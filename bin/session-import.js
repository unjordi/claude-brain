#!/usr/bin/env node
/*
 * session-import.js — SIEMBRA en ESTA máquina las sesiones que viajaron en el repo (embarcadas por
 * session-export.js), para poder `claude --resume <id>` aquí tras un `git pull`. Gemelo de export.
 *
 * Qué hace, por cada `<repo>/.claude/sessions/<id>.jsonl.gz`:
 *   - Descomprime el transcript y REESCRIBE el cwd interno de cada línea a la ruta local de ESTE repo,
 *     todo en STREAMING (memoria acotada, sin el techo de ~512 MiB de un string de Node). La ruta puede
 *     diferir de la máquina de origen: /Users/u/... en Mac vs /home/u/... en Cachy vs C:\... en
 *     Windows → así `claude --resume` reanuda coherente.
 *   - Deriva el slug LOCAL con la misma normalización que el harness (ruta física, sin barra final; en
 *     Windows la forma nativa `C:\…`) y escribe `~/.claude/projects/<slug-local>/<id>.jsonl` en modo 600.
 *   - Escritura ATÓMICA: a `<id>.jsonl.part.<pid>` en el mismo dir y luego `rename`. Un corte nunca
 *     deja un transcript truncado haciéndose pasar por sesión sembrada.
 *   - Restaura el nombre legible en ~/.claude/sesiones-alias.json — pero NO pisa un alias local
 *     distinto (un rename hecho AQUÍ manda sobre el `meta.label` que viajó); lo reporta en `aliasKept`.
 *     Y si el transcript entrante trae su propio `custom-title`, ese gana sobre `meta.label`.
 *
 * Idempotencia: si el destino local ya tiene esa sesión, la SALTA (no pisa una sesión viva) salvo
 * --force. SIN red. Salida (stdout): JSON {ok, repo, slug, imported:[], skipped:[], errors:[]}.
 *
 * FRESHNESS GATE (--force NO regresa una sesión viva): con --force sobre una sesión que ya existe local,
 * si la copia LOCAL está MÁS FRESCA (más actividad reciente) que el .gz entrante — p. ej. seguiste la
 * sesión en ESTA máquina y el .gz de Drive quedó viejo — NO se pisa (se salta con motivo). Para pisar a
 * propósito con una copia más vieja, usa --force-stale (implica --force y SALTA el gate). Sin el gate,
 * --force pisaría a ciegas y podría regresar la sesión a una copia vieja (turnos recientes perdidos).
 *
 * El slug/cwd LOCAL se derivan de --repo (el proyecto real). De DÓNDE se leen los `.gz` es, por
 * defecto, `<repo>/.claude/sessions/`, pero se puede separar con --sessions-dir (p. ej. apuntándolo al
 * worktree de la rama de transporte `sesiones/<usuario>`, mientras --repo sigue siendo el proyecto real).
 *
 * Uso:
 *   node session-import.js --repo <ruta-del-proyecto> [--sessions-dir <dir-con-los-.gz>]
 *                          [--force] [--force-stale] [--only <sessionId>] [--dry-run]
 */
const fs = require('fs');
const path = require('path');
const zlib = require('zlib');
const lib = require('./session-lib.js');

function fail(msg) { process.stdout.write(JSON.stringify({ ok: false, error: String(msg) }) + '\n'); process.exit(1); }

function parseArgs(argv) {
  const a = { repo: null, sessionsDir: null, force: false, forceStale: false, only: null, dryRun: false };
  for (let i = 0; i < argv.length; i++) {
    if (argv[i] === '--repo') a.repo = argv[++i];
    else if (argv[i] === '--sessions-dir') a.sessionsDir = argv[++i];
    else if (argv[i] === '--force') a.force = true;
    else if (argv[i] === '--force-stale') { a.forceStale = true; a.force = true; }   // implica --force, salta el gate de frescura
    else if (argv[i] === '--only') a.only = argv[++i];
    else if (argv[i] === '--dry-run') a.dryRun = true;
  }
  return a;
}

