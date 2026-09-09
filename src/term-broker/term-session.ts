// ⚠️ ESTE ARCHIVO SE VENDORIZA A CORTEX. Existe una COPIA byte-a-byte en `cortex/src/term-broker/`, que es
// la que instala y corre `cortex-term-broker.service`. Se edita AQUÍ (axon es la fuente) y después se
// RE-VENDORIZA allá: copiar los cinco módulos, regenerar `SHA256SUMS`, actualizar el commit anotado en
// `PROCEDENCIA.md` y en `NOTICE`, y correr `probe-topes.ts` + `probe-instalador.sh`. El contrato completo,
// con su anti-drift de tres chequeos, está en `cortex/src/term-broker/PROCEDENCIA.md`. Si cambias esto y no
// re-vendorizas, el broker que sirve al usuario se queda atrás sin que nada lo señale.
// src/server/term-session.ts — SESIONES DE SHELL PERSISTENTES para el widget de Terminal.
//
// PROBLEMA que resuelve: la primera versión de la terminal (broker + term-stream) spawneaba
// `<shell> -l -c <cmd>` NUEVO por cada comando → cada comando corría en un shell FRESCO desde el cwd
// default. `cd`, variables de entorno, venvs activados, `export`, etc. NO persistían entre comandos —
// un "ejecutor de comandos", no una sesión de shell de verdad (unjordi, 2026-09-04: `cd /etc` seguido
// de `pwd` devolvía el cwd default; "no es una terminal normal como la de ssh").
//
// SOLUCIÓN: UN shell de login VIVO por sesión (keyed por `session` id que manda el widget). Los comandos
// se escriben a SU stdin secuencialmente; como es el MISMO proceso, cwd/env/estado PERSISTEN igual que
// una sesión SSH. No usa un PTY nativo (node-pty = módulo nativo que rompería el "corre .ts sin build" de
// axon) — es un shell leyendo de un pipe. Trade-off consciente: NO es un TTY real (programas de pantalla
// completa como vim/top no funcionan; sin job-control), pero el widget es un runner línea-por-línea con
// botón Run, no un emulador xterm. Lo que el usuario pidió —que cd/env persistan— SÍ se cumple.
//
// FIN-DE-COMANDO (el reto de un shell persistente): como el shell no muere entre comandos, no hay un
// evento 'close' por comando. Tras cada comando escribimos un SENTINEL único que imprime el exit code:
// `printf '\001AXON_EOC_<token>:%d:EOC\001\n' "$?"`. El \001 (SOH, carácter de control invisible) hace
// la colisión con salida real prácticamente imposible. Cuando el sentinel aparece en stdout: emitimos lo
// previo como stdout del comando, extraemos el exit code, y damos el comando por terminado — SIN matar el
// shell (sigue vivo para el siguiente). Un comando mal formado (comilla sin cerrar) deja al shell en
// prompt de continuación; el usuario cierra/reabre el widget para resetear la sesión (igual que un shell real).
//
// PATH incompleto (bug real, 2026-09-04): el shell de la sesión es LOGIN (`-l`) pero NO interactivo — su
// stdin es un pipe (el pool le escribe comandos), no un tty, y zsh/bash deciden "interactivo" mirando si
// stdin+stdout son un tty (no basta con la ausencia de `-c`). Eso significa que NUNCA sourcea `~/.zshrc`
// (solo interactivo) — únicamente `~/.zprofile`/`/etc/zprofile` (login). Si el usuario agrega `~/.local/bin`
// (u otro bin de usuario) al PATH en `.zshrc` — como hace unjordi (`case ":$PATH:" in ... esac` en su
// `.zshrc`, NO en `.zprofile`) — ese directorio JAMÁS llega al PATH del shell de la sesión → `claude`,
// etc. resuelven "command not found" aunque el broker corra como el usuario correcto (badge HOST ✓).
//
// Descartadas dos alternativas, verificadas EN VIVO antes de elegir (evidencia, no intuición):
//   - Forzar `-i` (interactive) para que SÍ sourcee `.zshrc`: SÍ resuelve el PATH, pero mete secuencias OSC
//     de título de terminal (`\x1b]2;...\x07`) y ruido de gitstatus/zle/"can't change option: monitor"
//     (el prompt intenta usar job-control que no existe sin tty) DIRECTO en stdout — contaminaría cada
//     respuesta del widget con basura de escape codes, sentinel-parsing incluido. Además abre la puerta a
//     que un `.zshrc` con lógica realmente interactiva (un prompt que espera input) cuelgue el pipe.
//   - Sourcear `~/.zshrc` explícito como primer comando (sin `-i`): MISMO problema de contaminación — la
//     config de cachyos-zsh-config/p10k llama a sus hooks de título/prompt sin gatear por `[[ -o interactive ]]`,
//     así que el ruido OSC aparece en stdout igual, aunque el shell no sea técnicamente interactivo.
// Fix elegido: prependear al PATH heredado los bin-dirs de usuario más comunes ANTES de spawnear (ver
// `userBinDirs`/`sessionEnv` abajo) — inerte si un dir no existe, cero riesgo de colgarse (no toca zle/tty),
// y no arrastra efectos secundarios de un `.zshrc` completo. Verificado con `env -i` + `zsh -l` por stdin
// (sin heredar el PATH de una sesión interactiva previa, para replicar de verdad el entorno del broker):
// sin el fix, `which claude` → vacío; con el fix, resuelve `~/.local/bin/claude` y stdout queda limpio.

