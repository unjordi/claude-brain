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

  constructor(socket: Duplex, isServer: boolean) {
    this.socket = socket;
    this.isServer = isServer;
    socket.on("data", (d: Buffer) => this.onData(d));
    socket.on("close", () => this.fireClose(1006, "socket closed"));
    socket.on("error", (e: Error) => { if (this.errCb) this.errCb(e); this.fireClose(1006, e.message); });
  }

  onMessage(cb: MsgHandler): this { this.msgCb = cb; return this; }
  onClose(cb: CloseHandler): this { this.closeCb = cb; return this; }
  onError(cb: ErrHandler): this { this.errCb = cb; return this; }

  /** Envía un mensaje. `binary=false` -> frame TEXT; `true` -> frame BINARY. */
  send(data: string | Buffer, binary = false): void {
    if (this.closed) return;
    const payload = typeof data === "string" ? Buffer.from(data, "utf8") : data;
    this.writeFrame(binary ? OP_BIN : OP_TEXT, payload);
  }

  sendText(s: string): void { this.send(s, false); }
  sendBinary(b: Buffer): void { this.send(b, true); }

  ping(): void { if (!this.closed) this.writeFrame(OP_PING, Buffer.alloc(0)); }

  /** Cierra ordenadamente (envía un frame CLOSE una vez). */
  close(code = 1000, reason = ""): void {
    if (this.closed || this.closeSent) { this.destroy(); return; }
    this.closeSent = true;
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
    if (this.closeCb) this.closeCb(code, reason);
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
    try { this.socket.write(out); } catch (e) { if (this.errCb) this.errCb(e as Error); }
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
export function acceptWebSocket(req: IncomingMessage, socket: Duplex): WsConn | null {
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
  return new WsConn(socket, true);
}

/** Rechaza un upgrade con un status HTTP crudo (para auth fallida en el handshake) y cierra el socket. */
export function rejectWebSocket(socket: Duplex, status = 401, message = "unauthorized"): void {
  try {
    socket.write(`HTTP/1.1 ${status} ${message}\r\nConnection: close\r\nContent-Length: 0\r\n\r\n`);
  } catch { /* socket ya muerto */ }
  try { socket.destroy(); } catch { /* ya */ }
}

export interface WsConnectOptions {
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
      resolve(new WsConn(socket, false));
    });
    req.on("response", (res) => { if (settled) return; settled = true; reject(new Error(`WS upgrade rechazado: HTTP ${res.statusCode}`)); req.destroy(); });
    req.on("error", (e) => { if (settled) return; settled = true; reject(e); });
    req.on("timeout", () => { if (settled) return; settled = true; req.destroy(); reject(new Error("WS connect timeout")); });
    req.end();
  });
}