async function main() {
  const { repo, sessionsDir, force, forceStale, only, dryRun } = parseArgs(process.argv.slice(2));
  if (!repo) fail('falta --repo <ruta-del-proyecto>');

  let repoRoot;
  try { repoRoot = lib.normalizeCwd(repo); } catch (e) { fail(String(e.message || e)); }
  if (!lib.cwdExists(repoRoot)) fail('el repo no existe: ' + repo);

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
    const partFile = destFile + '.part.' + process.pid;
    try {
      const destExists = fs.existsSync(destFile);
      if (destExists && !force) { skipped.push({ id, reason: 'ya existe local' }); continue; }

      // meta (opcional) para restaurar el nombre legible
      let metaLabel = null;
      try {
        const meta = JSON.parse(fs.readFileSync(path.join(srcDir, id + '.meta.json'), 'utf8'));
        metaLabel = meta && meta.label ? meta.label : null;
      } catch (_) { /* sin meta: sigue */ }

      if (dryRun) { imported.push({ id, destFile, cwdRewritten: null, label: metaLabel, dryRun: true }); continue; }

      // Descomprimir + re-anclar el cwd en UNA pasada, a un temporal del dir destino (no pisa nada).
      fs.mkdirSync(destDir, { recursive: true });
      const gunzip = zlib.createGunzip();
      fs.createReadStream(gzPath).on('error', (e) => gunzip.destroy(e)).pipe(gunzip);
      const r = await lib.rewriteTranscriptStream(gunzip, partFile, { toCwd: repoRoot });
      const incoming = lib.scanTranscriptFile(partFile);

      // FRESHNESS GATE (#2): con --force sobre una sesión existente, no regresar una copia VIVA a una
      // más vieja. --force-stale salta el gate a propósito. Sin señal de frescura en ambos lados, no se
      // puede afirmar regresión → se procede (fail-safe hacia la intención explícita de --force).
      // Ambos lados se miden del ARCHIVO en streaming: el local nunca se lee completo a un string.
      if (destExists && !forceStale) {
        const local = lib.scanTranscriptFile(destFile);
        const localFresher = (local.ts !== null && incoming.ts !== null)
          ? (local.ts > incoming.ts)
          : (local.lines > incoming.lines);
        if (localFresher) {
          try { fs.unlinkSync(partFile); } catch (_) {}
          skipped.push({
            id, reason: 'local más fresco que el .gz entrante; NO piso (usa --force-stale para pisar igual)',
            local: { ts: local.ts, lines: local.lines }, incoming: { ts: incoming.ts, lines: incoming.lines },
          });
          continue;
        }
      }

      // El `custom-title` que viaja DENTRO del transcript es el que el picker muestra: sabe más que el
      // `meta.label`. Y un alias LOCAL distinto (un rename hecho en esta máquina) no se pisa.
      const incomingTitle = incoming.customTitle;
      const label = incomingTitle || metaLabel;
      const localAlias = lib.sessionAliases()[id] || null;
      let aliasKept = null;
      if (label && localAlias && localAlias !== label && !incomingTitle) {
        aliasKept = { local: localAlias, incoming: label };
      }

      const mode = destExists ? (fs.statSync(destFile).mode & 0o7777) : 0o600;
      fs.chmodSync(partFile, mode);
      fs.renameSync(partFile, destFile);
      if (label && !aliasKept) lib.writeAlias(id, label);
      imported.push({ id, destFile, cwdRewritten: r.cwdRewritten, lines: r.lines, label, aliasKept });
    } catch (e) {
      try { fs.unlinkSync(partFile); } catch (_) {}
      errors.push({ id, error: String(e && e.message || e) });
    }
  }

  process.stdout.write(JSON.stringify({
    ok: errors.length === 0, repo: repoRoot, slug: localSlug, imported, skipped, errors,
  }, null, 2) + '\n');
}

main().catch((e) => fail(String((e && e.message) || e)));
