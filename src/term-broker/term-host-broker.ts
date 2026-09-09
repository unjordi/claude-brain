// src/server/term-host-broker.ts — BROKER host-side para el widget de Terminal de Odysseus.
//
// CONTEXTO: `/api/axon/term` (term-stream.ts + http-server.ts) corre el comando DENTRO del proceso de axon.
// Cuando axon corre en el contenedor Docker del MAIN CAR, eso significa ejecutar en el contenedor como root,
// no en la compu del usuario. Este broker es la "opción 2" ya documentada en docs/terminal.md ("companion en
// el host"): un servidor HTTP CHIQUITO que corre NATIVO en el host (fuera de Docker), como el usuario real
// (unjordi), y expone un endpoint que ejecuta comandos con SU shell de LOGIN desde SU $HOME — igual que una
// sesión SSH normal. axon (desde el contenedor) le reenvía el comando en vez de spawnear localmente — ver
// `forwardTermToHostBroker()` en http-server.ts.
//
// ⚠️ SEGURIDAD — este broker ejecuta LITERALMENTE lo que le llega vía `<shell> -l -c <cmd>`, como el usuario
// que lo arrancó. Dos capas mínimas de defensa; NINGUNA es una sandbox real:
//   1. TOKEN compartido (env AXON_TERM_BROKER_TOKEN) — sin token configurado el broker NO ARRANCA (fail loud,
//      nunca expone ejecución de comandos sin auth "por accidente"). El request debe traer
//      `Authorization: Bearer <token>` exacto o se responde 401 ANTES de leer el body / tocar el shell.
//   2. NADA DE PUERTO EN LA LAN. El transporte por default para el contenedor es un SOCKET UNIX
//      (AXON_TERM_BROKER_SOCKET), que no tiene dirección de red: se alcanza solo montando el socket en el
//      contenedor, y lo protegen los permisos del filesystem (0600, dueño = el usuario del broker). El
//      listener TCP sigue existiendo para clientes NATIVOS del host, y bindea 127.0.0.1 por default
//      (AXON_TERM_BROKER_BIND lo hace configurable; cualquier valor que no sea loopback es exponer RCE).
//
// ⚠️ CORRECCIÓN DE DOC (2026-09-07) — el comentario que vivía aquí AFIRMABA que el bind a loopback era
// alcanzable "desde un contenedor con --add-host=host.docker.internal:host-gateway (Linux)". Es FALSO, y
// costó una terminal muerta: en Linux `host-gateway` resuelve a la IP del host en `docker0` (172.17.0.1),
// NO a loopback — un servidor bindeado a 127.0.0.1 nunca acepta ahí. (En Docker Desktop sí funciona, pero
// porque el host es una VM y `host.docker.internal` entra por otra vía; no es el caso de este Linux.)
// Medido el 2026-09-07 en esta máquina: bindear al gateway de la red de compose (172.23.0.1) TAMPOCO basta
// — `ufw` está activo y su política de INPUT descarta el tráfico contenedor→host (timeout, no refused).
// Por eso el transporte elegido es el socket unix: no pasa por la pila de red ni por el firewall.
//
// NO hay whitelist/denylist de comandos: quien tenga el token puede correr CUALQUIER cosa como el usuario del
// broker (unjordi). Aceptable en este scope (socket local + token secreto compartido solo con el contenedor
// maincar) — NUNCA expongas este broker más allá de loopback/socket unix ni relajes el bind.

import { createServer, type IncomingMessage, type ServerResponse, type Server } from "node:http";
import { connect as netConnect } from "node:net";
import { homedir } from "node:os";
import { accessSync, chmodSync, constants as fsConstants, mkdirSync, statSync, unlinkSync } from "node:fs";
import { dirname, join } from "node:path";
import { pathToFileURL } from "node:url";
import type { Duplex } from "node:stream";
import { ShellSessionPool, buildSessionEnv, DEFAULT_MAX_SESSIONS } from "./term-session.ts";
import { acceptWebSocket, rejectWebSocket } from "./ws.ts";
import { servePtyOverWs } from "./term-pty-bridge.ts";

/** Puerto default del broker — debe calzar con el `AXON_TERM_BROKER_URL` que se le pasa al maincar. */
export const DEFAULT_PORT = 8799;

