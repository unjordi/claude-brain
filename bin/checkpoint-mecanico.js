#!/usr/bin/env node
/*
 * checkpoint-mecanico.js — el 80% de un checkpoint COMPLETO, a CERO tokens de modelo (M2, auditoría
 * "mudanza de master · checkpoint/compactación", 2026-09-11).
 *
 * Por qué existe: el checkpoint hoy lo produce el actor con MENOS presupuesto (el modelo vivo, justo
 * cuando el contexto está por llenarse). Pero la MITAD del checkpoint —el 🗂️ ÁRBOL, el RESUELTO HOY, las
 * citas textuales del usuario, las métricas de sesión— sale MECÁNICAMENTE del transcript: no necesita
 * criterio, solo lectura. Este script hace ESA mitad, en streaming y con memoria ACOTADA (nunca sostiene
 * el archivo completo — el mismo principio que `rewriteTranscriptStream`/`scanTranscriptFile` de
 * session-lib.js, que reutiliza para la pasada barata de metadatos). Deja al modelo SOLO el juicio: en
 * qué estamos ahora, la decisión a medio cocinar, el siguiente paso y su porqué — que es lo barato de
 * ESCRIBIR (medido: 1.1K-2.8K tokens) y lo caro de DELEGAR.
 *
 * Corte por PRODUCTOR (lo que este script SÍ puede sacar del transcript sin criterio):
 *   - archivos escritos (Write/Edit/NotebookEdit), con conteo
 *   - skills invocadas (conteo)
 *   - comandos bash más frecuentes (primeros 2 tokens) + mensajes de `git commit -m` (verbatim)
 *   - cwds y ramas (gitBranch) vistos a lo largo de la sesión
 *   - compactaciones previas (marcador isCompactSummary) y tokens de contexto del ÚLTIMO usage
 *   - los últimos N mensajes de usuario, VERBATIM (filtra saludos/ruido de tool-result)
 *
 * Salida: un `.md` "andamio" — SIDECAR, nunca `hilo-mental-actual.md` (ese lo escribe el modelo con
 * criterio; pisarlo a ciegas desde un proceso mecánico sin turno sería exactamente el riesgo que la
 * skill `checkpoint` ya blinda con su "read-before-overwrite"). El skill `checkpoint` FUSIONA este
 * andamio al redactar el hilo real.
 *
 * Uso:  node checkpoint-mecanico.js <transcript.jsonl> --out <andamio.md> [--repo-root <path>] [--n-msgs 12]
 * Con --json en vez de (o adicional a) --out, imprime el resumen crudo a stdout (para el hook/log).
 *
 * Memoria acotada: streaming por líneas con buffer de 1 MiB; ningún string acumula el archivo completo.
 * Igual que session-lib.js, un renglón patológico (> MAX_LINE_CHARS) se descarta sin abortar el resto.
 */
'use strict';
const fs = require('fs');
const path = require('path');
const { StringDecoder } = require('string_decoder');

let sessionLib = null;
try { sessionLib = require(path.join(__dirname, 'session-lib.js')); } catch (_) { sessionLib = null; }

const MAX_LINE_CHARS = 64 * 1024 * 1024;
const TOP_N = 10;
const DEFAULT_N_MSGS = 12;

function parseArgs(argv) {
  const o = { file: null, out: null, json: false, repoRoot: null, nMsgs: DEFAULT_N_MSGS };
  const rest = [];
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i];
    if (a === '--out') o.out = argv[++i];
    else if (a === '--json') o.json = true;
    else if (a === '--repo-root') o.repoRoot = argv[++i];
    else if (a === '--n-msgs') o.nMsgs = parseInt(argv[++i], 10) || DEFAULT_N_MSGS;
    else rest.push(a);
  }
  o.file = rest[0] || null;
  return o;
}

