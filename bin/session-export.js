#!/usr/bin/env node
/*
 * session-export.js — embarca UNA sesión de Claude Code AL REPO para que viaje por git y se pueda
 * `claude --resume` en OTRA máquina (Mac↔Cachy↔Windows). Es opt-in: solo las sesiones que marcas.
 *
 * Qué hace:
 *   - Localiza el transcript `<sessionId>.jsonl` en ~/.claude/projects/<slug>/ (cualquier slug).
 *   - Lo COMPRIME (gzip) a `<repo>/.claude/sessions/<sessionId>.jsonl.gz` — los transcripts pesan
 *     decenas-cientos de MB en crudo; gzip sobre texto los baja ~10-20x, apto para git. Va en
 *     STREAMING (memoria acotada): un master de cientos de MB no topa con el techo de ~512 MiB de un
 *     string de Node, que es justo el tamaño en que un master deja de caber en RAM.
 *   - Escribe un sidecar `<sessionId>.meta.json` con proveniencia (cwd de origen, máquina, título,
 *     tamaños, fecha) para que el import del otro lado sepa qué está sembrando.
 *   - `.gz` y `.meta.json` se escriben a un temporal y se publican con `rename` (atómico): un corte
 *     no deja un `.gz` truncado haciéndose pasar por el respaldo bueno.
 *   - NO toca git (ni add ni commit): eso lo decide el flujo/wrapper (la sesión viaja por TU rama
 *     personal, nunca a develop/clones — ver el guard/gitignore del mecanismo).
 *
 * TÍTULO embarcado (`meta.label`, el que el import restaura como alias): manda el `--name` explícito;
 * si no, el `custom-title` que vive DENTRO del transcript (es el que el usuario fijó y el que el picker
 * muestra, así que sabe más que cualquier alias local); luego el alias del widget; al final el
 * `ai-title`. Con la precedencia al revés, un master renombrado se embarcaría con el nombre VIEJO del
 * alias y el import lo re-inyectaría en la otra máquina. `meta.labelSource` deja dicho de dónde salió.
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

function fail(msg) { process.stdout.write(JSON.stringify({ ok: false, error: String(msg) }) + '\n'); process.exit(1); }

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

// gzip en streaming a un temporal + rename. Devuelve los bytes comprimidos.
function gzipToFile(srcFile, tmpFile) {
  return new Promise((resolve, reject) => {
    const rs = fs.createReadStream(srcFile);
    const gz = zlib.createGzip({ level: 9 });
    const ws = fs.createWriteStream(tmpFile, { mode: 0o600 });
    const bail = (e) => { rs.destroy(); gz.destroy(); ws.destroy(); reject(e instanceof Error ? e : new Error(String(e))); };
    rs.on('error', bail); gz.on('error', bail); ws.on('error', bail);
    ws.on('finish', () => { try { resolve(fs.statSync(tmpFile).size); } catch (e) { bail(e); } });
    rs.pipe(gz).pipe(ws);
  });
}

async function main() {
  const { id, repo, name, force } = parseArgs(process.argv.slice(2));
  if (!id) fail('falta <sessionId>');
  if (!repo) fail('falta --repo <ruta-raiz-del-repo>');

  let repoRoot;
  try { repoRoot = fs.realpathSync(repo); } catch (_) { fail('el repo no existe: ' + repo); }

  const found = lib.findSession(id);
  if (!found) fail('no encontré la sesión ' + id + ' bajo ' + lib.projectsDir());
  if (found.collisions && found.collisions.length) {
    process.stderr.write('AVISO: el id ' + id + ' existe en ' + (found.collisions.length + 1)
      + ' slugs; embarco la copia viva (última actividad) del slug "' + found.slug + '". Otros: '
      + found.collisions.map(c => c.slug).join(', ') + '\n');
  }

  // Metadatos en UNA pasada de streaming (sin sostener el transcript en RAM).
  const scan = lib.scanTranscriptFile(found.file);
  const alias = lib.sessionAliases()[id] || null;
  let label = null, labelSource = null;
  if (name) { label = name; labelSource = 'name'; }
  else if (scan.customTitle) { label = scan.customTitle; labelSource = 'customTitle'; }
  else if (alias) { label = alias; labelSource = 'alias'; }
  else if (scan.aiTitle) { label = scan.aiTitle; labelSource = 'aiTitle'; }

  const destDir = path.join(repoRoot, '.claude', 'sessions');
  const gzFile = path.join(destDir, id + '.jsonl.gz');
  const metaFile = path.join(destDir, id + '.meta.json');
  if (fs.existsSync(gzFile) && !force) fail('ya está embarcada (' + gzFile + '); usa --force para re-embarcar');

  fs.mkdirSync(destDir, { recursive: true });
  const gzTmp = gzFile + '.part.' + process.pid;
  let gzBytes;
  try { gzBytes = await gzipToFile(found.file, gzTmp); }
  catch (e) { try { fs.unlinkSync(gzTmp); } catch (_) {} fail('falló al comprimir ' + found.file + ': ' + String(e.message || e)); }

  const meta = {
    id,
    label,
    labelSource,
    originCwd: scan.firstCwd,
    originSlug: found.slug,
    exportedFromMachine: os.hostname(),
    exportedFromPlatform: process.platform,
    exportedAt: new Date().toISOString(),
    rawBytes: scan.bytes,
    gzBytes,
    lines: scan.lines,
    lastActivity: scan.ts,
    truncatedLastLine: scan.truncated,
    schema: 1,
  };
  const metaTmp = metaFile + '.part.' + process.pid;
  try {
    fs.writeFileSync(metaTmp, JSON.stringify(meta, null, 2) + '\n', { mode: 0o600 });
    fs.renameSync(gzTmp, gzFile);        // el .gz primero: el meta solo describe un .gz que YA está
    fs.renameSync(metaTmp, metaFile);
  } catch (e) {
    try { fs.unlinkSync(metaTmp); } catch (_) {}
    try { fs.unlinkSync(gzTmp); } catch (_) {}
    fail('falló al publicar el embarque: ' + String(e.message || e));
  }

  process.stdout.write(JSON.stringify({
    ok: true, id, label, labelSource, gzFile, metaFile,
    rawBytes: scan.bytes, gzBytes,
    ratio: scan.bytes ? +(scan.bytes / gzBytes).toFixed(1) : null,
  }) + '\n');
}

main().catch((e) => fail(String((e && e.message) || e)));
