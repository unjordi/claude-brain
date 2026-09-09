// probe-topes.ts — prueba FUNCIONAL de los TOPES del broker: techo de sesiones concurrentes y
// backpressure del relay de WebSocket. Los dos hallazgos que este probe fija en el suelo:
//
//   1. `ShellSessionPool` no tenía techo: una fuga de sesiones (clientes que no cierran, reconexiones)
//      crecía sin límite hasta agotar memoria/PTYs de la máquina. Ahora hay un tope configurable y el
//      rechazo es LIMPIO (error al cliente, el broker sigue sirviendo, NO queda sesión zombi).
//   2. El relay PTY→WS bombeaba a `socket.write()` sin mirar su retorno: un cliente que lee más lento
//      que el PTY hacía crecer el buffer del socket sin control. Ahora el productor se PAUSA.
//
// Corre TODO en proceso, sin tocar ningún servicio: puertos efímeros altos, `socketPath: null` (jamás
// el socket real del broker que el usuario está usando) y cada hijo se mata al final.
//
//   node --disable-warning=ExperimentalWarning --experimental-strip-types src/term-broker/probe-topes.ts
//
// Diseño de cada prueba: FALLA con el código de antes (sin los topes) y pasa con el de ahora. Los
// checks de "antes" no son teóricos — se corrió el probe contra el árbol sin el fix y se anotó abajo,
// en cada bloque, el número que daba.

import { createServer, request as httpRequest, type IncomingMessage, type Server } from "node:http";
import { homedir } from "node:os";
import type { Duplex } from "node:stream";
import { ShellSessionPool, buildSessionEnv } from "./term-session.ts";
import { startTermHostBroker, type BrokerHandle } from "./term-host-broker.ts";
import { acceptWebSocket, wsConnect, type WsConn } from "./ws.ts";
import { servePtyOverWs, relayWsToWs } from "./term-pty-bridge.ts";

let pass = 0, fail = 0;
const check = (name: string, cond: boolean, detail = ""): void => {
  if (cond) { pass++; console.log(`  ✅ ${name}${detail ? ` — ${detail}` : ""}`); }
  else { fail++; console.log(`  ❌ ${name}${detail ? ` — ${detail}` : ""}`); }
};
const delay = (ms: number): Promise<void> => new Promise((r) => setTimeout(r, ms));
const MB = 1024 * 1024;

/** Cierra un servidor de prueba SIN esperar a sus conexiones: `close()` a secas se queda colgado
 *  mientras un socket siga abierto, y aquí los sockets son justo los que se dejaron atorados a
 *  propósito. `closeAllConnections` los corta primero. */
function shutdown(server: Server): void {
  try { (server as unknown as { closeAllConnections?: () => void }).closeAllConnections?.(); } catch { /* ya */ }
  try { server.close(); } catch { /* ya */ }
}

/** Puerto efímero alto y aleatorio — NUNCA el 8799 del servicio real. */
const pickPort = (): number => 19000 + Math.floor(Math.random() * 900);
const TOKEN = `probe-topes-${Math.random().toString(36).slice(2)}`;
const HOME = process.env.AXON_TERM_BROKER_HOME ?? homedir();
const SHELL = process.env.SHELL ?? "/bin/bash";

