#!/usr/bin/env node
/*
 * session-move.js — mueve UNA sesión de Claude Code de un slug de proyecto a otro, CON todo lo
 * que conlleva, de forma SEGURA y REVERSIBLE. Lo invoca el widget desde el menú "Mover a…".
 *
 * Qué mueve / re-atribuye:
 *   - El transcript (`<sessionId>.jsonl`) se MUEVE al dir del slug destino (~/.claude/projects/<slug>/),
 *     conservando el MODO del archivo de origen (el resto del slug está en 600; escribir con el umask
 *     dejaría este solo en 644).
 *   - Las estadísticas de tokens se re-atribuyen SOLAS: el fetch agrega por directorio de slug, así
 *     que al cambiar de dir el consumo cuenta para el proyecto destino en el próximo tick (no se toca
 *     nada aparte). No hay "memorias por-sesión" en este Claude Code (la memoria es por-repo), así que
 *     no hay más artefactos que mover.
 *   - El `cwd` interno de cada línea del transcript se REESCRIBE al cwd destino (salvo --keep-cwd), para
 *     que `claude --resume <id>` reanude coherente DENTRO del proyecto destino y no en la ruta vieja.
 *   - El `gitBranch` HISTÓRICO no se toca (falsificaría el registro). Con --git-branch <rama> se
 *     normaliza SOLO el del último evento con `cwd` —el par que el harness hereda al reanudar—, en la
 *     MISMA pasada del move: así el re-anclaje no necesita una segunda lectura del archivo después de
 *     la mutación destructiva, que es donde una excepción sería catastrófica.
 *
 * Seguridad: antes de tocar nada respalda el .jsonl original en ~/.claude/session-move-backups/. Ese
 * dir se PODA (conserva los N más recientes; N = CLAUDE_SESSION_MOVE_BACKUPS_KEEP, default 10) para que
 * los .bak —cientos de MB c/u— no lo hagan crecer sin límite.
 * ATOMICIDAD: el destino se escribe a `<id>.jsonl.part.<pid>` en el MISMO dir, se verifica (nº de
 * renglones idéntico al origen) y solo entonces se `rename` (atómico dentro del mismo filesystem) y se
 * borra el origen. Un corte a media escritura deja únicamente el `.part` (que la próxima corrida
 * limpia) y el origen intacto: nunca un transcript TRUNCADO en el destino, que bloquearía el reintento
 * por "colisión", pasaría por "ya movido" y sería elegido como la copia viva por findSession.
 * TAMAÑO: todo el camino va en STREAMING (memoria acotada) → un master de cientos de MB se mueve sin
 * topar con el techo de ~512 MiB de un string de Node.
 * Idempotencia/colisión: si el destino ya tiene esa sesión, ABORTA sin tocar (no pisa). Si el MISMO id
 * existe en >1 slug de origen, findSession elige la copia viva de forma determinista y AVISA.
 *
 * Uso:
 *   node session-move.js <sessionId> --to-cwd <ruta-real-del-proyecto-destino>
 *                        [--keep-cwd] [--git-branch <rama>] [--allow-missing-cwd]
 *   El slug destino se deriva del cwd NORMALIZADO igual que Claude Code (ruta física, sin barra final,
 *   no-alfanumérico -> '-'); por eso el destino debe EXISTIR — si no, el slug sería uno que el harness
 *   nunca mirará y la sesión desaparecería del picker. --allow-missing-cwd lo permite a propósito.
 *
 * Salida (stdout): JSON { ok, id, fromSlug, toSlug, toCwd, backup, cwdRewritten, lines, ... }.
 * En error: JSON { ok:false, error } y exit 1. SIN red.
 */
const fs = require('fs');
const path = require('path');
const lib = require('./session-lib.js');   // helpers COMPARTIDOS (fuente única: no divergir)

function fail(msg) {
  process.stdout.write(JSON.stringify({ ok: false, error: String(msg) }) + '\n');
  process.exit(1);
}

// Poda de respaldos: conserva los `keep` .bak más recientes (por mtime) y borra el resto. Fail-open:
// los backups son red de seguridad y un error al podar JAMÁS debe abortar el move. Sin poda, cada move
// deja un .bak (potencialmente cientos de MB) y el dir crece sin límite.
function pruneBackups(backupDir, keep) {
  try {
    const files = fs.readdirSync(backupDir)
      .filter(f => f.endsWith('.jsonl.bak'))
      .map(f => { const fp = path.join(backupDir, f); let mt = 0; try { mt = fs.statSync(fp).mtimeMs; } catch (_) {} return { fp, mt }; })
      .sort((a, b) => b.mt - a.mt);
    for (const { fp } of files.slice(keep)) { try { fs.unlinkSync(fp); } catch (_) {} }
  } catch (_) { /* fail-open: la poda es housekeeping, no crítica */ }
}

