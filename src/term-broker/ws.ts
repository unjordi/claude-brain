// ⚠️ ESTE ARCHIVO SE VENDORIZA A CORTEX. Existe una COPIA byte-a-byte en `cortex/src/term-broker/`, que es
// la que instala y corre `cortex-term-broker.service`. Se edita AQUÍ (axon es la fuente) y después se
// RE-VENDORIZA allá: copiar los cinco módulos, regenerar `SHA256SUMS`, actualizar el commit anotado en
// `PROCEDENCIA.md` y en `NOTICE`, y correr `probe-topes.ts` + `probe-instalador.sh`. El contrato completo,
// con su anti-drift de tres chequeos, está en `cortex/src/term-broker/PROCEDENCIA.md`. Si cambias esto y no
// re-vendorizas, el broker que sirve al usuario se queda atrás sin que nada lo señale.
// src/server/ws.ts — WebSocket MÍNIMO (RFC 6455) hecho a mano, SIN dep `ws`.
//
// POR QUÉ a mano: axon tiene UNA sola dep de runtime (@anthropic-ai/claude-agent-sdk) y el ethos es
// minimalista + "corre .ts directo sin build". El PTY interactivo (pty-session.ts) necesita un canal
// BIDIRECCIONAL en tiempo real (stdin del cliente <-> stdout del PTY) — WebSocket es el transporte natural.
// En vez de sumar la dep `ws`, implementamos aquí lo justo: handshake + codec de frames (text/binary/ping/
// pong/close) para SERVIDOR (browser -> axon) y CLIENTE (axon-en-contenedor -> broker host-side). Es puro
// Node (node:http + node:crypto), probe-testeable (src/probe-term-pty.ts).
//
// ALCANCE deliberado: frames enmascarados del cliente (obligatorio por RFC), continuación básica, auto-pong,
// cap de tamaño defensivo. NO negocia extensiones (permessage-deflate) ni subprotocolos — no hacen falta para
// un stream de terminal. Los frames de terminal son chicos; la salida grande del PTY va en muchos frames.

import { createHash, randomBytes } from "node:crypto";
import { request as httpRequest } from "node:http";
import { request as httpsRequest } from "node:https";
import type { IncomingMessage } from "node:http";
import type { Duplex } from "node:stream";

/** GUID mágico del RFC 6455 para derivar Sec-WebSocket-Accept. */
const WS_GUID = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11";
/** Cap defensivo de payload por mensaje (16 MiB) — un frame más grande cierra la conexión. */
const MAX_MESSAGE_BYTES = 16 * 1024 * 1024;

// ── BACKPRESSURE (el techo del relay) ─────────────────────────────────────────────────────────
// `socket.write()` devuelve `false` cuando lo escrito ya no cabe y Node lo está guardando EN MEMORIA.
// Ignorar ese retorno —que es lo que hacía esta clase— significa que un cliente que lee más lento que
// el PTY hace crecer ese buffer sin ningún techo: el PTY produce a la velocidad del kernel, el socket
// drena a la del cliente, y la diferencia se acumula en el heap del broker. No es hipotético: `yes`
// dentro de un PTY llenó 24 MiB en menos de 3 s (medido con `probe-topes.ts` contra el código previo).
//
// POLÍTICA ELEGIDA: **pausar la fuente, NO descartar bytes.** Un stream de terminal no tolera huecos
// (un byte perdido corrompe una secuencia ANSI y con ella la pantalla), así que descartar estaría mal
// aquí; lo correcto es dejar de bombear hasta que el cliente drene. Quien produce (el PTY, o el socket
// del peer en el relay WS↔WS) sabe pausarse — esta clase solo AVISA:
//   • `backpressured` pasa a `true` al superar `highWaterBytes`;
//   • el callback de `onDrain()` se dispara cuando el socket ya drenó y se puede reanudar.
// El buffer queda acotado a `highWaterBytes` + el chunk en vuelo (≤ 64 KiB de un pipe).
//
// Y una VÁLVULA DURA por si pausar no basta (cliente colgado que jamás vuelve a leer, con datos ya
// encolados): al pasar `maxBufferBytes` se cierra ESA conexión con 1013. Es degradar, no morir — se
// pierde una terminal, nunca el broker del que cuelgan todas las demás.
/** Buffer pendiente a partir del cual se considera que el cliente NO drena (default 1 MiB). */
const DEFAULT_HIGH_WATER_BYTES = positiveEnv(process.env.AXON_TERM_BROKER_WS_HIGH_WATER, 1024 * 1024);
/** Válvula dura: buffer pendiente que cierra ESA conexión (default 8 MiB). Nunca tumba el proceso. */
const DEFAULT_MAX_BUFFER_BYTES = positiveEnv(process.env.AXON_TERM_BROKER_WS_MAX_BUFFER, 8 * 1024 * 1024);
/** Cada cuánto se manda un ping de keepalive (default 30 s). `0` lo APAGA. */
const DEFAULT_KEEPALIVE_MS = positiveEnv(process.env.AXON_TERM_BROKER_WS_KEEPALIVE_MS, 30_000);

