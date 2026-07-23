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
const path = require('path');
const lib = require('./session-lib.js');   // helpers COMPARTIDOS (fuente única: no divergir)

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

function main() {
  const { id, toCwd, keepCwd } = parseArgs(process.argv.slice(2));
  if (!id) fail('falta <sessionId>');
  if (!toCwd) fail('falta --to-cwd <ruta-del-proyecto-destino>');

  const found = lib.findSession(id);
  if (!found) fail('no encontré la sesión ' + id + ' bajo ' + lib.projectsDir());

  const toSlug = lib.slugFromCwd(toCwd);
  const fromSlug = found.slug;
  if (toSlug === fromSlug) fail('la sesión ya está en el slug destino (' + toSlug + ')');

  const toDir = path.join(lib.projectsDir(), toSlug);
  const toFile = path.join(toDir, id + '.jsonl');
  if (fs.existsSync(toFile)) fail('el destino ya tiene una sesión con ese id (' + toFile + '); no la piso');

  // 1) respaldo (antes de tocar nada)
  const backupDir = path.join(lib.claudeBase(), 'session-move-backups');
  fs.mkdirSync(backupDir, { recursive: true });
  const backup = path.join(backupDir, id + '.' + Date.now() + '.jsonl.bak');
  fs.copyFileSync(found.file, backup);

  // 2) leer + (opcional) reescribir cwd interno
  const srcText = fs.readFileSync(found.file, 'utf8');
  let outText = srcText, cwdRewritten = 0;
  if (!keepCwd) { const r = lib.rewriteCwd(srcText, toCwd); outText = r.text; cwdRewritten = r.count; }

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
