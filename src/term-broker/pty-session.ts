// src/server/pty-session.ts — PTY REAL para el widget de Terminal INTERACTIVA de Odysseus.
//
// PROBLEMA que resuelve: term-session.ts (el pool one-shot) escribe comandos al stdin de un shell por un
// PIPE. Eso hace persistir cwd/env, pero NO es un TTY: los REPL interactivos (claude, vim, python, top, ssh)
// reciben EOF de stdin y SALEN, o rompen porque no hay control de terminal (sin winsize, sin señales, sin
// modo raw). Un widget de terminal DE VERDAD necesita un PTY (pseudo-terminal) por sesión.
//
// POR QUÉ NO node-pty: axon corre `.ts` DIRECTO con `node --experimental-strip-types`, SIN build step, y evita
// deps NATIVAS que necesiten compilar (node-gyp/python/g++). node-pty es un módulo nativo; en Node 26 (bleeding
// edge, ABI nueva) sus prebuilds casi seguro NO existen -> compilaría desde fuente en cada host/contenedor. Eso
// choca de frente con el ethos "corre .ts sin build, sin deps nativas".
//
// SOLUCIÓN sin deps nativas: `script(1)` de util-linux ASIGNA un PTY y corre el comando adentro. Con
// `script -qfec '<cmd>' /dev/null`:
//   -q quiet (sin "Script started/done"), -f flush por escritura (interactividad real),
//   -e propaga el exit code del hijo, -c corre <cmd> en vez de un shell interactivo default.
// El master del PTY queda conectado al stdin/stdout de `script` (que aquí son PIPES de node) -> escribimos
// keystrokes a child.stdin (incl. señales: Ctrl-C = \x03) y leemos ANSI crudo de child.stdout. VERIFICADO EN
// VIVO (2026-09-04): el hijo ve `/dev/pts/N` como tty, `stty size` correcto, Ctrl-C interrumpe (exit 130).
//
// WINSIZE (el reto del truco `script`): con stdin/stdout de `script` siendo pipes (no un tty), el PTY nace en
// 0x0. Dos mecanismos, ambos SIN deps nativas y verificados en vivo:
//   1. INICIAL: la primera línea del wrapper hace `stty rows R cols C` sobre su propio tty de control (el
//      slave) -> fija el winsize antes de arrancar el programa.
//   2. DINÁMICO (SIGWINCH en caliente): desde AFUERA, `stty -F /dev/pts/N rows R cols C` hace el TIOCSWINSZ
//      sobre el slave y DISPARA SIGWINCH al proceso en foreground -> resize real mientras corre claude/vim/top.
// Para (2) necesitamos la ruta del pts: el wrapper la emite in-band con un marcador de control
// (SOH + "AXON_PTS" + ruta + SOH) que este runner EXTRAE y quita del stream antes de entregárselo a xterm.

import { spawn, execFile, type ChildProcessWithoutNullStreams } from "node:child_process";

export interface PtyOptions {
  /** Comando a `exec`utar dentro del PTY. Default: shell de login INTERACTIVO (`exec <shell> -il`), que es lo
   *  que el widget abre — el usuario teclea `claude`/`vim`/lo que sea adentro. */
  readonly cmd?: string;
  /** Shell para el comando interactivo default (ej. "/usr/bin/zsh"). Ignorado si `cmd` viene dado. */
  readonly shell?: string;
  readonly cwd: string;
  readonly env: NodeJS.ProcessEnv;
  readonly cols?: number;
  readonly rows?: number;
}

export interface PtyProcess {
  /** Escribe al stdin del PTY (keystrokes; señales como \x03 = Ctrl-C viajan por aquí). */
  write(data: string | Buffer): void;
  /** Reajusta el winsize EN CALIENTE (TIOCSWINSZ + SIGWINCH) vía `stty -F <pts>`. */
  resize(cols: number, rows: number): void;
  /** Mata el PTY (SIGHUP -> el programa en foreground recibe HUP; SIGKILL de gracia si no cede). */
  kill(): void;
  /** Datos crudos del PTY (ANSI incluido), YA sin el marcador de pts. */
  onData(cb: (chunk: Buffer) => void): void;
  /** Cierre del PTY con exit code (null si lo mató una señal / nunca arrancó). */
  onExit(cb: (code: number | null, error?: string) => void): void;
  readonly pid: number | undefined;
}

// Marcador in-band del pts: SOH (0x01) + "AXON_PTS" + <ruta> + SOH. El SOH (control-char invisible) hace la
// colisión con ANSI normal prácticamente imposible. Se busca A NIVEL BYTE (no string) para no corromper UTF-8
// multibyte partido en el borde de un chunk durante la fase de extracción.
const SOH = 0x01;
const PTS_TAG = Buffer.from("AXON_PTS", "utf8");
/** Si el marcador no aparece en los primeros N bytes, dejamos de bufferizar y soltamos lo acumulado (defensa:
 *  un `cmd` custom que no use nuestro wrapper no debe colgar el stream para siempre). */
const PTS_MARK_MAX_BUFFER = 4096;

function clampDim(v: number | undefined, def: number): number {
  if (typeof v !== "number" || !Number.isFinite(v)) return def;
  const n = Math.floor(v);
  if (n < 1) return def;
  if (n > 1000) return 1000; // techo defensivo (winsize sensato)
  return n;
}

/**
 * Arranca un PTY con `script -qfec` y devuelve un handle bidireccional. NUNCA lanza — un fallo de spawn se
 * reporta por `onExit(null, error)`. El PTY vive mientras no se llame `kill()` o el programa adentro termine.
 */
