#!/usr/bin/env node
/*
 * session-export.js — embarca UNA sesión de Claude Code AL REPO para que viaje por git y se pueda
 * `claude --resume` en OTRA máquina (Mac↔Cachy↔Windows). Es opt-in: solo las sesiones que marcas.
 *
 * Qué hace:
 *   - Localiza el transcript `<sessionId>.jsonl` en ~/.claude/projects/<slug>/ (cualquier slug).
 *   - Lo COMPRIME (gzip) a `<repo>/.claude/sessions/<sessionId>.jsonl.gz` — los transcripts pesan
 *     decenas-cientos de MB en crudo; gzip sobre texto los baja ~10-20x, apto para git.
 *   - Escribe un sidecar `<sessionId>.meta.json` con proveniencia (cwd de origen, máquina, título,
 *     tamaños, fecha) para que el import del otro lado sepa qué está sembrando.
 *   - NO toca git (ni add ni commit): eso lo decide el flujo/wrapper (la sesión viaja por TU rama
 *     personal, nunca a develop/clones — ver el guard/gitignore del mecanismo).
 *
 * Seguridad/idempotencia: si el destino ya tiene ese .gz, requiere --force para re-embarcar.
 * SIN red. Salida (stdout): JSON. En error: JSON {ok:false,error} y exit 1.
 *
 * Uso:
 *   node session-export.js <sessionId> --repo <ruta-raiz-del-repo> [--name "<etiqueta>"] [--force]
 */
const fs = require('fs');
const os = require('os');
const path = require('path');
const zlib = require('zlib');
const lib = require('./session-lib.js');

function fail(msg) { process.stdout.write(JSON.stringify({ ok: false, error: msg }) + '\n'); process.exit(1); }

function parseArgs(argv) {
  const a = { id: null, repo: null, name: null, force: false };
  const rest = [];
  for (let i = 0; i < argv.length; i++) {
    if (argv[i] === '--repo') a.repo = argv[++i];
    else if (argv[i] === '--name') a.name = argv[++i];
    else if (argv[i] === '--force') a.force = true;
    else rest.push(argv[i]);
  }
  a.id = rest[0] || null;
  return a;
}

function main() {
  const { id, repo, name, force } = parseArgs(process.argv.slice(2));
  if (!id) fail('falta <sessionId>');
  if (!repo) fail('falta --repo <ruta-raiz-del-repo>');

  let repoRoot;
  try { repoRoot = fs.realpathSync(repo); } catch (_) { fail('el repo no existe: ' + repo); }

  const found = lib.findSession(id);
  if (!found) fail('no encontré la sesión ' + id + ' bajo ' + lib.projectsDir());

  const srcText = fs.readFileSync(found.file, 'utf8');
  const rawBytes = Buffer.byteLength(srcText, 'utf8');
  const originCwd = lib.firstCwd(srcText);
  const label = name || lib.sessionAliases()[id] || lib.titleFromTranscript(srcText) || null;

  const destDir = path.join(repoRoot, '.claude', 'sessions');
  const gzFile = path.join(destDir, id + '.jsonl.gz');
  const metaFile = path.join(destDir, id + '.meta.json');
  if (fs.existsSync(gzFile) && !force) fail('ya está embarcada (' + gzFile + '); usa --force para re-embarcar');

  fs.mkdirSync(destDir, { recursive: true });
  const gz = zlib.gzipSync(Buffer.from(srcText, 'utf8'), { level: 9 });
  fs.writeFileSync(gzFile, gz);

  const meta = {
    id,
    label,
    originCwd,
    originSlug: found.slug,
    exportedFromMachine: os.hostname(),
    exportedFromPlatform: process.platform,
    exportedAt: new Date().toISOString(),
    rawBytes,
    gzBytes: gz.length,
    lines: srcText.split('\n').filter(l => l.trim()).length,
    schema: 1,
  };
  fs.writeFileSync(metaFile, JSON.stringify(meta, null, 2) + '\n');

  process.stdout.write(JSON.stringify({
    ok: true, id, label, gzFile, metaFile,
    rawBytes, gzBytes: gz.length,
    ratio: rawBytes ? +(rawBytes / gz.length).toFixed(1) : null,
  }) + '\n');
}
main();
