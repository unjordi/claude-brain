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
 *
 * TAMAÑO: los transcripts llegan a cientos de MB y un string de Node topa en MAX_TEXT_BYTES
 * (~512 MiB) — leer uno completo puede ser IMPOSIBLE, no solo caro. Por eso el camino que MUTA
 * archivos va en STREAMING (`rewriteTranscriptStream`, `scanTranscriptFile`): memoria acotada y sin
 * techo. Los helpers que reciben TEXTO (`rewriteCwd`, `firstCwd`, `lastActivity`,
 * `titleFromTranscript`) siguen ahí para quien ya tiene el texto en mano; para leerlo de disco usa
 * `readTranscriptText`, que falla con un mensaje claro en vez de reventar dentro de V8.
 */
const fs = require('fs');
const os = require('os');
const path = require('path');
const { StringDecoder } = require('string_decoder');

// Techo DURO de un string en este Node: readFileSync(...,'utf8') LANZA por encima de esto.
const MAX_TEXT_BYTES = require('buffer').constants.MAX_STRING_LENGTH;

// Tope de UN renglón acumulado en RAM por los barridos en streaming. Un renglón real de transcript
// mide KB; uno que pase de esto es un archivo corrupto o sin '\n' — y acumularlo en un string volvería
// a topar con MAX_TEXT_BYTES, que es justo lo que el streaming existe para evitar. Al cruzarlo, el
// renglón se trata como OPACO: se copia verbatim y no se le reescribe nada.
const MAX_LINE_CHARS = 64 * 1024 * 1024;

function claudeBase() {
  const cfg = process.env.CLAUDE_CONFIG_DIR;
  return (cfg && cfg.length) ? cfg : path.join(os.homedir(), '.claude');
}
function projectsDir() { return path.join(claudeBase(), 'projects'); }

// Slug tal como lo deriva Claude Code del cwd: cada carácter no alfanumérico -> '-'.
// Es la REGLA de caracteres y nada más: espera una ruta ya NORMALIZADA. Para derivar el slug de una
// ruta que te dio un humano o un widget usa `slugForRepo` (normaliza primero) — con la ruta cruda, una
// barra final, una ruta relativa o un prefijo symlink producen un slug que el harness nunca mirará.
function slugFromCwd(cwd) { return cwd.replace(/[^a-zA-Z0-9]/g, '-'); }