// Un mensaje de usuario NO aporta señal si es un saludo pelón, un marcador de sistema
// (<command-message>, tool-result, [Request interrupted]) o un bloque de puro tool_result.
const GREETING = /^(?:h+o+l+a+|h+e+y+|o+l+a+|buen(?:os|as)(?: d[ií]as| tardes| noches)?|qu[eé] onda|saludos|hi+|hello+|holi+)[\s!¡.,:;]*$/i;
function isNoisyUserText(t) {
  if (!t) return true;
  const s = t.trim();
  if (!s) return true;
  if (GREETING.test(s)) return true;
  if (/^<command-(message|name)>/.test(s)) return true;
  if (/^\[Request interrupted/.test(s)) return true;
  return false;
}

function add(map, key) { map.set(key, (map.get(key) || 0) + 1); }
function top(map, n) {
  return [...map.entries()].sort((a, b) => b[1] - a[1]).slice(0, n).map(([k, v]) => ({ item: k, n: v }));
}

// ── Pasada 1 (barata, memoria acotada): reusa session-lib.js si está disponible (X1: el checkpoint
//    dejaba de compartir línea con la mudanza; ahora la comparte de verdad). Si no está (script suelto
//    fuera del repo cortex), degrada a null sin abortar — el resto del extractor no depende de esto.
function metaBarata(file) {
  if (!sessionLib || typeof sessionLib.scanTranscriptFile !== 'function') return null;
  try { return sessionLib.scanTranscriptFile(file, {}); } catch (_) { return null; }
}

// ── Pasada 2 (rica): streaming por líneas, memoria acotada — el mismo patrón de fs.readSync +
//    StringDecoder + partir por '\n' que rewriteTranscriptStream usa para el mismo archivo.
function extraer(file, nMsgs) {
  const R = {
    lineas: 0, compactaciones: 0,
    escrituras: new Map(), skills: new Map(), comandos: new Map(),
    commits: [], cwds: new Set(), ramas: new Set(),
    ctxTokens: null, ultimoUsageIdx: -1,
    mensajesUsuario: [], // ring buffer acotado a nMsgs
  };
  const pushMsg = (texto, ts) => {
    R.mensajesUsuario.push({ ts: ts || null, texto });
    if (R.mensajesUsuario.length > nMsgs) R.mensajesUsuario.shift();
  };
  const onLine = (raw) => {
    if (!raw || !raw.trim()) return;
    R.lineas++;
    let o;
    try { o = JSON.parse(raw); } catch (_) { return; }

    // Mismo anclaje al boundary que aviso-contexto.sh: un `isCompactSummary:true` RESETEA el ctxTokens
    // acumulado — así el usage PRE-compact (que la llamada interna de resumen deja en disco con el
    // tamaño VIEJO completo) no se reporta como si fuera el contexto vivo tras compactar (FP de
    // staleness, el mismo que el hook ya blinda). Si tras el boundary aún no hay usage nuevo, queda null.
    if (o.isCompactSummary === true) { R.compactaciones++; R.ctxTokens = null; }
    if (typeof o.cwd === 'string' && o.cwd) R.cwds.add(o.cwd);
    if (typeof o.gitBranch === 'string' && o.gitBranch) R.ramas.add(o.gitBranch);

    const usage = o.message && o.message.usage;
    if (usage && o.isSidechain !== true) {
      const t = (usage.input_tokens || 0) + (usage.cache_creation_input_tokens || 0) + (usage.cache_read_input_tokens || 0);
      R.ctxTokens = t; // el ÚLTIMO usage gana (orden del archivo = orden temporal)
    }

    // Mensaje de USUARIO textual (verbatim) — filtra ruido/saludos y el resumen SINTÉTICO del propio
    // /compact (isCompactSummary:true trae type:'user'/role:'user' pero NO lo escribió el usuario).
    if (o.type === 'user' && o.isCompactSummary !== true && o.message && o.message.role === 'user') {
      const c = o.message.content;
      let texto = null;
      if (typeof c === 'string') texto = c;
      else if (Array.isArray(c)) {
        const tb = c.find((b) => b && b.type === 'text' && typeof b.text === 'string');
        if (tb) texto = tb.text;
      }
      if (texto && !isNoisyUserText(texto)) pushMsg(texto, o.timestamp || null);
    }

    // tool_use del ASISTENTE: escrituras, skills, comandos bash + commits.
    const c = o.message && o.message.content;
    if (Array.isArray(c)) {
      for (const b of c) {
        if (!b || b.type !== 'tool_use') continue;
        const i = b.input || {};
        if ((b.name === 'Write' || b.name === 'Edit' || b.name === 'NotebookEdit') && i.file_path) {
          add(R.escrituras, i.file_path);
        }
        if (b.name === 'Skill' && i.skill) add(R.skills, i.skill);
        if (b.name === 'Bash' && i.command) {
          const cmd = String(i.command);
          add(R.comandos, cmd.trim().split(/\s+/).slice(0, 2).join(' '));
          const m = /git commit[^\n]*?-m\s+(["'])([\s\S]*?)\1/.exec(cmd);
          if (m) R.commits.push(m[2].split('\n')[0]);
        }
      }
    }
  };

  const st = fs.statSync(file);
  const fd = fs.openSync(file, 'r');
  const dec = new StringDecoder('utf8');
  const buf = Buffer.allocUnsafe(1 << 20); // 1 MiB — memoria de la pasada acotada al buffer, no al archivo
  let pending = '', pos = 0;
  try {
    for (;;) {
      const n = fs.readSync(fd, buf, 0, buf.length, pos);
      if (n <= 0) break;
      pos += n;
      pending += dec.write(buf.slice(0, n));
      let idx;
      while ((idx = pending.indexOf('\n')) >= 0) { onLine(pending.slice(0, idx)); pending = pending.slice(idx + 1); }
      // Renglón patológico (sin '\n' por decenas de MiB): se descarta, no se acumula sin cota.
      if (pending.length > MAX_LINE_CHARS) { pending = ''; }
    }
    pending += dec.end();
    if (pending.length) onLine(pending);
  } finally { fs.closeSync(fd); }

  return { ...R, bytes: st.size };
}

function renderAndamio(meta, r, ctxRepo) {
  const fecha = new Date().toISOString().slice(0, 10);
  const escrituras = top(r.escrituras, TOP_N);
  const skills = top(r.skills, TOP_N);
  const comandos = top(r.comandos, TOP_N);
  const lines = [];
  lines.push('# Andamio mecánico del checkpoint (auto-generado — NO es el hilo)');
  lines.push('');
  lines.push(`> Generado por \`bin/checkpoint-mecanico.js\` el ${fecha}, en streaming y sin gastar tokens de`);
  lines.push('> modelo. Es INSUMO para el checkpoint, no lo sustituye: el skill `checkpoint` lee este archivo');
  lines.push('> y FUSIONA lo que aplique al `hilo-mental-actual.md`; el juicio (en qué estamos, decisión');
  lines.push('> abierta, siguiente paso, procedencia) lo sigue poniendo el modelo. Este archivo se PISA en');
  lines.push('> cada corrida — no es durable por sí mismo.');
  lines.push('');
  lines.push('## Métricas de sesión');
  lines.push(`- Líneas del transcript: ${r.lineas}${meta ? ` (bytes: ${meta.bytes})` : ` (bytes: ${r.bytes})`}`);
  lines.push(`- Compactaciones previas detectadas: ${r.compactaciones}`);
  lines.push(`- Tokens de contexto del ÚLTIMO usage: ${r.ctxTokens === null ? 'sin dato' : r.ctxTokens}`);
  lines.push(`- cwd(s) vistos: ${[...r.cwds].join(', ') || '(ninguno)'}`);
  lines.push(`- Rama(s) vistas: ${[...r.ramas].join(', ') || '(ninguna)'}`);
  if (ctxRepo) lines.push(`- Repo (CLAUDE_PROJECT_DIR): ${ctxRepo}`);
  lines.push('');
  lines.push(`## 🗂️ Archivos tocados (Write/Edit/NotebookEdit) — top ${TOP_N} de ${r.escrituras.size}`);
  for (const e of escrituras) lines.push(`- ${e.item} (${e.n}×)`);
  if (!escrituras.length) lines.push('- (ninguno)');
  lines.push('');
  lines.push('## Skills invocadas');
  for (const e of skills) lines.push(`- ${e.item} (${e.n}×)`);
  if (!skills.length) lines.push('- (ninguna)');
  lines.push('');
  lines.push(`## RESUELTO HOY — mensajes de \`git commit\` (${r.commits.length} total, últimos ${TOP_N})`);
  for (const m of r.commits.slice(-TOP_N)) lines.push(`- ${m}`);
  if (!r.commits.length) lines.push('- (sin commits detectados)');
  lines.push('');
  lines.push(`## Comandos Bash más frecuentes (top ${TOP_N})`);
  for (const e of comandos) lines.push(`- \`${e.item}\` (${e.n}×)`);
  lines.push('');
  lines.push(`## Últimos ${r.mensajesUsuario.length} mensajes del usuario (VERBATIM, para citar con \`[user: "…"]\`)`);
  for (const m of r.mensajesUsuario) {
    const t = m.texto.length > 800 ? m.texto.slice(0, 800) + '…[truncado]' : m.texto;
    lines.push(`- ${m.ts ? `(${m.ts}) ` : ''}"${t.replace(/\n/g, ' ')}"`);
  }
  if (!r.mensajesUsuario.length) lines.push('- (ninguno)');
  lines.push('');
  return lines.join('\n');
}

function main() {
  const o = parseArgs(process.argv.slice(2));
  if (!o.file) {
    process.stderr.write('uso: checkpoint-mecanico.js <transcript.jsonl> [--out <andamio.md>] [--repo-root <path>] [--n-msgs N] [--json]\n');
    process.exit(2);
  }
  if (!fs.existsSync(o.file)) { process.stderr.write(`no existe: ${o.file}\n`); process.exit(1); }

  const t0 = Date.now();
  const meta = metaBarata(o.file);
  const r = extraer(o.file, o.nMsgs);
  const ms = Date.now() - t0;

  const md = renderAndamio(meta, r, o.repoRoot);
  if (o.out) {
    const tmp = o.out + '.tmp.' + process.pid;
    fs.writeFileSync(tmp, md, 'utf8');
    fs.renameSync(tmp, o.out); // atómico: nunca deja el andamio a medias
  }
  if (o.json || !o.out) {
    process.stdout.write(JSON.stringify({
      lineas: r.lineas, bytes: r.bytes, ms,
      rss_MB: Math.round(process.memoryUsage().rss / (1024 * 1024) * 10) / 10,
      compactaciones: r.compactaciones, ctxTokens: r.ctxTokens,
      cwds: [...r.cwds], ramas: [...r.ramas],
      archivosEscritos: r.escrituras.size, topEscrituras: top(r.escrituras, TOP_N),
      skillsInvocadas: top(r.skills, TOP_N), topComandos: top(r.comandos, TOP_N),
      commitsTotal: r.commits.length, commits: r.commits.slice(-TOP_N),
      mensajesUsuario: r.mensajesUsuario.length,
      out: o.out || null,
    }, null, 1) + '\n');
  }
}

if (require.main === module) main();
module.exports = { extraer, renderAndamio, metaBarata, isNoisyUserText };