import { spawn, type ChildProcessWithoutNullStreams } from "node:child_process";
import { randomBytes } from "node:crypto";
import { StringDecoder } from "node:string_decoder";

/** Bin-dirs de usuario comunes que muchos `.zshrc`/`.bashrc` solo agregan al PATH en modo INTERACTIVO —
 *  ver el comentario largo arriba. Prependerlos aquí es el fix; una ruta que no existe es inofensiva (el
 *  shell simplemente no encuentra nada ahí, igual que con cualquier entrada muerta de PATH). */
const USER_BIN_DIRS = [".local/bin", "bin", ".cargo/bin"];

/** Construye el `env` para el shell de la sesión: hereda `process.env` (con lo que el broker ya tenía) y
 *  PREPENDEA los bin-dirs de usuario de arriba, resueltos contra `home` (el mismo home con el que arranca
 *  la sesión, no necesariamente `os.homedir()` si `AXON_TERM_BROKER_HOME` lo overridea). */
export function buildSessionEnv(home: string): NodeJS.ProcessEnv {
  const prefix = USER_BIN_DIRS.map((d) => `${home}/${d}`).join(":");
  const path = process.env.PATH ? `${prefix}:${process.env.PATH}` : prefix;
  const env: NodeJS.ProcessEnv = { ...process.env, TERM: process.env.TERM || "xterm-256color", PATH: path };
  // El shell debe ser la sesión REAL del usuario, NO el entorno del servicio: el broker corre con la
  // EnvironmentFile del servicio (maincar.env) que inyecta ANTHROPIC_API_KEY + vars AXON_* internas. Esas NO
  // viven en el login shell real de unjordi (verificado: ANTHROPIC_API_KEY vacío en su zsh -l) y CAMBIAN el
  // comportamiento de sus herramientas — p. ej. `claude` deshabilita los connectors de claude.ai al ver
  // ANTHROPIC_API_KEY. Se strippean para que el terminal sea idéntico a su sesión (auditoría item 9 #7,
  // ampliado): además es defensa-en-profundidad (el token del broker y la API key no quedan expuestos a `env`).
  delete env.ANTHROPIC_API_KEY;
  for (const k of Object.keys(env)) { if (k.startsWith("AXON_")) delete env[k]; }
  return env;
}

export interface TermChunk {
  readonly stream: "stdout" | "stderr";
  readonly data: string;
}

interface PendingCmd {
  readonly cmd: string;
  onChunk: (c: TermChunk) => void;
  onDone: (exitCode: number | null, error?: string) => void;
  aborted: boolean;
}

interface Session {
  readonly child: ChildProcessWithoutNullStreams;
  readonly queue: PendingCmd[];
  running: PendingCmd | null;
  sentinel: string;   // token del comando en curso ("" cuando idle)
  stdoutBuf: string;  // buffer de stdout para detectar el sentinel
  emitted: number;    // hasta dónde de stdoutBuf ya se emitió como stdout live
  lastActivity: number;
  idleTimer?: ReturnType<typeof setTimeout>;
}

