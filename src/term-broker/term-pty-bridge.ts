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

  // BACKPRESSURE (ver el bloque largo en ws.ts). Sin esto, un cliente que lee más lento que el PTY
  // hacía crecer el buffer del socket sin techo: el PTY produce a velocidad de kernel y lo que no
  // drena se queda en el heap del broker. La política es PAUSAR la fuente, nunca descartar bytes —
  // un hueco en el stream corrompería la secuencia ANSI y con ella la pantalla del usuario.
  let paused = false;
  pty.onData((chunk) => {
    conn.sendBinary(chunk);
    if (!paused && conn.backpressured) { paused = true; pty.pause(); }
  });
  conn.onDrain(() => { if (paused) { paused = false; pty.resume(); } });

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
  // MISMO backpressure que el lado PTY, con la fuente que aquí corresponde: si el peer al que
  // escribimos no drena, dejamos de LEER del otro socket (`from.pause()`). El productor de verdad —el
  // PTY al otro extremo del hop— se frena solo cuando su propio socket deja de vaciarse. Nada se
  // descarta: los frames se quedan en el socket de origen, no en el heap del broker.
  const wire = (from: WsConn, to: WsConn): void => {
    from.onMessage((m) => {
      to.send(m.data, m.binary);
      if (to.backpressured && !from.isPaused) from.pause();
    });
    to.onDrain(() => { if (from.isPaused) from.resume(); });
  };
  wire(a, b);
  wire(b, a);
  // El motivo del cierre VIAJA por el relevo. Antes se re-cerraba con un 1000/1011 fijo, así que un
  // 1013 "cliente no drena: N B sobre el techo de M B" del salto de allá llegaba al navegador como un
  // "peer closed" genérico — el mismo problema que el HTTP 503 pelón: dos causas opuestas, un solo texto.
  // Solo se reemplaza el código cuando el que viene NO es utilizable (1005 = sin código, 1006 = cierre
  // anormal sin frame CLOSE), porque el RFC prohíbe reenviarlos tal cual.
  const propagar = (destino: WsConn, origen: string) => (code: number, reason: string) => {
    const utilizable = code !== 1005 && code !== 1006;
    destino.close(utilizable ? code : 1011, reason ? `${origen}: ${reason}` : `${origen}: cierre sin motivo`);
  };
  a.onClose(propagar(b, "peer"));
  b.onClose(propagar(a, "peer"));
  a.onError((e) => b.close(1011, `peer error: ${e.message}`));
  b.onError((e) => a.close(1011, `peer error: ${e.message}`));
}
