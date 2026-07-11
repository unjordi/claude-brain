#!/usr/bin/env node
/*
 * sessions-extract.js — lista las sesiones de Claude Code por proyecto, para el dropdown
 * "resumir sesión" del tab Proyectos. Lee ~/.claude/projects/<slug>/*.jsonl (o CLAUDE_CONFIG_DIR).
 * SIN red. Salida (stdout): JSON array [{id, project, cwd, updated_at, label}] ordenado por
 * más reciente. Cada .jsonl es una sesión (nombre = sessionId); se resume con `claude --resume <id>`.
 */
const fs = require('fs');
const os = require('os');
const path = require('path');

const PER_PROJECT = 12;   // tope de sesiones recientes por proyecto (acota la I/O del daemon)

function claudeBase() {
  const cfg = process.env.CLAUDE_CONFIG_DIR;
  return (cfg && cfg.length) ? cfg : path.join(os.homedir(), '.claude');
}

function projectsDir() {
  return path.join(claudeBase(), 'projects');
}

// Alias opcional de etiquetas de sesión: mapa {"<sessionId>":"<etiqueta>"} en
// ~/.claude/sesiones-alias.json (lo escribe el widget al renombrar una sesión). Fail-open:
// sin archivo / JSON inválido → mapa vacío (se usa la etiqueta derivada del transcript).
function sessionAliases() {
  try {
    const raw = fs.readFileSync(path.join(claudeBase(), 'sesiones-alias.json'), 'utf8');
    const o = JSON.parse(raw);
    return (o && typeof o === 'object') ? o : {};
  } catch (_) { return {}; }
}

// Un mensaje de usuario NO aporta contexto para nombrar la sesión si es solo un saludo, un
// marcador del sistema (<command-message>…, tool-result) o un aviso tipo "[Request interrupted]".
// El estilo real de unjordi abre con "holaaaaaa" / "hola! …" + un ritual de "carga memorias,
// despierta" antes de la petición de verdad → si tomáramos solo el 1er mensaje, el summary (y la
// sugerencia de nombre) saldría inútil ("charla inicial sin rumbo"). Por eso se SALTAN estos.
const GREETING = /^(?:h+o+l+a+|h+e+y+|o+l+a+|buen(?:os|as)(?: d[ií]as| tardes| noches)?|qu[eé] onda|saludos|hi+|hello+|holi+)[\s!¡.,:;]*$/i;
function isSkippable(t) {
  const s = (t || '').trim();
  if (!s) return true;
  if (s[0] === '<') return true;               // <command-message>…, salidas de herramienta, etc.
  if (/^\[.*\]$/.test(s)) return true;          // "[Request interrupted by user]"
  if (GREETING.test(s)) return true;            // saludo puro (sin contenido detrás)
  return false;
}

// Lee el prefijo del transcript (los primeros bytes bastan) y saca el cwd + el texto para nombrar.
//   label   = primer mensaje de usuario CON SUSTANCIA, 80 chars (para el listado).
//   summary = los primeros mensajes con sustancia concatenados (≤320 chars) — el "de qué trata"
//             que el diálogo de renombrar muestra y que alimenta al botón "Sugerir nombre" (opt-in,
//             `claude -p`, vive en la GUI). Este Claude Code NO escribe resúmenes server-generados
//             en el .jsonl → se DERIVA. Fallback: si TODO fue saludo/marcador, usa el 1er mensaje.
function meta(file) {
  let txt = '';
  try {
    const fd = fs.openSync(file, 'r');
    const buf = Buffer.alloc(131072);
    const n = fs.readSync(fd, buf, 0, buf.length, 0);
    fs.closeSync(fd);
    txt = buf.toString('utf8', 0, n);
  } catch (_) { return { cwd: null, label: null, summary: null }; }

  let cwd = null;
  const userTexts = [];
  for (const line of txt.split('\n')) {
    if (!line.trim()) continue;
    let o; try { o = JSON.parse(line); } catch (_) { continue; }   // la última línea puede venir cortada
    if (!cwd && typeof o.cwd === 'string' && o.cwd) cwd = o.cwd;
    if (o.type === 'user' && o.message) {
      const c = o.message.content;
      let t = null;
      if (typeof c === 'string') t = c;
      else if (Array.isArray(c)) {
        const x = c.find(e => e && e.type === 'text' && typeof e.text === 'string');
        t = x ? x.text : null;
      }
      if (t) { t = t.replace(/\s+/g, ' ').trim(); if (t) userTexts.push(t); }
    }
    if (cwd && userTexts.length >= 8) break;     // suficiente para hallar los primeros con sustancia
  }

  const substantive = userTexts.filter(t => !isSkippable(t));
  const firstAny = userTexts[0] || null;
  const labelSrc = substantive[0] || firstAny;
  const summarySrc = substantive.length ? substantive.slice(0, 4).join(' · ') : firstAny;
  return {
    cwd,
    label: labelSrc ? labelSrc.slice(0, 80) : null,
    summary: summarySrc ? summarySrc.slice(0, 320) : null,
  };
}

function main() {
  const dir = projectsDir();
  let slugs;
  try {
    slugs = fs.readdirSync(dir, { withFileTypes: true }).filter(e => e.isDirectory()).map(e => e.name);
  } catch (_) { process.stdout.write('[]\n'); return; }

  const aliases = sessionAliases();
  const out = [];
  for (const slug of slugs) {
    const sdir = path.join(dir, slug);
    let files;
    try {
      files = fs.readdirSync(sdir)
        .filter(f => f.endsWith('.jsonl'))
        .map(f => ({ f, m: fs.statSync(path.join(sdir, f)).mtimeMs }));
    } catch (_) { continue; }
    files.sort((a, b) => b.m - a.m);
    for (const { f, m } of files.slice(0, PER_PROJECT)) {
      const { cwd, label, summary } = meta(path.join(sdir, f));
      const realCwd = cwd || slug.replace(/^-/, '/').replace(/-/g, '/');   // fallback lossy si no hubo cwd
      const id = f.replace(/\.jsonl$/, '');
      out.push({
        id,
        project: path.basename(realCwd) || slug,
        cwd: realCwd,
        slug,                                          // dir real bajo projects/ (para mover entre slugs)
        updated_at: new Date(m).toISOString(),
        label: aliases[id] || label || '(sesión)',     // el alias del widget gana sobre la etiqueta derivada
        summary: summary || null,                      // contexto del contenido para el diálogo de renombrar
      });
    }
  }
  out.sort((a, b) => (Date.parse(b.updated_at) || 0) - (Date.parse(a.updated_at) || 0));
  process.stdout.write(JSON.stringify(out, null, 2) + '\n');
}
main();
