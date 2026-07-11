#!/usr/bin/env node
/*
 * session-move.js — mueve UNA sesión de Claude Code de un slug de proyecto a otro, CON todo lo
 * que conlleva, de forma SEGURA y REVERSIBLE. Lo invoca el widget desde el menú "Mover a…".
 *
 * Qué mueve / re-atribuye:
 *   - El transcript (`<sessionId>.jsonl`) se MUEVE al dir del slug destino (~/.claude/projects/<slug>/).
 *   - Las estadísticas de tokens se re-atribuyen SOLAS: el fetch agrega por directorio de slug, así
 *     que al cambiar de dir el consumo cuenta para el proyecto destino en el próximo tick (no se toca
 *     nada aparte). No hay "memorias por-sesión" en este Claude Code (la memoria es por-repo), así que
 *     no hay más artefactos que mover.
 *   - El `cwd` interno de cada línea del transcript se REESCRIBE al cwd destino (salvo --keep-cwd), para
 *     que `claude --resume <id>` reanude coherente DENTRO del proyecto destino y no en la ruta vieja.
 *
 * Seguridad: antes de tocar nada respalda el .jsonl original en ~/.claude/session-move-backups/.
 * Idempotencia/colisión: si el destino ya tiene esa sesión, ABORTA sin tocar (no pisa).
 *
 * Uso:
 *   node session-move.js <sessionId> --to-cwd <ruta-real-del-proyecto-destino> [--keep-cwd]
 *   (el slug destino se deriva del cwd igual que Claude Code: no-alfanumérico -> '-')
 *
 * Salida (stdout): JSON { ok, id, fromSlug, toSlug, toCwd, backup, cwdRewritten, lines }.
 * En error: JSON { ok:false, error } y exit 1. SIN red.
 */
const fs = require('fs');
const os = require('os');
const path = require('path');

function claudeBase() {
  const cfg = process.env.CLAUDE_CONFIG_DIR;
  return (cfg && cfg.length) ? cfg : path.join(os.homedir(), '.claude');
}
function projectsDir() { return path.join(claudeBase(), 'projects'); }

// Slug tal como lo deriva Claude Code del cwd: cada carácter no alfanumérico -> '-'
// (ej. "/Users/u/code/cps" -> "-Users-u-code-cps").
function slugFromCwd(cwd) { return cwd.replace(/[^a-zA-Z0-9]/g, '-'); }

function fail(msg) {
  process.stdout.write(JSON.stringify({ ok: false, error: msg }) + '\n');
  process.exit(1);
}

function parseArgs(argv) {
  const a = { id: null, toCwd: null, keepCwd: false };
  const rest = [];
  for (let i = 0; i < argv.length; i++) {
    if (argv[i] === '--to-cwd') { a.toCwd = argv[++i]; }
    else if (argv[i] === '--keep-cwd') { a.keepCwd = true; }
    else rest.push(argv[i]);
  }
  a.id = rest[0] || null;
  return a;
}

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

function main() {
  const { id, toCwd, keepCwd } = parseArgs(process.argv.slice(2));
  if (!id) fail('falta <sessionId>');
  if (!toCwd) fail('falta --to-cwd <ruta-del-proyecto-destino>');

  const found = findSession(id);
  if (!found) fail('no encontré la sesión ' + id + ' bajo ' + projectsDir());

  const toSlug = slugFromCwd(toCwd);
  const fromSlug = found.slug;
  if (toSlug === fromSlug) fail('la sesión ya está en el slug destino (' + toSlug + ')');

  const toDir = path.join(projectsDir(), toSlug);
  const toFile = path.join(toDir, id + '.jsonl');
  if (fs.existsSync(toFile)) fail('el destino ya tiene una sesión con ese id (' + toFile + '); no la piso');

  // 1) respaldo (antes de tocar nada)
  const backupDir = path.join(claudeBase(), 'session-move-backups');
  fs.mkdirSync(backupDir, { recursive: true });
  const backup = path.join(backupDir, id + '.' + Date.now() + '.jsonl.bak');
  fs.copyFileSync(found.file, backup);

  // 2) leer + (opcional) reescribir cwd interno
  const srcText = fs.readFileSync(found.file, 'utf8');
  let outText = srcText, cwdRewritten = 0;
  if (!keepCwd) { const r = rewriteCwd(srcText, toCwd); outText = r.text; cwdRewritten = r.count; }

  // 3) escribir en el destino y borrar el origen (mover). Escribir-luego-borrar evita perder datos
  // si algo falla a media operación (el respaldo + el origen siguen ahí hasta el unlink final).
  fs.mkdirSync(toDir, { recursive: true });
  fs.writeFileSync(toFile, outText);
  fs.unlinkSync(found.file);

  process.stdout.write(JSON.stringify({
    ok: true, id, fromSlug, toSlug, toCwd, backup, cwdRewritten,
    lines: outText.split('\n').filter(l => l.trim()).length,
  }) + '\n');
}
main();
