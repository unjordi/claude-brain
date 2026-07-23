#!/usr/bin/env node
/*
 * session-import.js — SIEMBRA en ESTA máquina las sesiones que viajaron en el repo (embarcadas por
 * session-export.js), para poder `claude --resume <id>` aquí tras un `git pull`. Gemelo de export.
 *
 * Qué hace, por cada `<repo>/.claude/sessions/<id>.jsonl.gz`:
 *   - Descomprime el transcript.
 *   - Deriva el slug LOCAL del cwd real de ESTE repo (la ruta puede diferir de la máquina de origen:
 *     /Users/u/... en Mac vs /home/u/... en Cachy vs C:\... en Windows) y REESCRIBE el cwd interno
 *     de cada línea a esa ruta local (reusa lib.rewriteCwd) → `claude --resume` reanuda coherente.
 *   - Escribe `~/.claude/projects/<slug-local>/<id>.jsonl`.
 *   - Restaura el nombre legible (del meta) en ~/.claude/sesiones-alias.json.
 *
 * Idempotencia: si el destino local ya tiene esa sesión, la SALTA (no pisa una sesión viva) salvo
 * --force. SIN red. Salida (stdout): JSON {ok, repo, slug, imported:[], skipped:[], errors:[]}.
 *
 * El slug/cwd LOCAL se derivan de --repo (el proyecto real). De DÓNDE se leen los `.gz` es, por
 * defecto, `<repo>/.claude/sessions/`, pero se puede separar con --sessions-dir (p. ej. apuntándolo al
 * worktree de la rama de transporte `sesiones/<usuario>`, mientras --repo sigue siendo el proyecto real).
 *
 * Uso:
 *   node session-import.js --repo <ruta-del-proyecto> [--sessions-dir <dir-con-los-.gz>]
 *                          [--force] [--only <sessionId>] [--dry-run]
 */
const fs = require('fs');
const path = require('path');
const zlib = require('zlib');
const lib = require('./session-lib.js');

function fail(msg) { process.stdout.write(JSON.stringify({ ok: false, error: msg }) + '\n'); process.exit(1); }

function parseArgs(argv) {
  const a = { repo: null, sessionsDir: null, force: false, only: null, dryRun: false };
  for (let i = 0; i < argv.length; i++) {
    if (argv[i] === '--repo') a.repo = argv[++i];
    else if (argv[i] === '--sessions-dir') a.sessionsDir = argv[++i];
    else if (argv[i] === '--force') a.force = true;
    else if (argv[i] === '--only') a.only = argv[++i];
    else if (argv[i] === '--dry-run') a.dryRun = true;
  }
  return a;
}

function main() {
  const { repo, sessionsDir, force, only, dryRun } = parseArgs(process.argv.slice(2));
  if (!repo) fail('falta --repo <ruta-del-proyecto>');

  let repoRoot;
  try { repoRoot = fs.realpathSync(repo); } catch (_) { fail('el repo no existe: ' + repo); }

  const srcDir = sessionsDir ? sessionsDir : path.join(repoRoot, '.claude', 'sessions');
  let gzs;
  try {
    gzs = fs.readdirSync(srcDir).filter(f => f.endsWith('.jsonl.gz'));
  } catch (_) {
    process.stdout.write(JSON.stringify({ ok: true, repo: repoRoot, slug: null, imported: [], skipped: [], errors: [], note: 'sin sesiones que importar en ' + srcDir }) + '\n');
    return;
  }
  if (only) gzs = gzs.filter(f => f === only + '.jsonl.gz');

  const localSlug = lib.slugFromCwd(repoRoot);
  const destDir = path.join(lib.projectsDir(), localSlug);
  const imported = [], skipped = [], errors = [];

  for (const gzName of gzs) {
    const id = gzName.replace(/\.jsonl\.gz$/, '');
    const gzPath = path.join(srcDir, gzName);
    const destFile = path.join(destDir, id + '.jsonl');
    try {
      if (fs.existsSync(destFile) && !force) { skipped.push({ id, reason: 'ya existe local' }); continue; }

      const text = zlib.gunzipSync(fs.readFileSync(gzPath)).toString('utf8');
      const { text: rewritten, count } = lib.rewriteCwd(text, repoRoot);

      // meta (opcional) para restaurar el nombre legible
      let label = null;
      try {
        const meta = JSON.parse(fs.readFileSync(path.join(srcDir, id + '.meta.json'), 'utf8'));
        label = meta && meta.label ? meta.label : null;
      } catch (_) { /* sin meta: sigue */ }

      if (dryRun) { imported.push({ id, destFile, cwdRewritten: count, label, dryRun: true }); continue; }

      fs.mkdirSync(destDir, { recursive: true });
      fs.writeFileSync(destFile, rewritten);
      if (label) lib.writeAlias(id, label);
      imported.push({ id, destFile, cwdRewritten: count, label });
    } catch (e) {
      errors.push({ id, error: String(e && e.message || e) });
    }
  }

  process.stdout.write(JSON.stringify({
    ok: errors.length === 0, repo: repoRoot, slug: localSlug, imported, skipped, errors,
  }, null, 2) + '\n');
}
main();