/** Host default del listener TCP. LOOPBACK — cambiarlo expone ejecución de comandos arbitrarios a la red. */
export const DEFAULT_BIND = "127.0.0.1";

/**
 * TECHO de PTYs concurrentes (`/pty`). Es el hermano del techo de sesiones de `term-session.ts`, por el
 * camino que MÁS duele: cada upgrade a `/pty` asigna un pseudo-terminal del kernel + un `script` + un
 * login shell INTERACTIVO, y hasta ahora nadie llevaba la cuenta — ni una. Un cliente que reconecta en
 * bucle (o un token filtrado) agota `/dev/pts` y con eso se queda sin terminales TODA la máquina, no
 * solo el widget.
 *
 * POR QUÉ 32: mismo razonamiento que el techo de sesiones (una pestaña = un PTY) y a propósito el MISMO
 * número, para que no haya dos cifras que recordar. `/proc/sys/kernel/pty/max` ronda 4096: 32 es ~1% de
 * eso. Configurable con `AXON_TERM_BROKER_MAX_PTYS`.
 *
 * El rechazo ocurre en el HANDSHAKE (`503`, ANTES de asignar el PTY): el cliente ve un fallo de conexión
 * claro y no queda ni un proceso a medio arrancar.
 */
export const DEFAULT_MAX_PTYS = 32;

/** Lee un entero POSITIVO de una env var; cualquier basura (vacío, 0, negativo, NaN) cae al default. */
function positiveEnv(raw: string | undefined, def: number): number {
  const n = Number(raw);
  return Number.isFinite(n) && n > 0 ? Math.floor(n) : def;
}

/**
 * Ruta default del SOCKET UNIX (el transporte que usa el maincar contenerizado).
 * `$XDG_RUNTIME_DIR/axon/term-broker.sock` cuando existe (tmpfs 0700 del usuario, se limpia al cerrar
 * sesión — el lugar correcto para un socket de runtime), si no `$HOME/.axon/term-broker.sock`.
 *
 * Se monta en el contenedor por DIRECTORIO, no por archivo: un bind-mount de archivo se ata al INODO, y el
 * broker recrea el socket en cada arranque ⇒ tras un `systemctl --user restart` el contenedor se quedaría
 * hablándole a un inodo muerto. Medido el 2026-09-07: con el archivo montado, tras recrear el socket el
 * contenedor da ECONNREFUSED; con el directorio montado, sigue conectando.
 */
export function defaultBrokerSocketPath(): string {
  const runtime = process.env.XDG_RUNTIME_DIR;
  if (runtime) return join(runtime, "axon", "term-broker.sock");
  return join(homedir(), ".axon", "term-broker.sock");
}

export interface BrokerOptions {
  readonly port?: number;   // default: env AXON_TERM_BROKER_PORT, o DEFAULT_PORT
  readonly token?: string;  // default: env AXON_TERM_BROKER_TOKEN — REQUERIDO, sin default (fail loud)
  readonly home?: string;   // default: env AXON_TERM_BROKER_HOME, o os.homedir() (cwd de arranque del comando)
  readonly shell?: string;  // default: env SHELL, o "/usr/bin/zsh" — shell de LOGIN del usuario
  readonly bind?: string;   // default: env AXON_TERM_BROKER_BIND, o DEFAULT_BIND (127.0.0.1). Loopback o RCE.
  /** Socket unix. `null`/"off" lo desactiva. default: env AXON_TERM_BROKER_SOCKET, o defaultBrokerSocketPath(). */
  readonly socketPath?: string | null;
  /** Techo de sesiones de shell CONCURRENTES. default: env AXON_TERM_BROKER_MAX_SESSIONS, o 32. */
  readonly maxSessions?: number;
  /** Techo de PTYs (`/pty`) CONCURRENTES. default: env AXON_TERM_BROKER_MAX_PTYS, o DEFAULT_MAX_PTYS. */
  readonly maxPtys?: number;
}

/** Cuenta viva de PTYs de un broker. Es un objeto (no un número) para que el handler de upgrade la
 *  MUTE — cada `startTermHostBroker` tiene la suya, y los DOS listeners (TCP y unix) la comparten,
 *  igual que comparten el pool: el techo es del BROKER, no de un transporte. */
interface PtyGuard { live: number; readonly max: number; }

