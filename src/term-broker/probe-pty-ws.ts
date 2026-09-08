// probe-pty-ws.ts — verifica el canal PTY (`/pty`, WebSocket) del broker YA LEVANTADO.
//
// Lo invoca probe-broker-vivo.sh, que es quien levanta el broker en un puerto de usar y tirar. Aquí
// solo se HABLA con él, con los mismos módulos vendorizados que usa el servidor (ws.ts) — así el
// probe ejercita el codec real, no una librería distinta.
//
//   node --experimental-strip-types probe-pty-ws.ts <puerto> <token>
//
// Comprueba:
//   1. sin Bearer  -> el upgrade se RECHAZA (401): auth antes de asignar un PTY.
//   2. con Bearer  -> hay PTY: se le escribe un comando por stdin (frame BINARY) y su salida vuelve
//      en frames BINARY (ANSI crudo), con el eco del shell interactivo.
//   3. `{"type":"resize"}` (frame TEXT de control) no rompe el canal.
//   4. al salir, llega el `{"type":"exit"}` de control y el WS cierra.

import { wsConnect } from "./ws.ts";

const port = Number(process.argv[2]);
const token = process.argv[3] ?? "";
let pass = 0, fail = 0;
const check = (name: string, cond: boolean): void => {
  if (cond) { pass++; console.log(`  ✅ ${name}`); } else { fail++; console.log(`  ❌ ${name}`); }
};
const delay = (ms: number): Promise<void> => new Promise((r) => setTimeout(r, ms));

// ── 1) sin token: el upgrade se rechaza ──
{
  let rejected = false;
  try { await wsConnect(`ws://127.0.0.1:${port}/pty`); }
  catch { rejected = true; }
  check("sin Bearer, el upgrade a /pty se rechaza", rejected);
}

// ── 2-4) con token: PTY real ──
{
  const conn = await wsConnect(`ws://127.0.0.1:${port}/pty?cols=80&rows=24`, {
    headers: { Authorization: `Bearer ${token}` },
  });
  let out = "";
  let exitSeen = false;
  let closed = false;
  conn.onMessage((m) => {
    if (m.binary) { out += m.data.toString("utf8"); return; }
    try {
      const o = JSON.parse(m.data.toString("utf8")) as { type?: string };
      if (o.type === "exit") exitSeen = true;
    } catch { /* control ilegible: se ignora */ }
  });
  conn.onClose(() => { closed = true; });

  await delay(1200); // el login shell tarda en pintar su prompt
  check("con Bearer, el PTY arranca y emite bytes", out.length > 0);

  conn.sendText(JSON.stringify({ type: "resize", cols: 100, rows: 30 })); // control TEXT
  conn.sendBinary(Buffer.from("echo MARCA-PTY-$(id -un)\n", "utf8"));     // stdin BINARY
  await delay(2500);
  check("el comando corrió en el PTY y su salida volvió", /MARCA-PTY-/.test(out));
  check("el resize no tumbó el canal", !closed);

  conn.sendBinary(Buffer.from("exit\n", "utf8"));
  await delay(1500);
  check("al salir llega el control {type:'exit'}", exitSeen);
  check("y el WebSocket cierra", closed);
}

console.log(`\n  ${pass} ✅   ${fail} ❌`);
process.exit(fail === 0 ? 0 : 1);