// ─────────────────────────────────────────────────────────────────────────────────────────────
// 1) TECHO DE SESIONES — a nivel de pool (la unidad donde vive el hallazgo)
// ANTES del fix: la 4ª sesión se creaba igual y el comando corría → `pool.size` acababa en 4.
// ─────────────────────────────────────────────────────────────────────────────────────────────
async function testPoolCap(): Promise<void> {
  console.log("— 1) ShellSessionPool: techo de sesiones concurrentes —");
  const pool = new ShellSessionPool({ shell: SHELL, loginArgs: ["-l"], home: HOME, maxSessions: 3 });

  const run = (id: string): Promise<{ code: number | null; error?: string; out: string }> =>
    new Promise((resolve) => {
      let out = "";
      pool.run(id, "echo OK-$$", (c) => { out += c.data; }, (code, error) => resolve({ code, error, out }));
    });

  const r1 = await run("s1");
  const r2 = await run("s2");
  const r3 = await run("s3");
  check("las 3 primeras sesiones corren", !r1.error && !r2.error && !r3.error,
    `codes=${r1.code},${r2.code},${r3.code}`);
  check("el pool reporta 3 sesiones vivas", pool.size === 3, `size=${String(pool.size)}`);

  const r4 = await run("s4");
  check("la 4ª sesión se RECHAZA (no se cuelga, no crashea)", !!r4.error, `error=${r4.error ?? "(ninguno)"}`);
  check("el rechazo dice SESSION_LIMIT y nombra el tope", /SESSION_LIMIT/.test(r4.error ?? "") && /3/.test(r4.error ?? ""));
  check("el rechazo NO deja sesión zombi", pool.size === 3, `size=${String(pool.size)}`);

  // Lo que más importa de un rechazo limpio: el pool sigue SIRVIENDO a quien ya estaba.
  const r1b = await run("s1");
  check("una sesión ya existente sigue funcionando tras el rechazo", !r1b.error && r1b.code === 0);

  // Y liberar un hueco vuelve a admitir.
  pool.close("s2");
  check("cerrar una sesión libera el hueco", pool.size === 2, `size=${String(pool.size)}`);
  const r5 = await run("s5");
  check("con hueco libre, una sesión nueva SÍ entra", !r5.error && r5.code === 0);

  pool.closeAll();
  check("closeAll deja el pool en 0", pool.size === 0, `size=${String(pool.size)}`);
}

// ─────────────────────────────────────────────────────────────────────────────────────────────
// 2) TECHO DE SESIONES — end-to-end sobre HTTP (el rechazo que VE el cliente)
// ANTES del fix: la 3ª sesión respondía exit 0 como cualquier otra.
// ─────────────────────────────────────────────────────────────────────────────────────────────
interface SseResult { status: number; body: string; }

function postRun(port: number, session: string, cmd: string, token = TOKEN): Promise<SseResult> {
  return new Promise((resolve, reject) => {
    const payload = JSON.stringify({ cmd, session });
    const req = httpRequest(
      { host: "127.0.0.1", port, path: "/run", method: "POST",
        headers: { Authorization: `Bearer ${token}`, "Content-Type": "application/json", "Content-Length": Buffer.byteLength(payload) } },
      (res) => {
        let body = "";
        res.setEncoding("utf8");
        res.on("data", (d: string) => { body += d; });
        res.on("end", () => resolve({ status: res.statusCode ?? 0, body }));
      },
    );
    req.on("error", reject);
    req.end(payload);
  });
}

function getHealth(port: number): Promise<number> {
  return new Promise((resolve, reject) => {
    const req = httpRequest({ host: "127.0.0.1", port, path: "/health", method: "GET",
      headers: { Authorization: `Bearer ${TOKEN}` } }, (res) => {
      res.resume();
      res.on("end", () => resolve(res.statusCode ?? 0));
    });
    req.on("error", reject);
    req.end();
  });
}