/** Lo que devuelve `startTermHostBroker`: los DOS listeners (TCP loopback + socket unix) y su cierre. */
export interface BrokerHandle {
  /** Listener TCP en `bind:port` — para clientes NATIVOS del host (el `axon` de la terminal de unjordi). */
  readonly tcp: Server;
  /** Listener sobre socket unix — el que usa el maincar contenerizado. `null` si se desactivó. */
  readonly unix: Server | null;
  readonly socketPath: string | null;
  /** Resuelve cuando AMBOS listeners están escuchando; rechaza si alguno no pudo bindear. */
  readonly ready: Promise<void>;
  close(): void;
}

function readBody(req: IncomingMessage, maxBytes = 1024 * 1024): Promise<string> {
  return new Promise((resolve, reject) => {
    const chunks: Buffer[] = [];
    let size = 0;
    req.on("data", (b: Buffer) => {
      size += b.length;
      if (size > maxBytes) { reject(new Error("body demasiado grande")); req.destroy(); return; }
      chunks.push(b);
    });
    req.on("end", () => resolve(Buffer.concat(chunks).toString("utf8")));
    req.on("error", reject);
  });
}

/** Compara el token recibido contra el configurado. Longitud distinta ⇒ falso rápido (evita construir un
 *  Buffer más grande de lo necesario); si calzan en longitud, compara con Buffer.equals — no es criptografía
 *  de verdad (Buffer.equals no es constant-time), pero evita el `===` de string más ingenuo. */
function tokenMatches(got: string, want: string): boolean {
  if (!want || got.length !== want.length) return false;
  return Buffer.from(got).equals(Buffer.from(want));
}

/**
 * ¿Hay un broker VIVO escuchando en `p`, o es un socket huérfano de un proceso muerto?
 * Un socket unix NO se borra solo al morir el proceso: si no distinguiéramos, o bien fallaríamos con
 * EADDRINUSE tras cada crash, o bien borraríamos el socket de un broker que SÍ está sirviendo.
 */
function probeUnixSocket(p: string, timeoutMs = 500): Promise<boolean> {
  return new Promise((resolve) => {
    let done = false;
    const settle = (alive: boolean): void => { if (!done) { done = true; resolve(alive); } };
    const s = netConnect(p);
    s.setTimeout(timeoutMs);
    s.on("connect", () => { settle(true); s.destroy(); });
    s.on("timeout", () => { settle(false); s.destroy(); });
    s.on("error", () => { settle(false); s.destroy(); });
  });
}

/**
 * Arranca el broker (no bloquea; el caller decide si mantiene el proceso vivo). Lanza SI falta el token —
 * jamás arranca en modo "sin auth" por accidente.
 *
 * DOS listeners, un solo handler:
 *   • TCP en `bind:port` (default 127.0.0.1) — clientes NATIVOS del host.
 *   • SOCKET UNIX en `socketPath` (default `defaultBrokerSocketPath()`) — el maincar CONTENERIZADO, que
 *     lo monta como volumen. Es el que arregla el bug: un contenedor NO alcanza un bind a loopback
 *     (host.docker.internal→172.17.0.1 en Linux), y abrir un puerto a la red sería exponer RCE.
 * Son dos `http.Server` porque `listen()` solo se puede llamar UNA vez por instancia; comparten handler,
 * token y —clave— el MISMO `ShellSessionPool`: una `session` del widget es la misma shell entre por donde
 * entre. Node aplica al socket el umask del proceso, así que se le fuerza 0600 tras bindear.
 */