/** Lee un entero POSITIVO de una env var; cualquier basura (vacío, 0, negativo, NaN) cae al default. */
function positiveEnv(raw: string | undefined, def: number): number {
  const n = Number(raw);
  return Number.isFinite(n) && n > 0 ? Math.floor(n) : def;
}

/** Lo que se sabe cuando una conexión empieza a quedarse atrás. */
export interface PressureInfo {
  /** Bytes pendientes en el buffer AHORA. */
  readonly pendingBytes: number;
  /** La marca a partir de la cual se pausa al productor. */
  readonly highWaterBytes: number;
  /** El techo que, de cruzarse, corta la conexión. */
  readonly maxBufferBytes: number;
}

export interface WsConnOptions {
  /** Buffer pendiente que marca `backpressured` (default: `AXON_TERM_BROKER_WS_HIGH_WATER` o 1 MiB). */
  readonly highWaterBytes?: number;
  /** Buffer pendiente que cierra la conexión (default: `AXON_TERM_BROKER_WS_MAX_BUFFER` o 8 MiB). */
  readonly maxBufferBytes?: number;
  /** Periodo del ping de keepalive en ms (default: `AXON_TERM_BROKER_WS_KEEPALIVE_MS` o 30 s). */
  readonly keepaliveMs?: number;
  /** Temporizador inyectable — el probe pasa un reloj falso para no esperar 30 s de verdad. */
  readonly setInterval?: (fn: () => void, ms: number) => { unref?: () => void };
  /** Pareja de `setInterval`. Inyectable por la misma razón. */
  readonly clearInterval?: (h: unknown) => void;
}

const OP_CONT = 0x0;
const OP_TEXT = 0x1;
const OP_BIN = 0x2;
const OP_CLOSE = 0x8;
const OP_PING = 0x9;
const OP_PONG = 0xa;

function acceptKey(clientKey: string): string {
  return createHash("sha1").update(clientKey + WS_GUID).digest("base64");
}

export interface WsMessage {
  readonly data: Buffer;
  readonly binary: boolean;
}

type MsgHandler = (msg: WsMessage) => void;
type CloseHandler = (code: number, reason: string) => void;
type ErrHandler = (err: Error) => void;
type DrainHandler = () => void;

/**
 * Conexión WebSocket sobre un socket ya "upgradeado". `isServer` decide el masking: el SERVIDOR nunca
 * enmascara sus frames; el CLIENTE SIEMPRE los enmascara (RFC 6455 §5.3). Never-throws hacia afuera: los
 * errores van por `onError` y siempre termina en `onClose` exactamente una vez.
 */
export class WsConn {
  private readonly socket: Duplex;
  private readonly isServer: boolean;
  private buf: Buffer = Buffer.alloc(0);
  private closed = false;
  private closeSent = false;
  // Acumulador de mensajes fragmentados (continuación).
  private fragOpcode = 0;
  private fragChunks: Buffer[] = [];

  private msgCb: MsgHandler | null = null;
  private closeCb: CloseHandler | null = null;
  private errCb: ErrHandler | null = null;
  private drainCb: DrainHandler | null = null;
  // Backpressure (ver el bloque de arriba): umbrales por conexión + el flag de "ya pedí un drain".
  private readonly highWaterBytes: number;
  private readonly maxBufferBytes: number;
  private waitingDrain = false;