function parseArgs(argv) {
  const a = { id: null, toCwd: null, keepCwd: false, gitBranch: null, allowMissingCwd: false };
  const rest = [];
  for (let i = 0; i < argv.length; i++) {
    if (argv[i] === '--to-cwd') { a.toCwd = argv[++i]; }
    else if (argv[i] === '--keep-cwd') { a.keepCwd = true; }
    else if (argv[i] === '--git-branch') { a.gitBranch = argv[++i]; }
    else if (argv[i] === '--allow-missing-cwd') { a.allowMissingCwd = true; }
    else rest.push(argv[i]);
  }
  a.id = rest[0] || null;
  return a;
}

async function main() {
  const { id, toCwd, keepCwd, gitBranch, allowMissingCwd } = parseArgs(process.argv.slice(2));
  if (!id) fail('falta <sessionId>');
  if (!toCwd) fail('falta --to-cwd <ruta-del-proyecto-destino>');

  // El cwd destino se NORMALIZA a la forma que el harness usaría (física, absoluta, sin barra final;
  // en Windows a la nativa `C:\…`) ANTES de derivar el slug y antes de escribirlo en el transcript.
  let destCwd;
  try { destCwd = lib.normalizeCwd(toCwd); } catch (e) { fail(String(e.message || e)); }
  if (!lib.cwdExists(destCwd) && !allowMissingCwd) {
    fail('el destino no existe como directorio: ' + destCwd + ' (derivado de "' + toCwd + '").'
      + ' El slug saldría de una ruta que el harness nunca va a tener como cwd, así que la sesión'
      + ' quedaría invisible en el picker. Crea el directorio o pasa --allow-missing-cwd si es a propósito.');
  }

  const found = lib.findSession(id);
  if (!found) fail('no encontré la sesión ' + id + ' bajo ' + lib.projectsDir());
  if (found.collisions && found.collisions.length) {
    process.stderr.write('AVISO: el id ' + id + ' existe en ' + (found.collisions.length + 1)
      + ' slugs; uso la copia viva (última actividad) del slug "' + found.slug + '". Otros: '
      + found.collisions.map(c => c.slug).join(', ') + '\n');
  }

  const toSlug = lib.slugFromCwd(destCwd);
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
  const keepEnv = parseInt(process.env.CLAUDE_SESSION_MOVE_BACKUPS_KEEP, 10);
  pruneBackups(backupDir, (Number.isFinite(keepEnv) && keepEnv >= 0) ? keepEnv : 10);

  // 2) escribir el destino a un TEMPORAL del mismo dir, en streaming, reescribiendo el cwd
  const srcStat = fs.statSync(found.file);
  fs.mkdirSync(toDir, { recursive: true });
  // Restos de un intento anterior que murió a media escritura: se barren. findSession no los ve (busca
  // `<id>.jsonl` exacto) y la colisión tampoco, así que un `.part` nunca frena el reintento — pero sí
  // ocuparía disco (cientos de MB) hasta que alguien lo notara.
  try {
    for (const f of fs.readdirSync(toDir)) {
      if (f.startsWith(id + '.jsonl.part.')) {
        try { fs.unlinkSync(path.join(toDir, f)); } catch (_) {}
      }
    }
  } catch (_) { /* fail-open: el barrido es housekeeping */ }
  const partFile = toFile + '.part.' + process.pid;
  let r;
  try {
    r = await lib.rewriteTranscriptStream(fs.createReadStream(found.file), partFile, {
      toCwd: keepCwd ? undefined : destCwd,
      gitBranch: gitBranch || undefined,
    });
  } catch (e) {
    try { fs.unlinkSync(partFile); } catch (_) {}
    fail('falló al escribir el destino (' + partFile + '): ' + String(e.message || e)
      + '. El origen y el respaldo (' + backup + ') están intactos.');
  }

  // 3) VERIFICAR el temporal contra el origen antes de destruir nada: mismo nº de renglones no vacíos.
  // Un `.part` truncado por un corte a media escritura se queda aquí y jamás llega a ser el destino.
  let check;
  try { check = lib.scanTranscriptFile(partFile); } catch (e) { check = null; }
  if (!check || check.lines !== r.lines) {
    try { fs.unlinkSync(partFile); } catch (_) {}
    fail('la copia del destino no cuadra con el origen (' + r.lines + ' renglones leídos vs '
      + (check ? check.lines : '?') + ' escritos); no muevo nada. Origen y respaldo (' + backup + ') intactos.');
  }
  fs.chmodSync(partFile, srcStat.mode & 0o7777);   // el modo del ORIGEN, no el del umask

  // 4) publicar (rename = atómico dentro del mismo dir) y borrar el origen. Hasta este rename, un corte
  // deja el origen vivo y el destino inexistente; después, el destino COMPLETO y el origen vivo.
  fs.renameSync(partFile, toFile);
  fs.unlinkSync(found.file);

  process.stdout.write(JSON.stringify({
    ok: true, id, fromSlug, toSlug, toCwd: destCwd, toFile, backup,
    cwdRewritten: r.cwdRewritten,
    lines: r.lines,
    gitBranchRewritten: r.gitBranchRewritten,
    mode: '0' + (srcStat.mode & 0o7777).toString(8),
    truncatedLastLine: r.truncated,
    collisions: (found.collisions || []).map(c => c.slug),
  }) + '\n');
}

main().catch((e) => fail(String((e && e.message) || e)));