export interface ShellSessionPoolOptions {
  readonly shell: string;         // ej. process.env.SHELL o "bash"
  readonly loginArgs: string[];   // ej. ["-l"] (login) — el shell lee comandos de stdin, sin -c
  readonly home: string;          // cwd inicial del shell
  readonly idleMs?: number;       // reap tras este tiempo sin actividad (default 30 min)
  /** Techo de sesiones concurrentes (default `DEFAULT_MAX_SESSIONS`). Un valor no-finito o <=0 cae al
   *  default. Llegó con los topes del broker; el constructor ya lo leía, pero la interfaz no lo
   *  declaraba: en cortex no se veía porque ahí los módulos corren con `--experimental-strip-types`,
   *  sin `tsc`. */
  readonly maxSessions?: number;
}

/** Marca de fin-de-comando: \001 + token aleatorio + exit code + \001. El control-char evita colisiones. */
const SENTINEL_PREFIX = "AXON_EOC_";

/**
 * TECHO de sesiones concurrentes. Cada sesión es un login shell VIVO del usuario: memoria, un pid y los
 * fds de sus pipes. Sin techo, una fuga —un cliente que nunca llama `close`, un widget que reconecta
 * con una `session` nueva cada vez— hace crecer el pool hasta agotar la memoria o los procesos de la
 * máquina, y eso se lleva por delante TODAS las terminales, no solo la que fugó.
 *
 * POR QUÉ 32: el widget abre UNA sesión por pestaña de terminal, y un humano trabaja con unas pocas.
 * 32 deja muchísimo aire para el uso legítimo (varias pestañas + reconexiones que el reap por idle aún
 * no barrió) y sigue estando un orden de magnitud por debajo de donde duele (`ulimit -u` ronda los
 * miles). O sea: un número que solo estorba cuando algo está FUGANDO — justo cuando se quiere que
 * frene. Configurable con `AXON_TERM_BROKER_MAX_SESSIONS` (lo cablea term-host-broker.ts).
 *
 * Al llegar al techo el rechazo es LIMPIO —`onDone(null, "SESSION_LIMIT: …")`, sin spawnear el shell y
 * sin dejar nada a medias— y no toca a las sesiones que ya existen: siguen ejecutando normal. El hueco
 * se libera con el reap por idle o al cerrar una sesión.
 */
export const DEFAULT_MAX_SESSIONS = 32;

export class ShellSessionPool {
  private readonly sessions = new Map<string, Session>();
  private readonly opts: ShellSessionPoolOptions;
  private readonly idleMs: number;
  private readonly maxSessions: number;

  constructor(opts: ShellSessionPoolOptions) {
    this.opts = opts;
    this.idleMs = opts.idleMs ?? 30 * 60 * 1000;
    const m = opts.maxSessions;
    this.maxSessions = typeof m === "number" && Number.isFinite(m) && m > 0 ? Math.floor(m) : DEFAULT_MAX_SESSIONS;
  }

  /** Sesiones VIVAS ahora mismo. Es lo que se compara contra el techo; también sirve para observarlo. */
  get size(): number { return this.sessions.size; }

  /** El techo efectivo de esta instancia (el default, o lo que se le configuró). */
  get limit(): number { return this.maxSessions; }