  constructor(socket: Duplex, isServer: boolean, opts: WsConnOptions = {}) {
    this.socket = socket;
    this.isServer = isServer;
    this.highWaterBytes = opts.highWaterBytes && opts.highWaterBytes > 0 ? opts.highWaterBytes : DEFAULT_HIGH_WATER_BYTES;
    this.maxBufferBytes = opts.maxBufferBytes && opts.maxBufferBytes > 0 ? opts.maxBufferBytes : DEFAULT_MAX_BUFFER_BYTES;
    socket.on("data", (d: Buffer) => this.onData(d));
    socket.on("close", () => this.fireClose(1006, "socket closed"));
    socket.on("error", (e: Error) => { if (this.errCb) this.errCb(e); this.fireClose(1006, e.message); });
    this.armarKeepalive(opts);
  }

  // ── Keepalive ────────────────────────────────────────────────────────────────────────────────────────
  // Por qué existe: `ping()` estaba implementado y NADIE lo llamaba. Una laptop que suspende deja la
  // conexión HALF-OPEN — el socket nunca emite `close`, así que el techo de PTYs concurrentes cuenta hacia
  // arriba y no baja jamás; la única reparación era reiniciar el broker, que mata TODAS las terminales.
  //
  // El ciclo es de UNA sola pregunta, sin relojes ni umbrales que comparar: en cada tick, si quedó un ping
  // SIN contestar desde el tick anterior, el peer no está; si no, se manda uno nuevo. Elegido así a
  // propósito sobre la variante "guardar lastPongAt y comparar contra un umbral": ahí el umbral y el
  // periodo son dos números que pueden desalinearse (con umbral == periodo, el cierre real cae al SEGUNDO
  // tick, no al primero — un detalle que se lee mal y se prueba peor).
  private esperandoPong = false;
  /** Código y razón con que NOSOTROS cerramos, para no reportar el 1006 genérico del socket. */
  private motivoLocal: { code: number; reason: string } | null = null;
  private pressureCb: ((info: PressureInfo) => void) | null = null;
  private keepaliveHandle: unknown = null;
  private keepaliveClear: ((h: unknown) => void) | null = null;

  private armarKeepalive(opts: WsConnOptions): void {
    const ms = opts.keepaliveMs !== undefined ? opts.keepaliveMs : DEFAULT_KEEPALIVE_MS;
    if (!(ms > 0)) return;                       // 0 o basura ⇒ apagado, sin timer
    const si = opts.setInterval ?? ((fn, n) => setInterval(fn, n));
    this.keepaliveClear = opts.clearInterval ?? ((h) => clearInterval(h as NodeJS.Timeout));
    const h = si(() => this.tickKeepalive(), ms);
    // Un keepalive no es motivo para que el proceso siga vivo.
    if (h && typeof h.unref === "function") h.unref();
    this.keepaliveHandle = h;
  }

  private tickKeepalive(): void {
    if (this.closed || this.closeSent) { this.pararKeepalive(); return; }
    // El keepalive solo puede concluir algo cuando el silencio es INFORMATIVO. Hay dos estados en que no
    // lo es, y en los dos el veredicto "sin pong" mataría una conexión perfectamente viva:
    //
    //  • PAUSADA por contrapresión: `pause()` corta los eventos `data` del socket, o sea también los
    //    PONG. El peer contestó y su respuesta está en el buffer del kernel, ilegible por diseño. Sin
    //    esta guarda, un `find /` en la terminal la mata a media ejecución POR IR LENTA — y el keepalive
    //    existía justo para preservar conexiones, no para cortarlas.
    //  • Con BUFFER pendiente: el ping viaja EN BANDA, detrás de lo encolado. Un cliente vivo pero lento
    //    (un tethering con 1 MiB por delante) no alcanza a recibirlo dentro del tick, mucho menos a
    //    contestarlo.
    //
    // En ambos casos se salta el veredicto y se espera al siguiente tick. Un half-open real NO drena ni
    // se despausa, así que el buffer se queda quieto y la válvula dura (`maxBufferBytes`) lo corta por su
    // cuenta: la conexión muerta sigue teniendo quien la cierre.
    if (this.isPaused || this.bufferedBytes > 0) return;
    if (this.esperandoPong) { this.close(1011, "keepalive: sin pong"); return; }
    this.esperandoPong = true;
    this.ping();
  }