export function startTermHostBroker(opts: BrokerOptions = {}): BrokerHandle {
  const port = opts.port ?? Number(process.env.AXON_TERM_BROKER_PORT ?? DEFAULT_PORT);
  const bind = opts.bind ?? process.env.AXON_TERM_BROKER_BIND ?? DEFAULT_BIND;
  const token = opts.token ?? process.env.AXON_TERM_BROKER_TOKEN ?? "";
  const home = opts.home ?? process.env.AXON_TERM_BROKER_HOME ?? homedir();
  const shell = opts.shell ?? process.env.SHELL ?? "/usr/bin/zsh";
  const rawSocket = opts.socketPath !== undefined ? opts.socketPath : (process.env.AXON_TERM_BROKER_SOCKET ?? defaultBrokerSocketPath());
  const socketPath = !rawSocket || rawSocket === "off" || rawSocket === "0" ? null : rawSocket;
  if (!token) {
    throw new Error(
      "AXON_TERM_BROKER_TOKEN no está seteado — el broker NO arranca sin token (evitaría exponer ejecución de comandos sin auth).",
    );
  }

  // Pool de sesiones de shell PERSISTENTES (una por `session` id del widget) — cwd/env perduran entre
  // comandos, igual que una sesión SSH. Ver term-session.ts. Vive mientras viva el broker.
  // `0` = "nadie lo configuró" → se deja `undefined` para que mande el default del propio pool (32),
  // en vez de tener el número escrito en dos lugares que puedan driftear.
  const envMaxSessions = positiveEnv(process.env.AXON_TERM_BROKER_MAX_SESSIONS, 0);
  const maxSessions = opts.maxSessions ?? (envMaxSessions > 0 ? envMaxSessions : undefined);
  const pool = new ShellSessionPool({ shell, loginArgs: ["-l"], home, maxSessions });
  const cfg = { token, home, shell, pool };
  // Techo de PTYs, compartido por los DOS listeners (ver PtyGuard).
  const ptyGuard: PtyGuard = {
    live: 0,
    max: opts.maxPtys && opts.maxPtys > 0 ? Math.floor(opts.maxPtys) : positiveEnv(process.env.AXON_TERM_BROKER_MAX_PTYS, DEFAULT_MAX_PTYS),
  };

  const mkServer = (): Server => {
    const s = createServer((req: IncomingMessage, res: ServerResponse) => { void handleRequest(req, res, cfg); });
    // TERMINAL INTERACTIVA (PTY real): upgrade a WebSocket en `/pty`. Mismo scope de seguridad que `/run` —
    // corre como el usuario del broker (unjordi), con SU shell de login y SU $HOME. Auth por el MISMO Bearer
    // token (axon-en-contenedor es el cliente y SÍ puede setear el header). Ver term-pty-bridge.ts.
    s.on("upgrade", (req: IncomingMessage, socket: Duplex) => { handlePtyUpgrade(req, socket, { token, home, shell, ptyGuard }); });
    return s;
  };

  const tcp = mkServer();
  const tcpReady = new Promise<void>((resolve, reject) => {
    tcp.once("error", reject);
    tcp.listen(port, bind, () => { tcp.removeListener("error", reject); resolve(); });
  });

  let unix: Server | null = null;
  let unixReady: Promise<void> = Promise.resolve();
  if (socketPath) {
    unix = mkServer();
    const srv = unix;
    unixReady = (async () => {
      const sockDir = dirname(socketPath);
      mkdirSync(sockDir, { recursive: true, mode: 0o700 });
      // Si el directorio existía pero NO es nuestro, decirlo con nombre y apellido en vez de dejar un
      // `listen EACCES` críptico. Caso probable: Docker crea el source de un bind-mount que no existe, y lo
      // crea **root:root** — si el stack levanta ANTES que este servicio, el directorio queda de root.
      try { accessSync(sockDir, fsConstants.W_OK); }
      catch {
        throw new Error(
          `no puedo escribir en ${sockDir} (¿lo creó Docker como root al levantar el stack antes que este servicio?). ` +
          `Arréglalo con \`sudo chown -R "$USER" ${sockDir}\` y arranca el broker ANTES del stack.`,
        );
      }
      // Socket huérfano de un crash previo → se borra. Socket VIVO → error ruidoso, jamás se lo quitamos
      // a un broker que está sirviendo (dos brokers sobre el mismo pool sería un bug silencioso).
      let exists = false;
      try { exists = statSync(socketPath).isSocket(); } catch { /* no existe */ }
      if (exists) {
        if (await probeUnixSocket(socketPath)) {
          throw new Error(`otro broker ya escucha en ${socketPath} — no lo piso. Detén ese proceso o usa AXON_TERM_BROKER_SOCKET.`);
        }
        try { unlinkSync(socketPath); } catch { /* carrera: alguien más lo quitó */ }
      }
      await new Promise<void>((resolve, reject) => {
        srv.once("error", reject);
        srv.listen(socketPath, () => { srv.removeListener("error", reject); resolve(); });
      });
      // 0600: solo el usuario del broker puede conectarse. El contenedor corre con el MISMO uid
      // (docker/axon.yml → `user: "${PUID:-1000}:${PGID:-1000}"`), así que le basta; cualquier otro
      // usuario del host queda fuera aunque llegue al directorio.
      chmodSync(socketPath, 0o600);
    })();
  }

  const close = (): void => {
    try { tcp.close(); } catch { /* ya cerrado */ }
    if (unix) { try { unix.close(); } catch { /* ya cerrado */ } }
    if (socketPath) { try { unlinkSync(socketPath); } catch { /* ya no está */ } }
    pool.closeAll();
  };
  tcp.on("close", () => pool.closeAll());

  return { tcp, unix, socketPath, ready: Promise.all([tcpReady, unixReady]).then(() => undefined), close };
}