export function spawnPty(opts: PtyOptions): PtyProcess {
  const cols = clampDim(opts.cols, 80);
  const rows = clampDim(opts.rows, 24);
  const shell = opts.shell || process.env.SHELL || "/usr/bin/bash";
  const rawInner = opts.cmd && opts.cmd.trim() ? opts.cmd.trim() : `${shell} -il`;
  // `exec` para que el programa REEMPLACE al sh del wrapper -> queda como líder de sesión del PTY (señales y
  // job-control llegan a ÉL, no a un sh intermedio). Si el caller ya trae su propio `exec`, no lo duplicamos.
  const inner = rawInner.startsWith("exec ") ? rawInner : `exec ${rawInner}`;
  // Corre bajo el shell de `script -c` (típicamente sh -c). POSIX puro: stty + printf + tty + exec.
  // `\\001` en el template JS -> los 4 chars `\001` que printf interpreta como octal -> byte SOH (0x01).
  const wrapper = `stty rows ${rows} cols ${cols} 2>/dev/null; printf '\\001AXON_PTS%s\\001' "$(tty)"; ${inner}`;

  let dataCb: ((chunk: Buffer) => void) | null = null;
  let exitCb: ((code: number | null, error?: string) => void) | null = null;
  let exited = false;

  // Estado de extracción del marcador de pts.
  let ptsPath: string | null = null;
  let ptsResolved = false;
  let preBuf = Buffer.alloc(0);
  let pendingResize: { cols: number; rows: number } | null = null;

  let child: ChildProcessWithoutNullStreams;
  try {
    child = spawn("script", ["-qfec", wrapper, "/dev/null"], {
      cwd: opts.cwd,
      env: { ...opts.env, TERM: opts.env.TERM || "xterm-256color" },
    });
  } catch (e) {
    // Devuelve un handle inerte que reporta el fallo en el próximo tick (para que el caller pueda registrar
    // onExit antes de recibirlo).
    const err = e instanceof Error ? e.message : String(e);
    queueMicrotask(() => { if (exitCb) exitCb(null, `no se pudo spawnear el PTY (script): ${err}`); });
    return {
      write() { /* no-op */ },
      resize() { /* no-op */ },
      kill() { /* no-op */ },
      onData(cb) { dataCb = cb; },
      onExit(cb) { exitCb = cb; },
      pid: undefined,
    };
  }

  const applyResize = (c: number, r: number): void => {
    if (!ptsPath) { pendingResize = { cols: c, rows: r }; return; }
    // stty -F <pts> rows R cols C -> TIOCSWINSZ sobre el slave + SIGWINCH al foreground. Best-effort.
    execFile("stty", ["-F", ptsPath, "rows", String(r), "cols", String(c)], () => { /* ignora errores (pts se cerró) */ });
  };

  const emit = (buf: Buffer): void => { if (buf.length && dataCb) dataCb(buf); };

  const onChunk = (buf: Buffer): void => {
    if (ptsResolved) { emit(buf); return; }
    // Aún buscando el marcador: acumula y busca A NIVEL BYTE.
    preBuf = Buffer.concat([preBuf, buf]);
    const start = preBuf.indexOf(SOH);
    if (start >= 0 && preBuf.length >= start + 1 + PTS_TAG.length) {
      if (preBuf.subarray(start + 1, start + 1 + PTS_TAG.length).equals(PTS_TAG)) {
        const end = preBuf.indexOf(SOH, start + 1 + PTS_TAG.length);
        if (end >= 0) {
          ptsPath = preBuf.subarray(start + 1 + PTS_TAG.length, end).toString("utf8").trim() || null;
          ptsResolved = true;
          const before = preBuf.subarray(0, start);
          const after = preBuf.subarray(end + 1);
          preBuf = Buffer.alloc(0);
          emit(Buffer.concat([before, after]));
          if (pendingResize) { const pr = pendingResize; pendingResize = null; applyResize(pr.cols, pr.rows); }
          return;
        }
        // Marcador aún incompleto (falta el SOH de cierre) -> espera más data.
      }
      // Un SOH que NO es nuestro tag -> espera (podría ser ruido); el cap de abajo evita colgarse.
    }
    if (preBuf.length > PTS_MARK_MAX_BUFFER) {
      // Nunca llegó el marcador -> suelta lo acumulado y sigue en modo passthrough.
      ptsResolved = true;
      const flushed = preBuf;
      preBuf = Buffer.alloc(0);
      emit(flushed);
    }
  };

  child.stdout.on("data", (b: Buffer) => onChunk(b));
  child.stderr.on("data", (b: Buffer) => onChunk(b)); // script -q casi no emite por acá; por si acaso
  const finish = (code: number | null, error?: string): void => {
    if (exited) return;
    exited = true;
    if (exitCb) exitCb(code, error);
  };
  child.on("error", (e) => finish(null, e.message));
  child.on("close", (code) => finish(code));

  return {
    write(data: string | Buffer) {
      try { child.stdin.write(data); } catch { /* pty cerrado */ }
    },
    resize(c: number, r: number) {
      applyResize(clampDim(c, 80), clampDim(r, 24));
    },
    kill() {
      try { child.kill("SIGHUP"); } catch { /* ya murió */ }
      // Gracia: si no cede en 2s, SIGKILL. unref para no mantener vivo el proceso solo por el timer.
      const t = setTimeout(() => { try { child.kill("SIGKILL"); } catch { /* ya murió */ } }, 2000);
      if (typeof t.unref === "function") t.unref();
    },
    onData(cb) { dataCb = cb; },
    onExit(cb) { exitCb = cb; },
    get pid() { return child.pid; },
  };
}