  private pararKeepalive(): void {
    if (this.keepaliveHandle !== null && this.keepaliveClear) this.keepaliveClear(this.keepaliveHandle);
    this.keepaliveHandle = null;
  }

  onMessage(cb: MsgHandler): this { this.msgCb = cb; return this; }
  onClose(cb: CloseHandler): this { this.closeCb = cb; return this; }
  onError(cb: ErrHandler): this { this.errCb = cb; return this; }
  /** Se dispara cuando el socket ya drenó tras haber estado en backpressure: reanuda al productor. */
  onDrain(cb: DrainHandler): this { this.drainCb = cb; return this; }

  /** Bytes que Node tiene EN MEMORIA esperando que el cliente los lea. 0 = el cliente va al día. */
  get bufferedBytes(): number {
    const n = (this.socket as unknown as { writableLength?: number }).writableLength;
    return typeof n === "number" ? n : 0;
  }

  /** ¿El cliente dejó de drenar? Quien produce debe PAUSARSE mientras esto sea `true`. */
  get backpressured(): boolean { return this.bufferedBytes > this.highWaterBytes; }

  /** ¿Se dejó de LEER de este socket? (lo usa el relay WS↔WS para frenar a la fuente). */
  get isPaused(): boolean {
    const f = (this.socket as unknown as { isPaused?: () => boolean }).isPaused;
    return typeof f === "function" ? f.call(this.socket) : false;
  }

  /** Deja de leer de este socket — la mitad de ENTRADA del backpressure. Never-throws. */
  pause(): void { try { this.socket.pause(); } catch { /* socket muerto */ } }
  /** Reanuda la lectura. Never-throws. */
  resume(): void { try { this.socket.resume(); } catch { /* socket muerto */ } }

  /** Envía un mensaje. `binary=false` -> frame TEXT; `true` -> frame BINARY. */
  send(data: string | Buffer, binary = false): void {
    if (this.closed) return;
    const payload = typeof data === "string" ? Buffer.from(data, "utf8") : data;
    this.writeFrame(binary ? OP_BIN : OP_TEXT, payload);
  }

  sendText(s: string): void { this.send(s, false); }
  sendBinary(b: Buffer): void { this.send(b, true); }

  ping(): void { if (!this.closed) this.writeFrame(OP_PING, Buffer.alloc(0)); }

  /** Aviso de que esta conexión se está quedando atrás, ANTES de que la válvula dura la corte (M-2).
   *  Se emite una vez por episodio de presión; al drenar, se rearma. */
  onPressure(cb: (info: PressureInfo) => void): this { this.pressureCb = cb; return this; }

  /** Cierra ordenadamente (envía un frame CLOSE una vez). */
  close(code = 1000, reason = ""): void {
    // El keepalive se para AQUÍ, no solo en `fireClose`: entre `close()` y el `close` del socket puede no
    // haber nunca un evento (un peer que no contesta, un socket que no lo emite), y ahí el timer quedaría
    // huérfano — justo la fuga que este mecanismo existe para cerrar.
    this.pararKeepalive();
    if (this.closed || this.closeSent) { this.destroy(); return; }
    this.closeSent = true;
    // Se recuerda POR QUÉ cerramos. Sin esto, el cierre le llega al consumidor como el 1006 genérico del
    // socket ("socket closed") y la causa real se pierde: un techo alcanzado, un keepalive vencido y un
    // cable desconectado se vuelven indistinguibles justo donde hay que decidir qué hacer.
    this.motivoLocal = { code, reason };
    const rb = Buffer.from(reason, "utf8");
    const payload = Buffer.alloc(2 + rb.length);
    payload.writeUInt16BE(code, 0);
    rb.copy(payload, 2);
    try { this.writeFrame(OP_CLOSE, payload); } catch { /* socket muerto */ }
    // Da un instante para que el CLOSE salga y luego cierra el socket.
    const t = setTimeout(() => this.destroy(), 200);
    if (typeof t.unref === "function") t.unref();
  }