async function testBrokerSessionCap(): Promise<void> {
  console.log("\n— 2) broker HTTP: la sesión que pasa del tope recibe un error LIMPIO —");
  const port = pickPort();
  let handle: BrokerHandle | null = null;
  try {
    handle = startTermHostBroker({ port, token: TOKEN, home: HOME, shell: SHELL, socketPath: null, maxSessions: 2 });
    await handle.ready;

    const a = await postRun(port, "e2e-a", "echo A");
    const b = await postRun(port, "e2e-b", "echo B");
    check("sesión 1 corre", /"type":"exit","code":0/.test(a.body), `status=${a.status}`);
    check("sesión 2 corre", /"type":"exit","code":0/.test(b.body), `status=${b.status}`);

    const c = await postRun(port, "e2e-c", "echo C");
    check("sesión 3 (sobre el tope) recibe `event: error`", /event: error/.test(c.body) && /SESSION_LIMIT/.test(c.body),
      c.body.split("\n").find((l) => l.startsWith("data:") && l.includes("SESSION_LIMIT"))?.slice(0, 120) ?? "(sin SESSION_LIMIT)");
    check("el rechazo cierra el stream con [DONE] (el widget no se cuelga)", /\[DONE\]/.test(c.body));
    check("el rechazo NO ejecutó el comando", !/"chunk":"C/.test(c.body));

    check("el broker SIGUE VIVO tras el rechazo (/health 200)", (await getHealth(port)) === 200);
    const a2 = await postRun(port, "e2e-a", "echo A2");
    check("y sigue sirviendo a las sesiones que ya tenía", /"type":"exit","code":0/.test(a2.body));
  } finally {
    handle?.close();
  }
}

// ─────────────────────────────────────────────────────────────────────────────────────────────
// 3) TECHO DE PTYs — el mismo hallazgo por su peor camino: `/pty` no llevaba NINGUNA cuenta.
// ANTES del fix: el 2º upgrade también recibía su PTY (y el 200º, y el 2000º).
// ─────────────────────────────────────────────────────────────────────────────────────────────
async function testPtyCap(): Promise<void> {
  console.log("\n— 3) broker /pty: techo de PTYs concurrentes —");
  const port = pickPort();
  let handle: BrokerHandle | null = null;
  let first: WsConn | null = null;
  try {
    handle = startTermHostBroker({ port, token: TOKEN, home: HOME, shell: SHELL, socketPath: null, maxPtys: 1 });
    await handle.ready;

    first = await wsConnect(`ws://127.0.0.1:${port}/pty?cols=80&rows=24`, { headers: { Authorization: `Bearer ${TOKEN}` } });
    check("el 1er /pty se acepta", !!first);

    let err = "";
    try { await wsConnect(`ws://127.0.0.1:${port}/pty`, { headers: { Authorization: `Bearer ${TOKEN}` } }); }
    catch (e) { err = e instanceof Error ? e.message : String(e); }
    check("el 2º /pty (sobre el tope) se RECHAZA en el handshake", /503/.test(err), `err=${err || "(se aceptó)"}`);

    check("el broker sigue vivo tras el rechazo (/health 200)", (await getHealth(port)) === 200);

    // Cerrar el primero libera el hueco.
    first.close(1000, "fin del check");
    first = null;
    await delay(500);
    let second: WsConn | null = null;
    try { second = await wsConnect(`ws://127.0.0.1:${port}/pty`, { headers: { Authorization: `Bearer ${TOKEN}` } }); } catch { /* queda null */ }
    check("al cerrar el 1º, un /pty nuevo SÍ entra (el contador baja)", !!second);
    second?.close(1000, "fin del check");
    await delay(300);
  } finally {
    try { first?.close(1000, "cleanup"); } catch { /* ya */ }
    handle?.close();
  }
}

// ─────────────────────────────────────────────────────────────────────────────────────────────
// 4) BACKPRESSURE PTY→WS con un CLIENTE LENTO de verdad (un socket que nunca lee).
// ANTES del fix: el buffer del socket del servidor crecía sin techo — el probe abortaba al pasar de
// 24 MiB en menos de 2 s (`yes` dentro del PTY). Con el fix se queda pegado al high-water.
// ─────────────────────────────────────────────────────────────────────────────────────────────
async function testPtyBackpressure(): Promise<void> {
  console.log("\n— 4) relay PTY→WS: un cliente que no drena NO hace crecer el buffer —");
  const HIGH_WATER = 256 * 1024;      // tope blando del test (el default de producción es 1 MiB)
  const ABORT_AT = 24 * MB;           // si llega aquí, NO hay backpressure: se corta para no comerse la RAM
  const PASS_UNDER = 2 * MB;          // con el fix debe quedarse en ~HIGH_WATER + un chunk

  const port = pickPort();
  let srvSocket: Duplex | null = null;
  let conn: WsConn | null = null;
  const server: Server = createServer();
  server.on("upgrade", (req: IncomingMessage, socket: Duplex) => {
    srvSocket = socket;
    conn = acceptWebSocket(req, socket, { highWaterBytes: HIGH_WATER, maxBufferBytes: 64 * MB });
    if (!conn) { socket.destroy(); return; }
    // `yes` dentro de un PTY real: el productor más rápido y honesto que hay.
    servePtyOverWs(conn, { cmd: "exec yes BACKPRESSURE-PROBE-LINE-0123456789", cwd: HOME, env: buildSessionEnv(HOME) });
  });
  await new Promise<void>((r) => server.listen(port, "127.0.0.1", r));

  // Cliente LENTO: hace el handshake y PAUSA el socket — nunca lee un byte más.
  const clientSocket = await new Promise<Duplex>((resolve, reject) => {
    const req = httpRequest({ host: "127.0.0.1", port, path: "/pty", method: "GET",
      headers: { Connection: "Upgrade", Upgrade: "websocket", "Sec-WebSocket-Version": "13", "Sec-WebSocket-Key": Buffer.from("0123456789abcdef").toString("base64") } });
    req.on("upgrade", (_res, socket) => { socket.pause(); resolve(socket); });
    req.on("error", reject);
    req.end();
  });

  let peak = 0;
  let aborted = false;
  for (let i = 0; i < 60; i++) {           // ~3 s de flood
    await delay(50);
    const buffered = (srvSocket as unknown as { writableLength?: number } | null)?.writableLength ?? 0;
    if (buffered > peak) peak = buffered;
    if (peak > ABORT_AT) { aborted = true; break; }
  }

  check("el buffer del socket se queda ACOTADO con un cliente que no drena",
    !aborted && peak < PASS_UNDER,
    `pico=${(peak / MB).toFixed(2)} MiB (tope blando ${(HIGH_WATER / 1024).toFixed(0)} KiB, corte del probe ${ABORT_AT / MB} MiB)`);
  check("el productor (el PTY) quedó PAUSADO, no descartando datos", conn !== null && (conn as WsConn).backpressured);

  try { (conn as WsConn | null)?.close(1000, "fin del check"); } catch { /* ya */ }
  try { clientSocket.destroy(); } catch { /* ya */ }
  shutdown(server);
  await delay(400); // que el SIGHUP/SIGKILL del `yes` aterrice antes de seguir
}

// ─────────────────────────────────────────────────────────────────────────────────────────────
// 5) BACKPRESSURE WS↔WS (el modo HOST: axon-en-contenedor relaya hacia el broker).
// ANTES del fix: `a.onMessage → b.send` sin mirar nada; el buffer de `b` crecía con todo el flood.
// ─────────────────────────────────────────────────────────────────────────────────────────────
async function testRelayBackpressure(): Promise<void> {
  console.log("\n— 5) relay WS↔WS: si el peer no drena, se PAUSA la fuente —");
  const HIGH_WATER = 256 * 1024;
  const FRAMES = 400, FRAME_SIZE = 64 * 1024;   // 25 MiB de flood
  const PASS_UNDER = 4 * MB;

  const portA = pickPort();
  const portB = pickPort() + 1;

  // Servidor B: completa el handshake y PAUSA su socket — el peer que NO drena.
  const serverB = createServer();
  serverB.on("upgrade", (req: IncomingMessage, socket: Duplex) => {
    const c = acceptWebSocket(req, socket);
    if (!c) { socket.destroy(); return; }
    socket.pause();
  });
  await new Promise<void>((r) => serverB.listen(portB, "127.0.0.1", r));

  // Servidor A: acepta al "browser" y relaya hacia B.
  let connA: WsConn | null = null;
  const serverA = createServer();
  const relayReady = new Promise<void>((resolve) => {
    serverA.on("upgrade", (req: IncomingMessage, socket: Duplex) => {
      void (async () => {
        const a = acceptWebSocket(req, socket, { highWaterBytes: HIGH_WATER, maxBufferBytes: 64 * MB });
        if (!a) { socket.destroy(); return; }
        connA = a;
        const b = await wsConnect(`ws://127.0.0.1:${portB}/pty`, { headers: {} });
        (b as unknown as { __probeB?: WsConn }).__probeB = b;
        relayWsToWs(a, b);
        (globalThis as unknown as { __probeConnB?: WsConn }).__probeConnB = b;
        resolve();
      })();
    });
  });
  await new Promise<void>((r) => serverA.listen(portA, "127.0.0.1", r));

  // El flooder va con umbrales ENORMES a propósito: si se quedara con los de producción, su propia
  // válvula dura (8 MiB) lo cerraría a mitad del flood y el probe mediría un relay que ya no recibe
  // nada — "acotado" por la razón equivocada. Aquí el sujeto de la prueba es el relay, no el flooder.
  const flooder = await wsConnect(`ws://127.0.0.1:${portA}/pty`, { headers: {}, highWaterBytes: 512 * MB, maxBufferBytes: 512 * MB });
  await relayReady;

  const payload = Buffer.alloc(FRAME_SIZE, 0x41);
  for (let i = 0; i < FRAMES; i++) flooder.sendBinary(payload);
  await delay(2000);

  const connB = (globalThis as unknown as { __probeConnB?: WsConn }).__probeConnB!;
  const bufferedB = connB.bufferedBytes;
  check("el flood LLEGÓ hasta el peer lento (la prueba no pasa por no haber movido nada)", bufferedB > 0,
    `buffered=${(bufferedB / MB).toFixed(2)} MiB`);
  check("el buffer del peer lento queda ACOTADO",
    bufferedB < PASS_UNDER,
    `buffered=${(bufferedB / MB).toFixed(2)} MiB de ${(FRAMES * FRAME_SIZE / MB).toFixed(0)} MiB inyectados`);
  check("la fuente quedó PAUSADA (dejó de leer del socket del cliente)", connA !== null && (connA as WsConn).isPaused);

  try { flooder.close(1000, "fin del check"); } catch { /* ya */ }
  try { connA?.close(1000, "fin del check"); } catch { /* ya */ }
  try { connB.close(1000, "fin del check"); } catch { /* ya */ }
  shutdown(serverA);
  shutdown(serverB);
}

// ─────────────────────────────────────────────────────────────────────────────────────────────
// 6) La CONFIGURACIÓN documentada es la que manda. Las pruebas de arriba pasan los topes por el
// objeto de opciones; lo que el usuario tiene en las manos son las env vars de `term-broker.env`, y
// eso es lo que se verifica aquí — que la doc no mienta.
// ─────────────────────────────────────────────────────────────────────────────────────────────
async function testEnvConfig(): Promise<void> {
  console.log("\n— 6) los topes se configuran por las env vars que documenta term-broker.env —");
  const port = pickPort();
  const prevSessions = process.env.AXON_TERM_BROKER_MAX_SESSIONS;
  const prevPtys = process.env.AXON_TERM_BROKER_MAX_PTYS;
  process.env.AXON_TERM_BROKER_MAX_SESSIONS = "1";
  process.env.AXON_TERM_BROKER_MAX_PTYS = "1";
  let handle: BrokerHandle | null = null;
  try {
    // SIN `maxSessions`/`maxPtys` en las opciones: si el tope aplica, salió de la env.
    handle = startTermHostBroker({ port, token: TOKEN, home: HOME, shell: SHELL, socketPath: null });
    await handle.ready;

    const one = await postRun(port, "env-a", "echo A");
    const two = await postRun(port, "env-b", "echo B");
    check("AXON_TERM_BROKER_MAX_SESSIONS=1 deja pasar la 1ª", /"type":"exit","code":0/.test(one.body));
    check("…y frena la 2ª con SESSION_LIMIT", /SESSION_LIMIT/.test(two.body));

    const w1 = await wsConnect(`ws://127.0.0.1:${port}/pty`, { headers: { Authorization: `Bearer ${TOKEN}` } });
    let err = "";
    try { await wsConnect(`ws://127.0.0.1:${port}/pty`, { headers: { Authorization: `Bearer ${TOKEN}` } }); }
    catch (e) { err = e instanceof Error ? e.message : String(e); }
    check("AXON_TERM_BROKER_MAX_PTYS=1 frena el 2º /pty con 503", /503/.test(err), `err=${err || "(se aceptó)"}`);
    w1.close(1000, "fin del check");
    await delay(300);
  } finally {
    handle?.close();
    if (prevSessions === undefined) delete process.env.AXON_TERM_BROKER_MAX_SESSIONS; else process.env.AXON_TERM_BROKER_MAX_SESSIONS = prevSessions;
    if (prevPtys === undefined) delete process.env.AXON_TERM_BROKER_MAX_PTYS; else process.env.AXON_TERM_BROKER_MAX_PTYS = prevPtys;
  }
}

// ── main ─────────────────────────────────────────────────────────────────────────────────────
// Red de seguridad: si algo se cuelga, el probe no se queda vivo para siempre (ni sus `yes`).
const watchdog = setTimeout(() => {
  console.error("\n  ⏱️  el probe pasó de 120 s — se corta (algo se colgó)");
  process.exit(2);
}, 120_000);
watchdog.unref?.();

try {
  await testPoolCap();
  await testBrokerSessionCap();
  await testPtyCap();
  await testPtyBackpressure();
  await testRelayBackpressure();
  await testEnvConfig();
} catch (e) {
  fail++;
  console.error(`  ❌ el probe reventó: ${e instanceof Error ? e.stack : String(e)}`);
}

console.log(`\n  ${pass} ✅   ${fail} ❌`);
process.exit(fail === 0 ? 0 : 1);
