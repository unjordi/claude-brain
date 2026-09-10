// ⚠️ ESTE ARCHIVO SE VENDORIZA A CORTEX. Existe una COPIA byte-a-byte en `cortex/src/term-broker/`, que es
// la que instala y corre `cortex-term-broker.service`. Se edita AQUÍ (axon es la fuente) y después se
// RE-VENDORIZA allá: copiar los cinco módulos, regenerar `SHA256SUMS`, actualizar el commit anotado en
// `PROCEDENCIA.md` y en `NOTICE`, y correr `probe-topes.ts` + `probe-instalador.sh`. El contrato completo,
// con su anti-drift de tres chequeos, está en `cortex/src/term-broker/PROCEDENCIA.md`. Si cambias esto y no
// re-vendorizas, el broker que sirve al usuario se queda atrás sin que nada lo señale.
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

/**
 * Ejecutor de UN ajuste de winsize sobre el pts. Resuelve `true` si se aplicó, `false` si falló o venció.
 * CONTRATO: nunca rechaza y SIEMPRE resuelve (el default trae timeout + watchdog) — de eso depende que la
 * cola de resizes no se quede trabada. Inyectable solo para pruebas; en producción se usa el default `stty`.
 */
export type ResizeRunner = (pts: string, cols: number, rows: number) => Promise<boolean>;

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
  /** Costura de PRUEBA: sustituye el ejecutor de winsize. Sin esto se usa `stty -F <pts>`. */
  readonly execResize?: ResizeRunner;
}

export interface PtyProcess {
  /** Escribe al stdin del PTY (keystrokes; señales como \x03 = Ctrl-C viajan por aquí). */
  write(data: string | Buffer): void;
  /** Reajusta el winsize EN CALIENTE (TIOCSWINSZ + SIGWINCH) vía `stty -F <pts>`. */
  resize(cols: number, rows: number): void;
  /** Mata el PTY (SIGHUP -> el programa en foreground recibe HUP; SIGKILL de gracia si no cede). */
  kill(): void;
  /**
   * Deja de LEER la salida del PTY — la mitad productora del backpressure (ver el bloque de ws.ts).
   * No descarta NADA: al no vaciar el pipe, éste se llena y `script` se bloquea escribiendo, lo que a
   * su vez frena al programa de adentro. Es la contrapresión del kernel, gratis y sin perder un byte.
   */
  pause(): void;
  /** Reanuda la lectura tras un `pause()`. Idempotente. */
  resume(): void;
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

/** Tope del `stty` de resize: si tarda más, se le manda SIGTERM y se da por fallido. */
const RESIZE_TIMEOUT_MS = 2000;
/** Red de seguridad por si el callback de `execFile` nunca llegara: la cola JAMÁS se queda trabada. */
const RESIZE_WATCHDOG_MS = RESIZE_TIMEOUT_MS + 1000;

// ── Reintentos del resize (FMEA 2026-09-08) ────────────────────────────────────────────────────────────
// Un `stty` puede fallar por causas TRANSITORIAS: el timeout de 2 s bajo carga, un `/dev/pts/N` ocupado un
// instante. Antes, el pedido se CONSUMÍA antes de saber si había funcionado: `applied` se quedaba en el
// PENÚLTIMO tamaño, `desired` ya era null y no había reintento. El comentario decía "un pedido idéntico
// posterior SÍ se reintenta", pero el frontend NUNCA lo repite: `createPtySizeReconciler` (odysseus
// static/js/term-geometry.js) marca `sent = next` en cuanto el `ws.send()` no lanza, SIN ACK. Los dos
// extremos quedaban convencidos de tamaños distintos y ninguno podía descubrirlo.
// El arreglo es acotado y local: reintentar aquí con backoff, y si aun así falla, NO tirar el pedido —
// `desired` vuelve a su ranura para que el próximo drenaje lo retome.
/** Intentos TOTALES por tamaño (1 + 2 reintentos). Acotado: un pts muerto no debe girar para siempre.
 *  Exportado para que el probe afirme contra la constante REAL y no contra un 3 copiado. */
/** Cuánto se espera antes de re-intentar el drenaje que quedó pendiente al agotar los intentos. Largo a
 *  propósito: si el pts no respondió a tres `stty` seguidos, insistir de inmediato solo quema ciclos. */
export const RESIZE_REAGENDA_MS = 5_000;

export const RESIZE_INTENTOS = 3;
/** Espera ENTRE intentos (ms). `RESIZE_INTENTOS - 1` entradas: el último intento no espera después. */
const RESIZE_BACKOFF_MS = [40, 160];

const dormir = (ms: number): Promise<void> => new Promise((r) => { const t = setTimeout(r, ms); if (typeof t.unref === "function") t.unref(); });

/** Ejecutor real: `stty -F <pts> rows R cols C` -> TIOCSWINSZ sobre el slave + SIGWINCH al foreground. */
const sttyResizeRunner: ResizeRunner = (pts, cols, rows) =>
  new Promise<boolean>((resolve) => {
    let settled = false;
    const done = (ok: boolean): void => { if (!settled) { settled = true; resolve(ok); } };
    const wd = setTimeout(() => done(false), RESIZE_WATCHDOG_MS);
    if (typeof wd.unref === "function") wd.unref();
    try {
      execFile(
        "stty", ["-F", pts, "rows", String(rows), "cols", String(cols)],
        { timeout: RESIZE_TIMEOUT_MS },
        (err) => { clearTimeout(wd); done(!err); }, // err = pts cerrado, stty ausente, o timeout
      );
    } catch { clearTimeout(wd); done(false); } // spawn imposible: se reporta como fallo, no se lanza
  });

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