  private destroy(): void {
    try { this.socket.end(); } catch { /* ya */ }
    try { this.socket.destroy(); } catch { /* ya */ }
  }

  private fireClose(code: number, reason: string): void {
    if (this.closed) return;
    this.closed = true;
    this.pararKeepalive();   // por aquí pasan TODAS las vías de cierre, así que el timer nunca queda huérfano
    const m = this.motivoLocal;
    if (this.closeCb) this.closeCb(m ? m.code : code, m ? m.reason : reason);
  }

  private writeFrame(opcode: number, payload: Buffer): void {
    const len = payload.length;
    let header: Buffer;
    let lenByte: number;
    let extLen = 0;
    if (len < 126) { lenByte = len; }
    else if (len < 65536) { lenByte = 126; extLen = 2; }
    else { lenByte = 127; extLen = 8; }

    const maskLen = this.isServer ? 0 : 4;
    header = Buffer.alloc(2 + extLen + maskLen);
    header[0] = 0x80 | opcode; // FIN=1
    header[1] = (this.isServer ? 0 : 0x80) | lenByte;
    if (extLen === 2) header.writeUInt16BE(len, 2);
    else if (extLen === 8) { header.writeUInt32BE(0, 2); header.writeUInt32BE(len, 6); }

    let out: Buffer;
    if (this.isServer) {
      out = Buffer.concat([header, payload]);
    } else {
      const mask = randomBytes(4);
      mask.copy(header, 2 + extLen);
      const masked = Buffer.allocUnsafe(len);
      for (let i = 0; i < len; i++) masked[i] = payload[i] ^ mask[i & 3];
      out = Buffer.concat([header, masked]);
    }
    try { this.socket.write(out); } catch (e) { if (this.errCb) this.errCb(e as Error); return; }
    this.checkBackpressure(opcode);
  }

  /**
   * Mira cuánto quedó pendiente DESPUÉS de escribir y actúa. Never-throws (lo llama `writeFrame`, que
   * a su vez lo llaman los relays: una excepción aquí tumbaría al broker entero, que es justo lo que
   * este cambio existe para evitar).
   *
   * Se salta los frames de CLOSE: si el techo duro ya disparó, el propio CLOSE que lo anuncia no debe
   * volver a disparar el cierre (recursión) — ese frame se manda "a como dé lugar" y el socket muere.
   */
  private checkBackpressure(opcode: number): void {
    if (opcode === OP_CLOSE || this.closed) return;
    try {
      const pending = this.bufferedBytes;
      if (pending > this.maxBufferBytes) {
        // Válvula dura: el cliente no drena ni pausando. Se cierra ESTA conexión, no el proceso.
        // La razón lleva los NÚMEROS: sin ellos, quien recibe el cierre no puede distinguir "tu red se
        // atoró" de "el broker se cayó", que es el mismo problema que arrastraba el 1006 genérico.
        this.close(1013, `cliente no drena: ${pending} B pendientes sobre el techo de ${this.maxBufferBytes} B`);
        return;
      }
      if (pending > this.highWaterBytes && !this.waitingDrain) {
        // AVISO antes del hachazo (M-2): la válvula dura mataba la sesión sin que nadie hubiera dicho que
        // la conexión venía quedándose atrás. Se emite UNA vez por episodio de presión — al drenar se
        // rearma —, así que no puede convertirse en un chorro de eventos.
        if (this.pressureCb) {
          try { this.pressureCb({ pendingBytes: pending, highWaterBytes: this.highWaterBytes, maxBufferBytes: this.maxBufferBytes }); }
          catch { /* el consumidor decide qué hacer con el aviso; su error no nos mata */ }
        }
        this.waitingDrain = true;
        this.socket.once("drain", () => {
          this.waitingDrain = false;
          if (this.drainCb) { try { this.drainCb(); } catch { /* el productor decide, nosotros no morimos */ } }
        });
      }
    } catch { /* socket en un estado raro: no es motivo para tumbar el broker */ }
  }

