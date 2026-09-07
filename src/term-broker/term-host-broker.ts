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
//   2. BIND SOLO A LOOPBACK (127.0.0.1) — jamás 0.0.0.0. Solo es alcanzable desde el HOST mismo, o desde un
//      contenedor con `--add-host=host.docker.internal:host-gateway` (Linux) / Docker Desktop (Mac/Windows,
//      donde `host.docker.internal` ya resuelve al host de fábrica).
// NO hay whitelist/denylist de comandos: quien tenga el token puede correr CUALQUIER cosa como el usuario del
// broker (unjordi). Aceptable en este scope (LAN de casa, token secreto compartido solo con el contenedor
// maincar) — NUNCA expongas este puerto más allá de loopback ni relajes el bind.

import { createServer, type IncomingMessage, type ServerResponse, type Server } from "node:http";
import { homedir } from "node:os";
import { pathToFileURL } from "node:url";
import type { Duplex } from "node:stream";
import { ShellSessionPool, buildSessionEnv } from "./term-session.ts";
import { acceptWebSocket, rejectWebSocket } from "./ws.ts";
import { servePtyOverWs } from "./term-pty-bridge.ts";

/** Puerto default del broker — debe calzar con el `AXON_TERM_BROKER_URL` que se le pasa al maincar. */
export const DEFAULT_PORT = 8799;

export interface BrokerOptions {
  readonly port?: number;   // default: env AXON_TERM_BROKER_PORT, o DEFAULT_PORT
  readonly token?: string;  // default: env AXON_TERM_BROKER_TOKEN — REQUERIDO, sin default (fail loud)
  readonly home?: string;   // default: env AXON_TERM_BROKER_HOME, o os.homedir() (cwd de arranque del comando)
  readonly shell?: string;  // default: env SHELL, o "/usr/bin/zsh" — shell de LOGIN del usuario
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
 * Arranca el broker (no bloquea; el caller decide si mantiene el proceso vivo). Lanza SI falta el token —
 * jamás arranca en modo "sin auth" por accidente. El servidor bindea explícitamente a 127.0.0.1 (loopback).
 */
export function startTermHostBroker(opts: BrokerOptions = {}): Server {
  const port = opts.port ?? Number(process.env.AXON_TERM_BROKER_PORT ?? DEFAULT_PORT);
  const token = opts.token ?? process.env.AXON_TERM_BROKER_TOKEN ?? "";
  const home = opts.home ?? process.env.AXON_TERM_BROKER_HOME ?? homedir();
  const shell = opts.shell ?? process.env.SHELL ?? "/usr/bin/zsh";
  if (!token) {
    throw new Error(
      "AXON_TERM_BROKER_TOKEN no está seteado — el broker NO arranca sin token (evitaría exponer ejecución de comandos sin auth).",
    );
  }

  // Pool de sesiones de shell PERSISTENTES (una por `session` id del widget) — cwd/env perduran entre
  // comandos, igual que una sesión SSH. Ver term-session.ts. Vive mientras viva el broker.
  const pool = new ShellSessionPool({ shell, loginArgs: ["-l"], home });

  const server = createServer((req: IncomingMessage, res: ServerResponse) => {
    void handleRequest(req, res, { token, home, shell, pool });
  });
  // TERMINAL INTERACTIVA (PTY real): upgrade a WebSocket en `/pty`. Mismo scope de seguridad que `/run` — corre
  // como el usuario del broker (unjordi), con SU shell de login y SU $HOME. Auth por el MISMO Bearer token
  // (axon-en-contenedor es el cliente y SÍ puede setear el header en el handshake). Ver term-pty-bridge.ts.
  server.on("upgrade", (req: IncomingMessage, socket: Duplex) => {
    handlePtyUpgrade(req, socket, { token, home, shell });
  });
  server.listen(port, "127.0.0.1"); // ⚠️ SOLO loopback — ver comentario de seguridad arriba
  server.on("close", () => pool.closeAll());
  return server;
}

/** Handshake WS + PTY para `/pty` en el broker host-side. Auth por Bearer token ANTES de tocar el shell. */
function handlePtyUpgrade(
  req: IncomingMessage,
  socket: Duplex,
  cfg: { token: string; home: string; shell: string },
): void {
  let parsed: URL;
  try { parsed = new URL(req.url ?? "/", "http://127.0.0.1"); }
  catch { rejectWebSocket(socket, 400, "bad request"); return; }
  if (parsed.pathname !== "/pty") { rejectWebSocket(socket, 404, "not found"); return; }

  // Auth PRIMERO: 401 antes de asignar un PTY.
  const auth = req.headers.authorization ?? "";
  const presented = auth.startsWith("Bearer ") ? auth.slice("Bearer ".length) : "";
  if (!tokenMatches(presented, cfg.token)) { rejectWebSocket(socket, 401, "unauthorized"); return; }

  const conn = acceptWebSocket(req, socket);
  if (!conn) { rejectWebSocket(socket, 400, "not a websocket upgrade"); return; }

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
  const home = process.env.AXON_TERM_BROKER_HOME ?? homedir();
  const shell = process.env.SHELL ?? "/usr/bin/zsh";
  try {
    startTermHostBroker();
    console.log(`[term-host-broker] escuchando en 127.0.0.1:${port} (home=${home}, shell=${shell} -l)`);
  } catch (e) {
    console.error(`[term-host-broker] no arrancó: ${e instanceof Error ? e.message : String(e)}`);
    process.exit(1);
  }
}

// Ejecuta main() solo si se invoca DIRECTAMENTE (mismo patrón que cli.ts) — no al importarlo desde un test/probe.
if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  main();
}