/** Handshake WS + PTY para `/pty` en el broker host-side. Auth por Bearer token ANTES de tocar el shell. */
function handlePtyUpgrade(
  req: IncomingMessage,
  socket: Duplex,
  cfg: { token: string; home: string; shell: string; ptyGuard: PtyGuard },
): void {
  let parsed: URL;
  try { parsed = new URL(req.url ?? "/", "http://127.0.0.1"); }
  catch { rejectWebSocket(socket, 400, "bad request"); return; }
  if (parsed.pathname !== "/pty") { rejectWebSocket(socket, 404, "not found"); return; }

  // Auth PRIMERO: 401 antes de asignar un PTY.
  const auth = req.headers.authorization ?? "";
  const presented = auth.startsWith("Bearer ") ? auth.slice("Bearer ".length) : "";
  if (!tokenMatches(presented, cfg.token)) { rejectWebSocket(socket, 401, "unauthorized"); return; }

  // TECHO de PTYs (ver DEFAULT_MAX_PTYS): se rechaza en el HANDSHAKE, antes de asignar nada. `503` =
  // "ahora no puedo", que es exactamente lo que pasa; el cliente lo ve como un fallo de conexión con
  // su razón, no como un canal que se abre y muere raro.
  const guard = cfg.ptyGuard;
  if (guard.live >= guard.max) {
    rejectWebSocket(socket, 503, `too many pty sessions (${guard.live}/${guard.max}) - AXON_TERM_BROKER_MAX_PTYS`);
    return;
  }

  const conn = acceptWebSocket(req, socket);
  if (!conn) { rejectWebSocket(socket, 400, "not a websocket upgrade"); return; }

  // La cuenta se lleva sobre el SOCKET, no sobre `conn.onClose`: WsConn guarda UN solo callback de
  // cierre y `servePtyOverWs` (abajo) se queda con él para matar el PTY. El evento 'close' del socket
  // admite varios listeners y dispara una sola vez, pase lo que pase con el WebSocket.
  guard.live++;
  let counted = true;
  const release = (): void => { if (counted) { counted = false; guard.live = Math.max(0, guard.live - 1); } };
  socket.on("close", release);
  socket.on("error", release);

  const cols = Number(parsed.searchParams.get("cols")) || undefined;
  const rows = Number(parsed.searchParams.get("rows")) || undefined;
  // Shell de LOGIN INTERACTIVO real del usuario (`-il`): ahora que es un PTY de verdad, el modo interactivo
  // es lo que QUEREMOS (carga .zshrc, PATH completo, prompt) — xterm.js renderiza el ANSI/OSC correctamente
  // (justo lo que el pipe one-shot NO podía: ahí el ruido de escape codes contaminaba el stream). env = la
  // sesión REAL del usuario (buildSessionEnv strippea ANTHROPIC_API_KEY + AXON_*, igual que el one-shot).
  servePtyOverWs(conn, {
    shell: cfg.shell,
    cwd: cfg.home,
    env: buildSessionEnv(cfg.home),
    cols,
    rows,
  });
}