  private onData(chunk: Buffer): void {
    this.buf = this.buf.length ? Buffer.concat([this.buf, chunk]) : chunk;
    // Parsea tantos frames completos como haya en el buffer.
    for (;;) {
      if (this.buf.length < 2) return;
      const b0 = this.buf[0];
      const b1 = this.buf[1];
      const fin = (b0 & 0x80) !== 0;
      const opcode = b0 & 0x0f;
      const masked = (b1 & 0x80) !== 0;
      let len = b1 & 0x7f;
      let offset = 2;
      if (len === 126) {
        if (this.buf.length < offset + 2) return;
        len = this.buf.readUInt16BE(offset); offset += 2;
      } else if (len === 127) {
        if (this.buf.length < offset + 8) return;
        const hi = this.buf.readUInt32BE(offset);
        const lo = this.buf.readUInt32BE(offset + 4);
        len = hi * 0x100000000 + lo; offset += 8;
      }
      if (len > MAX_MESSAGE_BYTES) { this.close(1009, "message too big"); return; }
      const maskKey = masked ? this.buf.subarray(offset, offset + 4) : null;
      if (masked) offset += 4;
      if (this.buf.length < offset + len) return; // frame incompleto -> espera más
      let payload = this.buf.subarray(offset, offset + len);
      if (maskKey) {
        const unmasked = Buffer.allocUnsafe(len);
        for (let i = 0; i < len; i++) unmasked[i] = payload[i] ^ maskKey[i & 3];
        payload = unmasked;
      } else {
        payload = Buffer.from(payload); // copia (subarray comparte memoria con this.buf que vamos a recortar)
      }
      this.buf = this.buf.subarray(offset + len);
      this.handleFrame(fin, opcode, payload);
    }
  }

  private handleFrame(fin: boolean, opcode: number, payload: Buffer): void {
    switch (opcode) {
      case OP_PING:
        if (!this.closed) this.writeFrame(OP_PONG, payload);
        return;
      case OP_PONG:
        this.esperandoPong = false;
        return;
      case OP_CLOSE: {
        const code = payload.length >= 2 ? payload.readUInt16BE(0) : 1005;
        const reason = payload.length > 2 ? payload.subarray(2).toString("utf8") : "";
        if (!this.closeSent) { this.closeSent = true; try { this.writeFrame(OP_CLOSE, payload); } catch { /* */ } }
        this.destroy();
        this.fireClose(code, reason);
        return;
      }
      case OP_TEXT:
      case OP_BIN: {
        if (!fin) { this.fragOpcode = opcode; this.fragChunks = [payload]; return; }
        this.deliver(opcode, payload);
        return;
      }
      case OP_CONT: {
        this.fragChunks.push(payload);
        if (fin) {
          const full = Buffer.concat(this.fragChunks);
          const op = this.fragOpcode;
          this.fragChunks = []; this.fragOpcode = 0;
          this.deliver(op, full);
        }
        return;
      }
      default:
        this.close(1002, "unknown opcode");
    }
  }

  private deliver(opcode: number, payload: Buffer): void {
    if (this.msgCb) this.msgCb({ data: payload, binary: opcode === OP_BIN });
  }
}

/** ¿El request es un upgrade a WebSocket válido? (headers Connection/Upgrade + Sec-WebSocket-Key). */
export function isWebSocketUpgrade(req: IncomingMessage): boolean {
  const upgrade = (req.headers.upgrade ?? "").toLowerCase();
  const key = req.headers["sec-websocket-key"];
  return upgrade === "websocket" && typeof key === "string" && key.length > 0;
}

/**
 * Completa el handshake del lado SERVIDOR sobre `socket` (del evento 'upgrade' de http.Server) y devuelve una
 * WsConn lista. Devuelve `null` si el request no es un upgrade WS válido (el caller debe destruir el socket).
 */
export function acceptWebSocket(req: IncomingMessage, socket: Duplex, opts: WsConnOptions = {}): WsConn | null {
  if (!isWebSocketUpgrade(req)) return null;
  const key = req.headers["sec-websocket-key"] as string;
  const headers = [
    "HTTP/1.1 101 Switching Protocols",
    "Upgrade: websocket",
    "Connection: Upgrade",
    `Sec-WebSocket-Accept: ${acceptKey(key)}`,
    "\r\n",
  ].join("\r\n");
  socket.write(headers);
  return new WsConn(socket, true, opts);
}

