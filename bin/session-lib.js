/*
 * session-lib.js — helpers COMPARTIDOS de la maquinaria de sesiones de Claude Code.
 * Fuente ÚNICA (no divergir): la usan session-move.js (mover entre slugs, local→local),
 * session-export.js (embarcar una sesión al repo) y session-import.js (sembrarla en otra máquina).
 *
 * Modelo de almacenamiento (verificado 2026-07-23 leyendo el CLI v2.1.218):
 *   - Cada sesión es UN archivo `~/.claude/projects/<slug>/<sessionId>.jsonl`.
 *   - El <slug> se DERIVA del cwd absoluto: cada carácter no-alfanumérico -> '-'
 *     (ej. "/Users/u/code/cps" -> "-Users-u-code-cps"). El slug NO vive dentro del jsonl,
 *     solo es el nombre del dir → cross-máquina hay que re-derivarlo del cwd destino.
 *   - Cada línea del jsonl es un JSON independiente; muchas llevan un campo `cwd` con la ruta
 *     absoluta del proyecto → cross-máquina hay que REESCRIBIRLO para que `claude --resume`
 *     reanude coherente (una ruta Mac /Users/... no existe en Cachy /home/... ni Windows C:\...).
 *   - No hay índice/sqlite; los nombres legibles viven en ~/.claude/sesiones-alias.json.
 */
const fs = require('fs');
const os = require('os');
const path = require('path');

function claudeBase() {
  const cfg = process.env.CLAUDE_CONFIG_DIR;
  return (cfg && cfg.length) ? cfg : path.join(os.homedir(), '.claude');
}
function projectsDir() { return path.join(claudeBase(), 'projects'); }

// Slug tal como lo deriva Claude Code del cwd: cada carácter no alfanumérico -> '-'.
function slugFromCwd(cwd) { return cwd.replace(/[^a-zA-Z0-9]/g, '-'); }

// Localiza el <id>.jsonl bajo projects/<algún-slug>/. Devuelve {slug, file} o null.
function findSession(id) {
  const dir = projectsDir();
  let slugs;
  try {
    slugs = fs.readdirSync(dir, { withFileTypes: true }).filter(e => e.isDirectory()).map(e => e.name);
  } catch (_) { return null; }
  for (const slug of slugs) {
    const file = path.join(dir, slug, id + '.jsonl');
    if (fs.existsSync(file)) return { slug, file };
  }
  return null;
}

// Reescribe el cwd de cada línea JSON del transcript al destino. Preserva tal cual las líneas que no
// parsean (p. ej. la última cortada) para no corromper el archivo. Devuelve {text, count}.
function rewriteCwd(srcText, toCwd) {
  let count = 0;
  const lines = srcText.split('\n');
  const out = lines.map((line) => {
    if (!line.trim()) return line;
    let o;
    try { o = JSON.parse(line); } catch (_) { return line; }
    if (typeof o.cwd === 'string' && o.cwd && o.cwd !== toCwd) { o.cwd = toCwd; count++; return JSON.stringify(o); }
    return line;
  });
  return { text: out.join('\n'), count };
}

// Primer cwd que aparezca en el transcript (la ruta de origen de la sesión). null si no hay.
function firstCwd(srcText) {
  for (const line of srcText.split('\n')) {
    if (!line.trim()) continue;
    let o; try { o = JSON.parse(line); } catch (_) { continue; }
    if (typeof o.cwd === 'string' && o.cwd) return o.cwd;
  }
  return null;
}

// Título legible de la sesión: prioriza el custom-title/ai-title que el CLI nuevo (v2.1.218)
// ya escribe DENTRO del jsonl; si no hay, cae al alias del widget. Devuelve string o null.
function titleFromTranscript(srcText) {
  let ai = null;
  for (const line of srcText.split('\n')) {
    if (!line.trim()) continue;
    let o; try { o = JSON.parse(line); } catch (_) { continue; }
    if (o.type === 'custom-title' && o.customTitle) return String(o.customTitle);   // el del usuario gana
    if (o.type === 'ai-title' && o.aiTitle && !ai) ai = String(o.aiTitle);
  }
  return ai;
}

const aliasFile = () => path.join(claudeBase(), 'sesiones-alias.json');

// Mapa {sessionId: label}. Fail-open: sin archivo / JSON inválido -> {}.
function sessionAliases() {
  try {
    const o = JSON.parse(fs.readFileSync(aliasFile(), 'utf8'));
    return (o && typeof o === 'object') ? o : {};
  } catch (_) { return {}; }
}

// Fija/actualiza el alias de una sesión (merge, no pisa el resto). No-op si label es vacío.
function writeAlias(id, label) {
  if (!label) return;
  const m = sessionAliases();
  m[id] = String(label);
  try {
    fs.mkdirSync(claudeBase(), { recursive: true });
    fs.writeFileSync(aliasFile(), JSON.stringify(m, null, 2) + '\n');
  } catch (_) { /* fail-open: el alias es cosmético */ }
}

module.exports = {
  claudeBase, projectsDir, slugFromCwd, findSession, rewriteCwd,
  firstCwd, titleFromTranscript, sessionAliases, writeAlias,
};