async function handleRequest(
  req: IncomingMessage,
  res: ServerResponse,
  cfg: { token: string; home: string; shell: string; pool: ShellSessionPool },
): Promise<void> {
  const url = req.url ?? "/";
  const method = req.method ?? "GET";

  // GET /health — LIVENESS con auth, para que el badge de la terminal pueda decir la VERDAD.
  // `/api/axon/term/mode` (http-server.ts) lo sondea antes de responder "host": sin esto, el único dato
  // disponible era "las env están puestas", que es exactamente lo que mentía cuando el broker no se
  // alcanzaba. Pide el MISMO Bearer que /run — así el sondeo distingue "no llego" de "llego pero el token
  // no calza" (dos fallas distintas que se veían igual). No toca el shell ni el pool: es barato a propósito.
  if (method === "GET" && (url === "/health" || url.startsWith("/health?"))) {
    const hAuth = req.headers.authorization ?? "";
    const hTok = hAuth.startsWith("Bearer ") ? hAuth.slice("Bearer ".length) : "";
    if (!tokenMatches(hTok, cfg.token)) {
      res.writeHead(401, { "Content-Type": "application/json" });
      res.end(JSON.stringify({ error: "unauthorized" }));
      return;
    }
    res.writeHead(200, { "Content-Type": "application/json" });
    res.end(JSON.stringify({ ok: true, home: cfg.home, shell: cfg.shell }));
    return;
  }

  if (method !== "POST" || !(url === "/" || url.startsWith("/run"))) {
    res.writeHead(404, { "Content-Type": "application/json" });
    res.end(JSON.stringify({ error: "not found" }));
    return;
  }

  // Auth PRIMERO: 401 antes de leer el body o tocar el shell.
  const auth = req.headers.authorization ?? "";
  const presented = auth.startsWith("Bearer ") ? auth.slice("Bearer ".length) : "";
  if (!tokenMatches(presented, cfg.token)) {
    res.writeHead(401, { "Content-Type": "application/json" });
    res.end(JSON.stringify({ error: "unauthorized" }));
    return;
  }

  let raw: string;
  try {
    raw = await readBody(req);
  } catch (e) {
    res.writeHead(400, { "Content-Type": "application/json" });
    res.end(JSON.stringify({ error: e instanceof Error ? e.message : String(e) }));
    return;
  }

  let cmd = "";
  let session = "default"; // sin session id del widget → una sola sesión compartida (aún persiste cwd/env)
  try {
    const obj = JSON.parse(raw.trim() || "{}") as { cmd?: unknown; session?: unknown };
    if (typeof obj.cmd === "string") cmd = obj.cmd;
    if (typeof obj.session === "string" && obj.session.trim()) session = obj.session.trim();
    // `cwd` del request ya NO se usa: el shell persistente de la sesión es dueño de su propio cwd (cd persiste).
  } catch { /* body ilegible → cmd vacío, se reporta abajo como MISSING_ARG (mismo wire que term-stream.ts) */ }

  // Mismo wire que runTermStream (term-stream.ts): {type:"stdout"|"stderr",chunk} / {type:"exit",code} /
  // [DONE], con `event: error` para fallos — así el widget de Odysseus no distingue si corrió local o vía
  // broker (forwardTermToHostBroker en http-server.ts pipea esto BYTE-A-BYTE, sin re-serializar).
  res.writeHead(200, { "Content-Type": "text/event-stream; charset=utf-8", "Cache-Control": "no-cache", Connection: "keep-alive" });

  if (!cmd.trim()) {
    res.write(`event: error\ndata: ${JSON.stringify({ error: "MISSING_ARG: 'cmd' vacío", status: 400 })}\n\n`);
    res.write("data: [DONE]\n\n");
    res.end();
    return;
  }

  // Cliente se soltó (cerró el widget): abortamos la ENTREGA de este comando (dejamos de escribir a un
  // socket muerto), PERO el shell de la sesión sigue vivo — su estado (cwd/env) se conserva para la próxima
  // vez que el widget se reabra con la misma `session`. El shell se reapea por idle (ver term-session.ts).
  const controller = new AbortController();
  res.on("close", () => controller.abort());

  // El shell de LOGIN persistente lo maneja el pool (mismo -l que antes: carga .zprofile del usuario). El
  // pool escribe `cmd` a su stdin, detecta el fin vía sentinel y reporta exit code — cwd/env PERSISTEN.
  let answered = false; // guarda contra doble-escritura (mismo espíritu que antes)
  cfg.pool.run(
    session,
    cmd,
    (c) => {
      try { res.write(`data: ${JSON.stringify({ type: c.stream, chunk: c.data })}\n\n`); } catch { /* socket cerrado */ }
    },
    (code, error) => {
      if (answered) return;
      answered = true;
      try {
        if (error) res.write(`event: error\ndata: ${JSON.stringify({ error, status: 500 })}\n\n`);
        res.write(`data: ${JSON.stringify({ type: "exit", code })}\n\n`);
        res.write("data: [DONE]\n\n");
      } catch { /* socket cerrado */ }
      try { res.end(); } catch { /* ya cerrado */ }
    },
    controller.signal,
  );
}