  /**
   * Encola `cmd` en la sesión `sessionId` (la crea si no existe) y streamea su salida. cwd/env PERSISTEN
   * entre llamadas a la MISMA sessionId. NUNCA lanza — los errores van por `onDone(null, error)`.
   */
  run(
    sessionId: string,
    cmd: string,
    onChunk: (c: TermChunk) => void,
    onDone: (exitCode: number | null, error?: string) => void,
    signal?: AbortSignal,
  ): void {
    if (!cmd.trim()) { onDone(null, "MISSING_ARG: 'cmd' vacío"); return; }
    // TECHO (ver DEFAULT_MAX_SESSIONS): solo aplica a sesiones NUEVAS — una que ya existe nunca se
    // rechaza. El rechazo va por el MISMO canal que cualquier otro error (`onDone(null, …)`), así que
    // el cliente recibe su `event: error` + `[DONE]` y no se queda colgado; y como se rechaza ANTES de
    // `getOrCreate`, no se spawnea ningún shell: no hay sesión zombi que reapear después.
    if (!this.sessions.has(sessionId) && this.sessions.size >= this.maxSessions) {
      onDone(
        null,
        `SESSION_LIMIT: el broker ya tiene ${this.sessions.size} sesiones de shell abiertas (tope ${this.maxSessions}). ` +
        "Cierra alguna terminal, o sube AXON_TERM_BROKER_MAX_SESSIONS si de verdad necesitas más.",
      );
      return;
    }
    let sess: Session;
    try {
      sess = this.getOrCreate(sessionId);
    } catch (e) {
      onDone(null, `no se pudo abrir la sesión de shell: ${e instanceof Error ? e.message : String(e)}`);
      return;
    }
    const pending: PendingCmd = { cmd, onChunk, onDone, aborted: false };
    if (signal) {
      // Abort (widget cerrado / socket muerto): desconecta los callbacks para no escribir a un socket
      // cerrado. El comando SIGUE corriendo en el shell (no hay forma limpia de mandar SIGINT al proceso
      // en foreground sin un PTY); el shell queda consistente para el siguiente comando.
      if (signal.aborted) pending.aborted = true;
      else signal.addEventListener("abort", () => { pending.aborted = true; }, { once: true });
    }
    sess.queue.push(pending);
    this.pump(sessionId, sess);
  }

  /** Cierra una sesión explícitamente (mata su shell). El widget la llama al cerrarse. Idempotente. */
  close(sessionId: string): void {
    const sess = this.sessions.get(sessionId);
    if (!sess) return;
    this.sessions.delete(sessionId);
    if (sess.idleTimer) clearTimeout(sess.idleTimer);
    try { sess.child.kill("SIGTERM"); } catch { /* ya murió */ }
  }

  /** Cierra TODAS las sesiones (shutdown del broker). */
  closeAll(): void {
    for (const id of [...this.sessions.keys()]) this.close(id);
  }

  private getOrCreate(sessionId: string): Session {
    const existing = this.sessions.get(sessionId);
    if (existing) return existing;

    // Shell de login leyendo de stdin (sin -c): un proceso VIVO que ejecuta comandos secuencialmente.
    const child = spawn(this.opts.shell, this.opts.loginArgs, {
      cwd: this.opts.home,
      env: buildSessionEnv(this.opts.home),
    });
    const sess: Session = {
      child, queue: [], running: null, sentinel: "", stdoutBuf: "", emitted: 0, lastActivity: Date.now(),
    };
    this.sessions.set(sessionId, sess);

    // #3 (auditoría 2026-09-09): decodificar CADA chunk con `b.toString("utf8")` por separado corrompía un
    // carácter UTF-8 multibyte partido en el borde de dos eventos `data` (rutina en el límite de 64 KiB del
    // pipe): cada mitad → U+FFFD (), irrecuperable. `StringDecoder` retiene la secuencia parcial de cola
    // hasta el siguiente `write`, así que un acento/ñ a caballo entre chunks sale intacto. UNO por stream
    // (stdout/stderr son flujos distintos). El camino PTY no sufre esto (es Buffer puro end-to-end).
    const soDec = new StringDecoder("utf8");
    const seDec = new StringDecoder("utf8");
    child.stdout.on("data", (b: Buffer) => this.onStdout(sessionId, sess, soDec.write(b)));
    child.stderr.on("data", (b: Buffer) => {
      if (sess.running && !sess.running.aborted) sess.running.onChunk({ stream: "stderr", data: seDec.write(b) });
    });
    const die = (err?: string) => this.onShellDeath(sessionId, sess, err);
    child.on("error", (e) => die(e.message));
    child.on("close", () => die("el shell de la sesión terminó (exit)"));

    this.armIdle(sessionId, sess);
    return sess;
  }