// Normaliza una ruta de proyecto a la MISMA forma que el `process.cwd()` del harness, que es de donde
// sale el slug real: absoluta, sin barra final, sin '.'/'..' y FÍSICA (getcwd(3) devuelve la ruta
// resuelta, así que un prefijo symlink —macOS /tmp→/private/tmp, un home en /Volumes— daría otro slug).
// Windows: Git Bash/MSYS y Cygwin hablan `/c/Users/...` mientras el harness corre con `C:\Users\...`;
// aquí se traduce a la forma NATIVA para que ambos deriven el MISMO slug. Al revés (una ruta `C:\...`
// en una máquina POSIX) es irresoluble → lanza, en vez de fabricar un slug fantasma.
// Lanza Error si la ruta es vacía o intraducible; si simplemente NO EXISTE la devuelve resuelta
// lexicográficamente, y que exista o no lo juzga el llamador con `cwdExists`.
function normalizeCwd(p) {
  if (typeof p !== 'string' || !p.trim()) throw new Error('ruta de proyecto vacía');
  let s = p.trim();
  if (process.platform === 'win32') {
    const m = /^\/(?:cygdrive\/)?([A-Za-z])(\/.*)?$/.exec(s);
    if (m) s = m[1].toUpperCase() + ':' + ((m[2] || '/').replace(/\//g, '\\'));
  } else if (/^[A-Za-z]:[\\/]/.test(s) || s.startsWith('\\\\')) {
    throw new Error('la ruta "' + p + '" es de estilo Windows y esta máquina es ' + process.platform
      + ': no puedo resolverla ni derivar el slug que usaría el harness. Pásame la ruta LOCAL del'
      + ' proyecto (en Git Bash valen tanto /c/Users/... como C:\\Users\\..., pero solo EN Windows).');
  }
  s = path.resolve(s);
  try { s = fs.realpathSync(s); } catch (_) { /* no existe: lo juzga el llamador */ }
  if (s.length > 1 && !/^[A-Za-z]:[\\/]$/.test(s)) s = s.replace(/[\\/]+$/, '');
  return s;
}

function cwdExists(p) {
  try { return fs.statSync(p).isDirectory(); } catch (_) { return false; }
}

// Slug de un proyecto a partir de la ruta que te dieron: normaliza y aplica la regla del harness.
// ÚNICA vía correcta de derivar un slug — move, import y cualquier otro consumidor usan esta.
function slugForRepo(p) { return slugFromCwd(normalizeCwd(p)); }

// Lee un transcript COMPLETO a un string, con el techo DECLARADO en vez de una excepción cruda de V8.
function readTranscriptText(file) {
  let st;
  try { st = fs.statSync(file); } catch (e) { throw new Error('no puedo medir ' + file + ': ' + e.message); }
  if (st.size >= MAX_TEXT_BYTES) {
    throw new Error('el transcript mide ' + st.size + ' bytes y el techo de un string de Node es '
      + MAX_TEXT_BYTES + ' (~512 MiB): NO se puede leer completo. Ve por la vía en STREAMING'
      + ' (scanTranscriptFile / rewriteTranscriptStream, la que usan session-move/export/import).');
  }
  return fs.readFileSync(file, 'utf8');
}

// Transforma UN renglón del transcript. Preserva tal cual lo que no parsea (p. ej. la última línea
// cortada de una sesión viva) para no corromper el archivo. Devuelve {out, cwdChanged}.
function transformLine(piece, toCwd) {
  if (typeof toCwd !== 'string' || !piece.trim()) return { out: piece, cwdChanged: false };
  let o;
  try { o = JSON.parse(piece); } catch (_) { return { out: piece, cwdChanged: false }; }
  if (typeof o.cwd === 'string' && o.cwd && o.cwd !== toCwd) {
    o.cwd = toCwd;
    return { out: JSON.stringify(o), cwdChanged: true };
  }
  return { out: piece, cwdChanged: false };
}

// Localiza el <id>.jsonl bajo projects/<algún-slug>/. Devuelve {slug, file, activity, collisions} o null.
// TIE-BREAK DETERMINISTA: si el mismo id existe en >1 slug (p. ej. un move a medias que dejó copia en
// origen y destino), `readdirSync` los lista en orden de FS ARBITRARIO → devolver "el primero que tope"
// sería no-determinista (`claude --resume`/session-move podrían tomar copias distintas entre corridas).
// Se recogen TODAS y se elige por CONTENIDO: última actividad del transcript (el `timestamp` más
// reciente de su cola) → tamaño → mtime → slug asc. El contenido manda sobre el mtime porque un
// respaldo VIEJO restaurado trae mtime de HOY y por mtime ganaría siendo la copia muerta. El sondeo de
// contenido corre solo si hay colisión (con una sola copia no hay nada que desempatar).
// Las demás van en `collisions` para que el llamador AVISE del duplicado.
function findSession(id) {
  const dir = projectsDir();
  let slugs;
  try {
    slugs = fs.readdirSync(dir, { withFileTypes: true }).filter(e => e.isDirectory()).map(e => e.name);
  } catch (_) { return null; }
  const matches = [];
  for (const slug of slugs) {
    const file = path.join(dir, slug, id + '.jsonl');
    let st;
    try { st = fs.statSync(file); } catch (_) { continue; }
    if (st.isFile()) matches.push({ slug, file, mtimeMs: st.mtimeMs, bytes: st.size, ts: null });
  }
  if (matches.length === 0) return null;
  if (matches.length > 1) {
    for (const m of matches) {
      try { m.ts = scanTranscriptFile(m.file, { tailBytes: 256 * 1024 }).ts; } catch (_) { m.ts = null; }
    }
  }
  matches.sort((a, b) =>
    ((b.ts === null ? -1 : b.ts) - (a.ts === null ? -1 : a.ts))
    || (b.bytes - a.bytes)
    || (b.mtimeMs - a.mtimeMs)
    || (a.slug < b.slug ? -1 : a.slug > b.slug ? 1 : 0));
  const chosen = matches[0];
  return {
    slug: chosen.slug,
    file: chosen.file,
    activity: { ts: chosen.ts, bytes: chosen.bytes, mtimeMs: chosen.mtimeMs },
    collisions: matches.slice(1).map(m => ({ slug: m.slug, file: m.file, ts: m.ts, bytes: m.bytes })),
  };
}

// Reescribe el cwd de cada línea JSON del transcript al destino. Recibe el TEXTO, no la ruta. Preserva
// tal cual las líneas que no parsean (p. ej. la última cortada) para no corromper el archivo.
// Devuelve {text, count}. Para un archivo de disco usa `rewriteTranscriptStream` (sin techo de tamaño).
function rewriteCwd(srcText, toCwd) {
  let count = 0;
  const out = srcText.split('\n').map((line) => {
    const t = transformLine(line, toCwd);
    if (t.cwdChanged) count++;
    return t.out;
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

// Frescura de un transcript: {ts, lines}. `ts` = el MAYOR `timestamp` (ms epoch) hallado en las líneas
// (robusto a reordenamientos); `lines` = nº de líneas JSON parseables (proxy monótono del avance de una
// conversación append-only). Sirve para decidir si una copia entrante REGRESARÍA una sesión más viva.
// Devuelve {ts:null, lines:0} si no hay señal (fail-safe: sin señal, no se puede afirmar frescura).
// Gemelo de disco, en streaming y sin techo de tamaño: `scanTranscriptFile`.
function lastActivity(srcText) {
  let ts = null, lines = 0;
  for (const line of srcText.split('\n')) {
    if (!line.trim()) continue;
    let o; try { o = JSON.parse(line); } catch (_) { continue; }
    lines++;
    if (typeof o.timestamp === 'string' && o.timestamp) {
      const t = Date.parse(o.timestamp);
      if (!Number.isNaN(t) && (ts === null || t > ts)) ts = t;
    }
  }
  return { ts, lines };
}

// Título legible de la sesión: prioriza el custom-title/ai-title que el CLI nuevo (v2.1.218)
// ya escribe DENTRO del jsonl; si no hay, el llamador cae al alias del widget. String o null.
function titleFromTranscript(srcText) {
  const t = titlesFromText(srcText);
  return t.customTitle || t.aiTitle;
}

// Los dos títulos POR SEPARADO. El merge de arriba pierde cuál es cuál, y la distinción importa: el
// `customTitle` es el que el usuario fijó y el que el picker muestra, así que manda sobre cualquier
// alias (local o embarcado en un .meta.json), mientras el `aiTitle` es solo un respaldo generado.
function titlesFromText(srcText) {
  let customTitle = null, aiTitle = null;
  for (const line of srcText.split('\n')) {
    if (!line.trim()) continue;
    let o; try { o = JSON.parse(line); } catch (_) { continue; }
    if (o.type === 'custom-title' && o.customTitle) customTitle = String(o.customTitle);   // el último gana
    if (o.type === 'ai-title' && o.aiTitle && !aiTitle) aiTitle = String(o.aiTitle);
  }
  return { customTitle, aiTitle };
}

// Barre un transcript de DISCO en streaming (memoria acotada, sin techo de tamaño) y devuelve los
// metadatos que la maquinaria necesita: {bytes, lines, ts, firstCwd, customTitle, aiTitle, truncated}.
//   - `lines` = renglones no vacíos; `ts` = el `timestamp` más reciente; `truncated` = el archivo NO
//     termina en '\n' (última línea a medio escribir, caso NORMAL de una sesión viva).
//   - opts.tailBytes > 0 ⇒ lee SOLO la cola: barato y O(1), suficiente para `ts` (el transcript es
//     append-only) pero deja `lines`/`firstCwd`/títulos en null.
// El `timestamp` sale por regex del renglón crudo (barrer cientos de MB con un JSON.parse por línea no
// es viable); `cwd` y los títulos sí se parsean, pero solo en los pocos renglones que los mencionan.
function scanTranscriptFile(file, opts) {
  const tailBytes = (opts && opts.tailBytes > 0) ? opts.tailBytes : 0;
  const st = fs.statSync(file);
  const res = {
    bytes: st.size, lines: tailBytes ? null : 0, ts: null,
    firstCwd: null, customTitle: null, aiTitle: null, truncated: false,
  };
  if (st.size === 0) return res;
  const start = tailBytes ? Math.max(0, st.size - tailBytes) : 0;
  const fd = fs.openSync(file, 'r');
  const dec = new StringDecoder('utf8');
  const buf = Buffer.allocUnsafe(1 << 20);
  const tsRe = /"timestamp"\s*:\s*"([^"]+)"/;
  let pending = '', pos = start, lastByte = null, skipFirst = start > 0, skipRest = false;
  const take = (piece) => {
    if (skipRest) { skipRest = false; return; }     // cola de un renglón opaco ya contabilizado
    if (skipFirst) { skipFirst = false; return; }   // la cola arranca a media línea: ese trozo se descarta
    if (!piece.trim()) return;
    if (res.lines !== null) res.lines++;
    const m = tsRe.exec(piece);
    if (m) { const t = Date.parse(m[1]); if (!Number.isNaN(t) && (res.ts === null || t > res.ts)) res.ts = t; }
    if (tailBytes) return;
    if (res.firstCwd === null && piece.indexOf('"cwd"') >= 0) {
      try { const o = JSON.parse(piece); if (typeof o.cwd === 'string' && o.cwd) res.firstCwd = o.cwd; } catch (_) {}
    }
    if (piece.indexOf('-title"') >= 0) {
      try {
        const o = JSON.parse(piece);
        if (o.type === 'custom-title' && o.customTitle) res.customTitle = String(o.customTitle);
        if (o.type === 'ai-title' && o.aiTitle && !res.aiTitle) res.aiTitle = String(o.aiTitle);
      } catch (_) {}
    }
  };
  try {
    for (;;) {
      const n = fs.readSync(fd, buf, 0, buf.length, pos);
      if (n <= 0) break;
      pos += n;
      lastByte = buf[n - 1];
      pending += dec.write(buf.slice(0, n));
      let i;
      while ((i = pending.indexOf('\n')) >= 0) { take(pending.slice(0, i)); pending = pending.slice(i + 1); }
      if (pending.length > MAX_LINE_CHARS) { take(pending); pending = ''; skipRest = true; }
    }
    pending += dec.end();
    if (pending.length) take(pending);
  } finally { fs.closeSync(fd); }
  res.truncated = lastByte !== null && lastByte !== 0x0a;
  return res;
}

// Copia un transcript de un stream a `dstFile` reescribiendo su `cwd` renglón por renglón, con memoria
// ACOTADA: nunca sostiene el archivo completo, así que no topa con el techo de ~512 MiB de un string ni
// produce el pico de ~6× el tamaño del archivo que da leer-partir-mapear-unir en RAM.
// Semántica idéntica a `rewriteCwd`: el archivo se parte por '\n', cada trozo se transforma
// independientemente y lo que no parsea pasa VERBATIM (así la última línea cortada de una sesión viva
// no corrompe nada ni aborta el move).
// opts:
//   - toCwd: ruta a escribir en cada `cwd` (ausente ⇒ copia sin tocar el cwd).
//   - gitBranch: si es string, además fija ese `gitBranch` en el ÚLTIMO renglón que lleve `cwd` —el par
//     (cwd, gitBranch) que el harness hereda al reanudar—, sin tocar las ramas HISTÓRICAS. Para eso
//     retiene en RAM la COLA del archivo (tope `holdBytes`, 8 MiB por default); si el último evento con
//     cwd quedara fuera de esa cola, no se toca nada y `gitBranchRewritten` vuelve en 0.
// Devuelve una promesa con {lines, cwdRewritten, gitBranchRewritten, bytesOut, truncated}.
// Hace fsync antes de cerrar, y ante error cierra el fd y BORRA `dstFile` (nunca deja un destino a
// medias). El llamador escribe a un temporal y luego hace rename.
function rewriteTranscriptStream(readable, dstFile, opts) {
  const o = opts || {};
  const toCwd = (typeof o.toCwd === 'string') ? o.toCwd : null;
  const gitBranch = (typeof o.gitBranch === 'string') ? o.gitBranch : null;
  const holdBytes = gitBranch === null ? 0 : (o.holdBytes > 0 ? o.holdBytes : 8 * 1024 * 1024);
  const OUT_FLUSH = 1 << 18;   // 256 KiB de salida acumulada antes de bajar al fd
  return new Promise((resolve, reject) => {
    const fd = fs.openSync(dstFile, 'w', 0o600);
    const dec = new StringDecoder('utf8');
    let out = [], outLen = 0, bytesOut = 0;
    let pending = '', first = true, lastNewline = false;
    let hold = [], holdLen = 0;
    let lines = 0, cwdRewritten = 0, gitBranchRewritten = 0;
    let done = false, opaque = false;

    // Vuelca el buffer de salida al fd. Va por Buffer y con REINTENTO del resto: un `writeSync` puede
    // escribir menos bytes de los pedidos, y darlo por hecho perdería un trozo del transcript en silencio.
    const flush = () => {
      if (!out.length) return;
      const b = Buffer.from(out.join(''), 'utf8'); out = []; outLen = 0;
      let off = 0;
      while (off < b.length) {
        const n = fs.writeSync(fd, b, off, b.length - off);
        if (n <= 0) throw new Error('escritura de 0 bytes en ' + dstFile);
        off += n;
      }
      bytesOut += b.length;
    };
    const raw = (s) => { if (s.length) { out.push(s); outLen += s.length; } if (outLen >= OUT_FLUSH) flush(); };
    const emit = (piece) => { if (first) { first = false; raw(piece); } else { raw('\n'); raw(piece); } };
    const push = (piece) => {
      if (!holdBytes) { emit(piece); return; }
      hold.push(piece); holdLen += piece.length + 1;
      while (hold.length > 1 && holdLen > holdBytes) { const p = hold.shift(); holdLen -= p.length + 1; emit(p); }
    };
    const take = (piece) => {
      if (piece.trim()) lines++;
      const t = transformLine(piece, toCwd);
      if (t.cwdChanged) cwdRewritten++;
      push(t.out);
    };
    const drainHold = () => { for (const p of hold) emit(p); hold = []; holdLen = 0; };
    // Renglón que pasó MAX_LINE_CHARS (archivo corrupto o sin '\n'): se copia VERBATIM a trozos, sin
    // transformar ni retener nada — acumularlo para parsearlo volvería a topar con el techo del string.
    const openOpaque = (chunkStr) => {
      drainHold();
      if (first) first = false; else raw('\n');
      raw(chunkStr);
      lines++;
      opaque = true;
    };
    const abort = (err) => {
      if (done) return;
      done = true;
      try { fs.closeSync(fd); } catch (_) {}
      try { fs.unlinkSync(dstFile); } catch (_) {}
      reject(err instanceof Error ? err : new Error(String(err)));
    };

    readable.on('data', (chunk) => {
      if (done) return;
      try {
        if (chunk.length) lastNewline = chunk[chunk.length - 1] === 0x0a;
        pending += dec.write(chunk);
        for (;;) {
          const i = pending.indexOf('\n');
          if (i >= 0) {
            if (opaque) { raw(pending.slice(0, i)); opaque = false; } else { take(pending.slice(0, i)); }
            pending = pending.slice(i + 1);
            continue;
          }
          if (pending.length > MAX_LINE_CHARS) {
            if (opaque) raw(pending); else openOpaque(pending);
            pending = '';
          }
          break;
        }
      } catch (e) { readable.destroy(); abort(e); }
    });
    readable.on('error', abort);
    readable.on('end', () => {
      if (done) return;
      try {
        pending += dec.end();
        if (opaque) { raw(pending); opaque = false; } else { take(pending); }
        if (gitBranch !== null) {
          for (let i = hold.length - 1; i >= 0; i--) {
            if (!hold[i].trim()) continue;
            let obj; try { obj = JSON.parse(hold[i]); } catch (_) { continue; }
            if (typeof obj.cwd !== 'string' || !obj.cwd) continue;
            obj.gitBranch = gitBranch;
            hold[i] = JSON.stringify(obj);
            gitBranchRewritten = 1;
            break;
          }
        }
        drainHold();
        flush();
        fs.fsyncSync(fd);
        fs.closeSync(fd);
        done = true;
        resolve({ lines, cwdRewritten, gitBranchRewritten, bytesOut, truncated: !lastNewline });
      } catch (e) { abort(e); }
    });
  });
}

const aliasFile = () => path.join(claudeBase(), 'sesiones-alias.json');

// Mapa {sessionId: label}. Fail-open: sin archivo / JSON inválido -> {}. Es un LECTOR cosmético; el
// camino de ESCRITURA no puede apoyarse en este fallback (degradar a {} borraría todos los alias).
function sessionAliases() {
  try {
    const o = JSON.parse(fs.readFileSync(aliasFile(), 'utf8'));
    return (o && typeof o === 'object' && !Array.isArray(o)) ? o : {};
  } catch (_) { return {}; }
}

// Fija/actualiza el alias de una sesión (merge, no pisa el resto). No-op si label es vacío; devuelve
// true si quedó escrito. Escritura ATÓMICA (tmp en el MISMO dir + rename): un archivo a medio escribir
// nunca pisa el bueno. Y un JSON ILEGIBLE no se degrada a {} —eso reemplazaría el mapa entero por una
// sola entrada, borrando en silencio todos los demás alias—: se RESPALDA a un lado y se avisa.
function writeAlias(id, label) {
  if (!label) return false;
  const f = aliasFile();
  let m = {}, mode = 0o600, raw = null;
  try { raw = fs.readFileSync(f, 'utf8'); mode = fs.statSync(f).mode & 0o7777; } catch (_) { raw = null; }
  if (raw !== null) {
    let parsed = null;
    try { parsed = JSON.parse(raw); } catch (_) { parsed = null; }
    if (parsed && typeof parsed === 'object' && !Array.isArray(parsed)) {
      m = parsed;
    } else {
      const keep = f + '.ilegible.' + Date.now();
      try { fs.copyFileSync(f, keep); } catch (_) {}
      process.stderr.write('AVISO: ' + f + ' no es un JSON de objeto. Lo respaldé en ' + keep
        + ' y escribo un mapa nuevo con solo el alias de ' + id + '; reconcilia a mano lo que hubiera.\n');
    }
  }
  m[id] = String(label);
  const tmp = f + '.tmp.' + process.pid;
  try {
    fs.mkdirSync(claudeBase(), { recursive: true });
    fs.writeFileSync(tmp, JSON.stringify(m, null, 2) + '\n', { mode });
    fs.renameSync(tmp, f);
    return true;
  } catch (e) {
    try { fs.unlinkSync(tmp); } catch (_) {}
    process.stderr.write('AVISO: no pude escribir el alias de ' + id + ': ' + String(e && e.message || e) + '\n');
    return false;
  }
}

module.exports = {
  MAX_TEXT_BYTES,
  claudeBase, projectsDir,
  slugFromCwd, normalizeCwd, cwdExists, slugForRepo,
  findSession, rewriteCwd, transformLine,
  readTranscriptText, scanTranscriptFile, rewriteTranscriptStream,
  firstCwd, lastActivity, titleFromTranscript, titlesFromText,
  sessionAliases, writeAlias,
};