/** Entry point directo: `node --experimental-strip-types src/server/term-host-broker.ts`. Toda la config sale
 *  de env vars — ver docs/terminal.md (o el reporte de cierre del slice) para el comando exacto de arranque. */
function main(): void {
  const port = Number(process.env.AXON_TERM_BROKER_PORT ?? DEFAULT_PORT);
  const bind = process.env.AXON_TERM_BROKER_BIND ?? DEFAULT_BIND;
  const home = process.env.AXON_TERM_BROKER_HOME ?? homedir();
  const shell = process.env.SHELL ?? "/usr/bin/zsh";

  // ÚLTIMA RED: de este proceso cuelgan TODAS las terminales del usuario, y matarlo las mata a todas
  // de golpe (KillMode=control-group). Una excepción suelta en un callback de socket —un cliente que
  // se cae en el microsegundo equivocado, un EPIPE que nadie atrapó— no vale eso. Se registra y se
  // sigue: degradar, no morir. Va SOLO aquí, en el entry point: importar el módulo (probes, tests, el
  // axon contenerizado) no debe cambiarle a nadie el manejo global de errores de SU proceso.
  process.on("uncaughtException", (e: Error) => {
    console.error(`[term-host-broker] excepción no capturada (el broker SIGUE vivo): ${e.stack ?? e.message}`);
  });
  process.on("unhandledRejection", (r: unknown) => {
    console.error(`[term-host-broker] promesa rechazada sin manejar (el broker SIGUE vivo): ${r instanceof Error ? r.stack : String(r)}`);
  });

  let handle: BrokerHandle;
  try {
    handle = startTermHostBroker();
  } catch (e) {
    console.error(`[term-host-broker] no arrancó: ${e instanceof Error ? e.message : String(e)}`);
    process.exit(1);
    return;
  }
  handle.ready.then(
    () => {
      console.log(`[term-host-broker] escuchando en ${bind}:${port} (home=${home}, shell=${shell} -l)`);
      // Los topes se IMPRIMEN al arrancar: un rechazo por techo se diagnostica mirando el journal, no
      // adivinando qué default trae la versión instalada.
      console.log(
        `[term-host-broker] topes: ${positiveEnv(process.env.AXON_TERM_BROKER_MAX_SESSIONS, DEFAULT_MAX_SESSIONS)} sesiones de shell ` +
        `(AXON_TERM_BROKER_MAX_SESSIONS) · ${positiveEnv(process.env.AXON_TERM_BROKER_MAX_PTYS, DEFAULT_MAX_PTYS)} PTYs ` +
        "(AXON_TERM_BROKER_MAX_PTYS) · backpressure del WS a " +
        `${(positiveEnv(process.env.AXON_TERM_BROKER_WS_HIGH_WATER, 1024 * 1024) / 1024).toFixed(0)} KiB ` +
        `(AXON_TERM_BROKER_WS_HIGH_WATER), corte duro a ${(positiveEnv(process.env.AXON_TERM_BROKER_WS_MAX_BUFFER, 8 * 1024 * 1024) / (1024 * 1024)).toFixed(0)} MiB ` +
        "(AXON_TERM_BROKER_WS_MAX_BUFFER)",
      );
      if (handle.socketPath) console.log(`[term-host-broker] socket unix: ${handle.socketPath} (0600) — el que usa el maincar contenerizado`);
      else console.log("[term-host-broker] socket unix DESACTIVADO (AXON_TERM_BROKER_SOCKET=off) — un maincar en contenedor NO lo alcanzará");
      if (bind !== "127.0.0.1" && bind !== "::1" && bind !== "localhost") {
        console.warn(`[term-host-broker] ⚠️  AXON_TERM_BROKER_BIND=${bind} NO es loopback: este broker ejecuta comandos arbitrarios como ${process.env.USER ?? "el usuario"}. Solo el token te separa de un RCE en la red.`);
      }
    },
    (e: unknown) => {
      console.error(`[term-host-broker] no pudo escuchar: ${e instanceof Error ? e.message : String(e)}`);
      process.exit(1);
    },
  );
}

// Ejecuta main() solo si se invoca DIRECTAMENTE (mismo patrón que cli.ts) — no al importarlo desde un test/probe.
if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  main();
}