  private pump(sessionId: string, sess: Session): void {
    if (sess.running || sess.queue.length === 0) return;
    const next = sess.queue.shift()!;
    sess.running = next;
    sess.sentinel = randomBytes(9).toString("hex");
    sess.stdoutBuf = "";
    sess.emitted = 0;
    sess.lastActivity = Date.now();
    this.armIdle(sessionId, sess);

    // Escribe el comando y, en su PROPIA línea, el printf del sentinel con $? (exit del comando).
    // `\\001` en JS → los 4 chars `\001` que printf interpreta como octal → SOH (control invisible).
    // `\\n` → los 2 chars `\n` que printf interpreta como newline (fin de la línea del sentinel).
    // El `\n` FINAL (real) somete la línea del printf al shell.
    const marker = `${SENTINEL_PREFIX}${sess.sentinel}:`;
    const sentinelCmd = `printf '\\001${marker}%d:EOC\\001\\n' "$?"\n`;
    // El comando corre en un GRUPO `{ … }` (NO subshell → `cd`/`export` PERSISTEN) con stdin redirigido desde
    // /dev/null: así un REPL interactivo (claude, vim, python) recibe EOF y SALE en vez de robarse el pipe de
    // comandos del shell y colgar la sesión entera (el bug de "[detenido]"). El comando va en su propia línea
    // para no romperse con comentarios `#` o quotes sin cerrar en una sola línea.
    const wrapped = `{\n${next.cmd}\n} </dev/null\n`;
    try {
      sess.child.stdin.write(wrapped);
      sess.child.stdin.write(sentinelCmd);
    } catch (e) {
      const r = sess.running; sess.running = null;
      r.onDone(null, `no se pudo escribir al shell: ${e instanceof Error ? e.message : String(e)}`);
      this.pump(sessionId, sess);
    }
  }

  private onStdout(sessionId: string, sess: Session, data: string): void {
    if (!sess.running) return; // salida espuria sin comando en curso — ignora
    sess.lastActivity = Date.now();
    this.armIdle(sessionId, sess);
    sess.stdoutBuf += data;

    const re = new RegExp(`\\u0001${SENTINEL_PREFIX}${sess.sentinel}:(-?\\d+):EOC\\u0001`);
    const m = re.exec(sess.stdoutBuf);
    if (m) {
      // Emite todo lo previo al sentinel (menos el \n que el printf antepuso, si cabe) y cierra el comando.
      const pre = sess.stdoutBuf.slice(sess.emitted, m.index);
      const r = sess.running;
      if (r && !r.aborted && pre) r.onChunk({ stream: "stdout", data: pre });
      const code = Number.parseInt(m[1], 10);
      sess.running = null; sess.sentinel = ""; sess.stdoutBuf = ""; sess.emitted = 0;
      if (r && !r.aborted) r.onDone(Number.isNaN(code) ? null : code);
      this.pump(sessionId, sess);
      return;
    }
    // Sin sentinel aún: emite líneas COMPLETAS, reteniendo la última parcial (podría ser el inicio del
    // sentinel, que empieza con \001 en su propia línea).
    const lastNl = sess.stdoutBuf.lastIndexOf("\n");
    if (lastNl >= sess.emitted) {
      const chunk = sess.stdoutBuf.slice(sess.emitted, lastNl + 1);
      const r = sess.running;
      if (r && !r.aborted && chunk) r.onChunk({ stream: "stdout", data: chunk });
      sess.emitted = lastNl + 1;
    }
  }

  private onShellDeath(sessionId: string, sess: Session, err?: string): void {
    if (this.sessions.get(sessionId) === sess) this.sessions.delete(sessionId);
    if (sess.idleTimer) clearTimeout(sess.idleTimer);
    // Falla el comando en curso + los encolados, para que sus SSE no queden colgados.
    const pendings = [sess.running, ...sess.queue].filter(Boolean) as PendingCmd[];
    sess.running = null; sess.queue.length = 0;
    for (const p of pendings) if (!p.aborted) p.onDone(null, err ?? "la sesión de shell terminó");
  }

  private armIdle(sessionId: string, sess: Session): void {
    if (sess.idleTimer) clearTimeout(sess.idleTimer);
    sess.idleTimer = setTimeout(() => this.close(sessionId), this.idleMs);
    // No mantiene el proceso vivo solo por el timer.
    if (typeof sess.idleTimer.unref === "function") sess.idleTimer.unref();
  }
}