  // ── Serialización de resizes (#26d) ────────────────────────────────────────────────────────────────────
  // Un resize es ESTADO IDEMPOTENTE, no un evento: lo único que importa es el tamaño FINAL. Por eso la
  // semántica es COALESCE "gana el último" y no una cola FIFO de todos los frames:
  //   · a lo más UN `stty` en vuelo por sesión  -> imposible que dos procesos se pisen el TIOCSWINSZ;
  //   · a lo más UN tamaño pendiente (el más reciente) -> una ráfaga de N frames cuesta 2 `stty`, no N,
  //     y no bombardea al programa en foreground con N SIGWINCH de tamaños que ya caducaron.
  // Antes esto era `execFile` fire-and-forget: N procesos concurrentes cuyo orden de ioctl no está
  // garantizado, así que podía GANAR UNO INTERMEDIO y dejar al shell con un tamaño que ya no era el de la
  // rejilla (medido: shell 115x24 vs xterm 121x24). La cola es POR SESIÓN (este closure), que es lo que
  // #29(a) necesita: N terminales simultáneas son N colas independientes sobre su propio pts.
  const runResize: ResizeRunner = opts.execResize ?? sttyResizeRunner;
  let desired: { cols: number; rows: number } | null = null;  // último tamaño PEDIDO y no confirmado
  let applied: { cols: number; rows: number } | null = null;  // último tamaño APLICADO con éxito
  let draining = false;

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
      pause() { /* no-op */ },
      resume() { /* no-op */ },
      onData(cb) { dataCb = cb; },
      onExit(cb) { exitCb = cb; },
      pid: undefined,
    };
  }

  // Vacía la ranura `desired` de a un `stty` a la vez. NUNCA lanza ni deja `draining` colgado: un runner que
  // reviente o venza no puede tumbar la sesión del PTY (a lo sumo el winsize se queda como estaba).
  const drainResizes = async (): Promise<void> => {
    if (draining) return;
    draining = true;
    try {
      while (desired && ptsPath && !exited) {
        const target = desired;
        // No-op: el tamaño pedido ya es el vigente -> ni se forkea.
        if (applied && applied.cols === target.cols && applied.rows === target.rows) { desired = null; break; }

        // Un solo `stty` en vuelo, con reintentos ACOTADOS ante un fallo transitorio (ver arriba).
        let ok = false;
        for (let intento = 0; intento < RESIZE_INTENTOS; intento++) {
          // La ranura queda LIBRE durante el await: si llega un tamaño más nuevo, ese manda y no se
          // insiste con el caducado (la semántica coalesce "gana el último" no se toca).
          desired = null;
          try { ok = await runResize(ptsPath, target.cols, target.rows); }
          catch { ok = false; } // runner defectuoso: cuenta como fallo, no tumba la sesión
          if (ok || exited || desired) break;
          const espera = RESIZE_BACKOFF_MS[intento];
          if (espera === undefined) break; // se agotaron los intentos
          await dormir(espera);
          if (exited || desired) break;
        }

        if (ok) { applied = target; continue; }
        if (exited || desired) continue; // murió, o hay algo más nuevo: la vuelta siguiente decide

        // Agotados los intentos y NADIE pidió otra cosa. Aquí `applied` NO puede quedarse con su valor
        // viejo: un `stty` que falla no prueba que no haya aplicado nada — el ioctl es instantáneo y el
        // timeout mata al proceso DESPUÉS, así que el pts puede haber cambiado igual. Con un `applied`
        // stale, el atajo no-op de arriba se traga la reconciliación: si el frontend vuelve luego al
        // tamaño viejo, coincide con `applied`, no se emite ningún `stty`, y el shell se queda en el
        // tamaño nuevo PARA SIEMPRE. El frontend tampoco lo salva: marca `sent` sin ACK, así que no
        // repite. Se marca DESCONOCIDO, que es lo único honesto: obliga al próximo pedido a emitir.
        applied = null;
        desired = target;   // el tamaño sigue pendiente: no se tira
        // …y se re-agenda el drenaje, porque nada más lo haría. `drainResizes` solo lo llaman
        // `applyResize` y la resolución del pts; sin esto, el `desired` que acabamos de guardar quedaba
        // huérfano esperando un pedido que el frontend nunca vuelve a mandar.
        const reintentoDiferido = setTimeout(() => { if (!exited && desired) void drainResizes(); }, RESIZE_REAGENDA_MS);
        if (typeof reintentoDiferido.unref === "function") reintentoDiferido.unref();
        break;
      }
    } catch { /* defensa final: la sesión sigue viva pase lo que pase */ }
    finally { draining = false; }
  };

  const applyResize = (c: number, r: number): void => {
    desired = { cols: c, rows: r };
    if (!ptsPath) return; // aún sin marcador de pts: queda pedido y se drena al resolverlo
    void drainResizes();
  };

  const emit = (buf: Buffer): void => { if (buf.length && dataCb) dataCb(buf); };

  const onChunk = (buf: Buffer): void => {
    if (ptsResolved) { emit(buf); return; }
    // Aún buscando el marcador: acumula y busca A NIVEL BYTE. L2 (auditoría 2026-09-09): se ITERA sobre los
    // SOH sucesivos — un `0x01` espurio en la salida del programa ANTES del marcador real ya no lo entierra
    // (antes `indexOf(SOH)` se clavaba en el primero y esperaba al cap, soltando el marcador real como
    // passthrough → resize muerto para esa sesión). Solo alcanzable con un `cmd` custom que emita 0x01.
    preBuf = Buffer.concat([preBuf, buf]);
    let start = preBuf.indexOf(SOH);
    while (start >= 0) {
      if (preBuf.length < start + 1 + PTS_TAG.length) break;  // faltan bytes para decidir ESTE candidato → espera
      if (preBuf.subarray(start + 1, start + 1 + PTS_TAG.length).equals(PTS_TAG)) {
        const end = preBuf.indexOf(SOH, start + 1 + PTS_TAG.length);
        if (end >= 0) {
          ptsPath = preBuf.subarray(start + 1 + PTS_TAG.length, end).toString("utf8").trim() || null;
          ptsResolved = true;
          const before = preBuf.subarray(0, start);   // lo previo (incluido cualquier SOH espurio) es salida real
          const after = preBuf.subarray(end + 1);
          preBuf = Buffer.alloc(0);
          emit(Buffer.concat([before, after]));
          if (desired) void drainResizes(); // ya hay pts: se drena lo que se pidió durante el arranque
          return;
        }
        break;  // tag correcto pero falta el SOH de cierre → espera más data
      }
      start = preBuf.indexOf(SOH, start + 1);  // SOH espurio → prueba el siguiente
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
    // Backpressure: pausar/reanudar la LECTURA de la salida. Never-throws — se llama desde el relay,
    // y una excepción ahí tumbaría el broker entero.
    pause() {
      try { child.stdout.pause(); child.stderr.pause(); } catch { /* pty cerrado */ }
    },
    resume() {
      try { child.stdout.resume(); child.stderr.resume(); } catch { /* pty cerrado */ }
    },
    kill() {
      desired = null; // nada que redimensionar en un PTY que se está muriendo
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
