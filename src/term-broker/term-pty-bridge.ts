// src/server/term-pty-bridge.ts — pega un PTY (pty-session.ts) a una conexión WebSocket (ws.ts), y relaya
// WS<->WS para el modo HOST (axon-en-contenedor -> broker host-side). Un solo lugar con el PROTOCOLO del
// canal PTY, para que broker, http-server y el probe NO divergan.
//
// PROTOCOLO del canal PTY (idéntico en los DOS hops: browser<->axon y axon<->broker):
//   cliente -> servidor:
//     - frame BINARY  = bytes de stdin (keystrokes; Ctrl-C = \x03 viaja como byte normal).
//     - frame TEXT    = JSON de control: {"type":"resize","cols":C,"rows":R}.
//   servidor -> cliente:
//     - frame BINARY  = bytes crudos del PTY (ANSI incluido) -> xterm.write().
//     - frame TEXT    = JSON de estado: {"type":"exit","code":N} | {"type":"error","error":"..."}.
// La separación binary/text evita corromper UTF-8 multibyte (la salida cruda va en binary, nunca re-serializada
// a JSON) y da un canal de control limpio sin colisiones con el stream.

import { spawnPty, type PtyOptions } from "./pty-session.ts";
import type { WsConn } from "./ws.ts";

/** Parsea un mensaje de control TEXT del cliente. Never-throws: devuelve null si no aplica. */
function parseControl(text: string): { type: "resize"; cols: number; rows: number } | null {
  try {
    const o = JSON.parse(text) as { type?: unknown; cols?: unknown; rows?: unknown };
    if (o && o.type === "resize" && typeof o.cols === "number" && typeof o.rows === "number") {
      return { type: "resize", cols: o.cols, rows: o.rows };
    }
  } catch { /* no es JSON de control */ }
  return null;
}

/**
 * Sirve una sesión de PTY sobre `conn`: arranca el PTY, streamea su salida como frames BINARY, aplica resize/
 * stdin del cliente, y cierra ambos lados cuando el PTY termina o el WS se cae. Es el lado SERVIDOR del canal
 * (lo usan el broker host-side y el modo contenedor de axon).
 */
export function servePtyOverWs(conn: WsConn, opts: PtyOptions): void {
  const pty = spawnPty(opts);

  pty.onData((chunk) => conn.sendBinary(chunk));
  pty.onExit((code, error) => {
    try {
      if (error) conn.sendText(JSON.stringify({ type: "error", error }));
      conn.sendText(JSON.stringify({ type: "exit", code }));
    } catch { /* ws ya cerrado */ }
    conn.close(1000, "pty exit");
  });

  conn.onMessage((msg) => {
    if (msg.binary) {
      pty.write(msg.data); // stdin crudo (keystrokes/señales)
      return;
    }
    const ctl = parseControl(msg.data.toString("utf8"));
    if (ctl && ctl.type === "resize") pty.resize(ctl.cols, ctl.rows);
  });

  conn.onClose(() => pty.kill()); // widget cerrado / socket muerto -> mata el PTY (SIGHUP)
}

/**
 * Relaya frames entre dos WsConn BYTE-A-BYTE preservando binary/text — el modo HOST: axon (en el contenedor)
 * conecta al broker host-side y pipea el canal PTY del browser hacia él sin re-interpretar el protocolo. Cerrar
 * cualquiera de los dos cierra el otro.
 */
export function relayWsToWs(a: WsConn, b: WsConn): void {
  a.onMessage((m) => b.send(m.data, m.binary));
  b.onMessage((m) => a.send(m.data, m.binary));
  a.onClose(() => b.close(1000, "peer closed"));
  b.onClose(() => a.close(1000, "peer closed"));
  a.onError(() => b.close(1011, "peer error"));
  b.onError(() => a.close(1011, "peer error"));
}