/** Rechaza un upgrade con un status HTTP crudo (para auth fallida en el handshake) y cierra el socket. */
export function rejectWebSocket(socket: Duplex, status = 401, message = "unauthorized"): void {
  try {
    socket.write(`HTTP/1.1 ${status} ${message}\r\nConnection: close\r\nContent-Length: 0\r\n\r\n`);
  } catch { /* socket ya muerto */ }
  try { socket.destroy(); } catch { /* ya */ }
}

export interface WsConnectOptions extends WsConnOptions {
  readonly headers?: Record<string, string>;
  readonly timeoutMs?: number;
  /**
   * SOCKET UNIX en vez de TCP. Con esto puesto, el host/puerto de la URL se IGNORAN (la URL solo aporta
   * path+query) y el handshake viaja por ese socket. Es el transporte del PTY hacia el broker host-side:
   * el maincar corre en un contenedor y NO alcanza un bind a loopback del host, mientras que abrir un
   * puerto de red sería exponer ejecución de comandos arbitrarios. Ver term-host-broker.ts.
   */
  readonly socketPath?: string;
}

/**
 * Abre una conexión WebSocket como CLIENTE hacia `url` (ws:// o wss://). Resuelve con una WsConn ya
 * handshakeada, o rechaza con Error. Usado por axon (en el contenedor) para hablarle al broker host-side.
 * Con `opts.socketPath` el transporte es un socket unix (la URL solo aporta path+query).
 */
export function wsConnect(url: string, opts: WsConnectOptions = {}): Promise<WsConn> {
  return new Promise((resolve, reject) => {
    let target: URL;
    try { target = new URL(url); } catch (e) { reject(new Error(`URL WS inválida (${url}): ${e instanceof Error ? e.message : String(e)}`)); return; }
    const secure = !opts.socketPath && target.protocol === "wss:";
    const key = randomBytes(16).toString("base64");
    const reqFn = secure ? httpsRequest : httpRequest;
    const req = reqFn({
      protocol: secure ? "https:" : "http:",
      ...(opts.socketPath
        ? { socketPath: opts.socketPath }
        : { hostname: target.hostname, port: target.port || (secure ? 443 : 80) }),
      path: (target.pathname || "/") + (target.search || ""),
      method: "GET",
      headers: {
        Connection: "Upgrade",
        Upgrade: "websocket",
        "Sec-WebSocket-Version": "13",
        "Sec-WebSocket-Key": key,
        ...(opts.headers ?? {}),
      },
      timeout: opts.timeoutMs ?? 8000,
    });
    let settled = false;
    req.on("upgrade", (res, socket) => {
      if (settled) return; settled = true;
      const accept = res.headers["sec-websocket-accept"];
      if (accept !== acceptKey(key)) { try { socket.destroy(); } catch { /* */ } reject(new Error("Sec-WebSocket-Accept inválido")); return; }
      resolve(new WsConn(socket, false, opts));
    });
    req.on("response", (res) => {
      if (settled) return; settled = true;
      // La REASON PHRASE es donde `rejectWebSocket` pone el porqué ("too many pty sessions (7/8)"), y
      // quedarse solo con el número de estado la tiraba: al otro extremo llegaba un `HTTP 503` pelón,
      // indistinguible de cualquier otro rechazo. Un techo alcanzado y un servicio caído piden acciones
      // opuestas — cerrar una terminal que ya no usas, o revisar el broker —, así que el motivo VIAJA.
      const motivo = typeof res.statusMessage === "string" ? res.statusMessage.trim() : "";
      reject(new Error(`WS upgrade rechazado: HTTP ${res.statusCode}${motivo ? ` — ${motivo}` : ""}`));
      req.destroy();
    });
    req.on("error", (e) => { if (settled) return; settled = true; reject(e); });
    req.on("timeout", () => { if (settled) return; settled = true; req.destroy(); reject(new Error("WS connect timeout")); });
    req.end();
  });
}
