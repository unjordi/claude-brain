#!/usr/bin/env node
/*
 * checkpoint-mecanico.js — el 80% de un checkpoint COMPLETO, a CERO tokens de modelo (M2, auditoría
 * "mudanza de master · checkpoint/compactación", 2026-09-11).
 *
 * Por qué existe: el checkpoint hoy lo produce el actor con MENOS presupuesto (el modelo vivo, justo
 * cuando el contexto está por llenarse). Pero la MITAD del checkpoint —el 🗂️ ÁRBOL, el RESUELTO HOY, las
 * citas textuales del usuario, las métricas de sesión— sale MECÁNICAMENTE del transcript: no necesita
 * criterio, solo lectura. Este script hace ESA mitad, en streaming y con memoria ACOTADA (nunca sostiene
 * el archivo completo — el mismo principio que `rewriteTranscriptStream`/`scanTranscriptFile` de
 * session-lib.js, que reutiliza para la pasada barata de metadatos). Deja al modelo SOLO el juicio: en
 * qué estamos ahora, la decisión a medio cocinar, el siguiente paso y su porqué — que es lo barato de
 * ESCRIBIR (medido: 1.1K-2.8K tokens) y lo caro de DELEGAR.
 *
 * Corte por PRODUCTOR (lo que este script SÍ puede sacar del transcript sin criterio):
 *   - archivos escritos (Write/Edit/NotebookEdit), con conteo
 *   - archivos escritos VÍA BASH (redirección `>`/`>>`, `tee`) — heurística, ver "LÍMITES" abajo
 *   - skills invocadas (conteo)
 *   - comandos bash más frecuentes (primeros 2 tokens) + mensajes de `git commit -m` (verbatim)
 *   - cwds y ramas (gitBranch) vistos
 *   - compactaciones previas (marcador isCompactSummary) y tokens de contexto del ÚLTIMO usage
 *   - los últimos N mensajes de usuario, VERBATIM (filtra saludos/ruido de tool-result)
 *
 * ── LA VENTANA: por default, el TRAMO VIVO (desde el último /compact) ──────────────────────────────
 * MEDIDO el 2026-09-11 sobre dos masters reales (192 MB/39 183 líneas/13 compactaciones y 201 MB/39 221/
 * 13): con la ventana puesta en el transcript ENTERO, los top-N por frecuencia los gana el trabajo VIEJO
 * Y TERMINADO por volumen acumulado de semanas — `reporte_ejecutivo_v2.tex` (34×), `Site.Master` (28×),
 * `dark-theme.css` (25×) encabezando un andamio de una jornada que no tocó ninguno de los tres; los 10
 * `git commit` listados, todos del día ANTERIOR; y la lista de ramas con 4 `worktree-agent-*` muertas.
 * Un andamio de checkpoint describe **lo que está por perderse**, y eso es la ventana VIVA: el tramo
 * desde la última frontera de compactación — la MISMA frontera que el script ya detecta y que ya usaba
 * para resetear `ctxTokens`. Ahora esa frontera gobierna a TODOS los colectores.
 * Lo histórico no se tira: se CUENTA aparte y se etiqueta como tal (`tramosPrevios`). Mezclado, miente.
 * `--ventana todo` restaura el barrido acumulado de todo el archivo (útil para auditar una sesión, no
 * para un checkpoint).
 *
 * ── LÍMITES DECLARADOS del andamio (lo que este script NO ve) ──────────────────────────────────────
 *   · Las escrituras hechas DENTRO de un comando Bash (heredoc, `>`, `tee`, `python - <<EOF`) no son
 *     tool_use de Write/Edit: en modo auto son una fracción grande de las escrituras reales. Se cubren
 *     con una heurística SEPARADA (`bashEscrituras`), listada aparte y etiquetada como heurística —
 *     nunca fusionada con las de Write/Edit, que son exactas. Lo que la heurística NO cubre y se declara:
 *     `sed -i`, `cp`/`mv` de destino, y cualquier escritura hecha por un script invocado (el nombre del
 *     archivo no aparece en la línea de comando).
 *   · El trabajo hecho por SUB-AGENTES vive en OTROS transcripts (`<slug>/<id>/subagents/*.jsonl`): este
 *     barrido es el del transcript que se le pasa, no el del fan-out.
 *   · El *porque Z* de una decisión que nunca se tecleó no está en la traza y ningún extractor lo saca.
 *     Esa mitad es del modelo, por diseño (el JUICIO), y la skill `checkpoint` la sigue pidiendo.
 *
 * Salida: un `.md` "andamio" — SIDECAR, nunca `hilo-mental-actual.md` (ese lo escribe el modelo con
 * criterio; pisarlo a ciegas desde un proceso mecánico sin turno sería exactamente el riesgo que la
 * skill `checkpoint` ya blinda con su "read-before-overwrite"). El skill `checkpoint` FUSIONA este
 * andamio al redactar el hilo real.
 *
 * Uso:
 *   node checkpoint-mecanico.js <transcript.jsonl> --out <andamio.md> [--repo-root <path>] [--n-msgs 12]
 *   node checkpoint-mecanico.js --self [--ensure] [--out <andamio.md>]     ← lo invoca el SKILL
 *   [--ventana viva|todo] [--json]
 * Con --json (o sin --out) imprime el resumen crudo a stdout (para el hook/log).
 *
 * Memoria acotada: streaming por líneas con buffer de 1 MiB; ningún string acumula el archivo completo.
 * Igual que session-lib.js, un renglón patológico (> MAX_LINE_CHARS) se descarta sin abortar el resto.
 */
'use strict';
const fs = require('fs');
const path = require('path');
const { StringDecoder } = require('string_decoder');

let sessionLib = null;
try { sessionLib = require(path.join(__dirname, 'session-lib.js')); } catch (_) { sessionLib = null; }

const MAX_LINE_CHARS = 64 * 1024 * 1024;
const TOP_N = 10;
const DEFAULT_N_MSGS = 12;
const ANDAMIO_REL = path.join('.claude', 'memory', 'hilo-mental-actual.andamio.md');

function parseArgs(argv) {
  const o = {
    file: null, out: null, json: false, repoRoot: null, nMsgs: DEFAULT_N_MSGS,
    ventana: 'viva', self: false, ensure: false,
  };
  const rest = [];
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i];
    if (a === '--out') o.out = argv[++i];
    else if (a === '--json') o.json = true;
    else if (a === '--repo-root') o.repoRoot = argv[++i];
    else if (a === '--n-msgs') o.nMsgs = parseInt(argv[++i], 10) || DEFAULT_N_MSGS;
    else if (a === '--ventana') o.ventana = (argv[++i] === 'todo') ? 'todo' : 'viva';
    else if (a === '--self') o.self = true;
    else if (a === '--ensure') o.ensure = true;
    else rest.push(a);
  }
  o.file = rest[0] || null;
  return o;
}

// Un mensaje de usuario NO aporta señal si es un saludo pelón, un marcador de sistema
// (<command-message>, tool-result, [Request interrupted]) o un bloque de puro tool_result.
const GREETING = /^(?:h+o+l+a+|h+e+y+|o+l+a+|buen(?:os|as)(?: d[ií]as| tardes| noches)?|qu[eé] onda|saludos|hi+|hello+|holi+)[\s!¡.,:;]*$/i;
function isNoisyUserText(t) {
  if (!t) return true;
  const s = t.trim();
  if (!s) return true;
  if (GREETING.test(s)) return true;
  if (/^<command-(message|name)>/.test(s)) return true;
  if (/^\[Request interrupted/.test(s)) return true;
  return false;
}

function add(map, key) { map.set(key, (map.get(key) || 0) + 1); }
function top(map, n) {
  return [...map.entries()].sort((a, b) => b[1] - a[1]).slice(0, n).map(([k, v]) => ({ item: k, n: v }));
}

// ── Escrituras hechas DENTRO de un comando Bash (heurística DECLARADA, nunca mezclada con Write/Edit).
// Captura destinos de redirección (`> f`, `>> f`) y de `tee [-a] f`. Descarta lo que no es un archivo:
// duplicaciones de descriptor (`2>&1`, `>&2`) y los sumideros (`/dev/null`, `/dev/stdout`…). Exige que
// el destino parezca ruta (con `/` o con extensión) para no contar un `> $VAR` ni un `>` suelto.
const RE_REDIR = /(?:^|[^0-9>&=|<-])>>?\s*(?:&\s*)?("[^"]*"|'[^']*'|[^\s;|&()<>]+)/g;
const RE_TEE = /\btee\b\s+(?:-a\s+)?("[^"]*"|'[^']*'|[^\s;|&()<>]+)/g;
function destinosDeEscrituraBash(cmd) {
  const out = [];
  const cosechar = (re, texto) => {
    re.lastIndex = 0;
    let m;
    while ((m = re.exec(texto)) !== null) {
      let d = m[1] || '';
      if (d.length > 1 && ((d[0] === '"' && d[d.length - 1] === '"') || (d[0] === "'" && d[d.length - 1] === "'"))) {
        d = d.slice(1, -1);
      }
      if (!d || d[0] === '&' || /^\d+$/.test(d)) continue;          // 2>&1, >&2, fd sueltos
      if (/^\/dev\//.test(d)) continue;                              // sumideros
      if (d === '/' || d.length < 3) continue;                       // no es un destino
      if (/[-.]$/.test(d)) continue;                                 // truncado/prosa, no un archivo
      if (/^\.[A-Za-z0-9]{1,3}$/.test(d)) continue;                  // una EXTENSIÓN pelona (`.sh`), no una ruta
      if (!(d.indexOf('/') >= 0 || /\.[A-Za-z0-9]{1,8}$/.test(d))) continue;  // no parece archivo
      out.push(d);
    }
  };
  // Se recorre LÍNEA A LÍNEA y se SALTA toda línea que EMPIEZA con `>`. Un comando trae con frecuencia
  // un heredoc, y dentro del heredoc va markdown: una CITA de markdown (`> texto`) es indistinguible de
  // una redirección para un regex. MEDIDO 2026-09-11 sobre un master real: sin este filtro, los falsos
  // positivos `/AUDITOR-` (4×) y `/` (4×) entraban al top — y venían justo de bloques de cita dentro de
  // heredocs. Una redirección REAL casi nunca abre línea, así que el filtro cuesta falsos negativos
  // raros y paga falsos positivos frecuentes. (El resto del heredoc sí se mira: un `> archivo` a media
  // línea de prosa es improbable, y perder las redirecciones reales del comando sería peor.)
  for (const linea of String(cmd).split('\n')) {
    if (/^\s*>/.test(linea)) continue;
    cosechar(RE_REDIR, linea);
    cosechar(RE_TEE, linea);
  }
  return out;
}

// ── Pasada 1 (barata, memoria acotada): reusa session-lib.js si está disponible (X1: el checkpoint
//    dejaba de compartir línea con la mudanza; ahora la comparte de verdad). Si no está (script suelto
//    fuera del repo cortex), degrada a null sin abortar — el resto del extractor no depende de esto.
function metaBarata(file) {
  if (!sessionLib || typeof sessionLib.scanTranscriptFile !== 'function') return null;
  try { return sessionLib.scanTranscriptFile(file, {}); } catch (_) { return null; }
}

// ── Pasada 2 (rica): streaming por líneas, memoria acotada — el mismo patrón de fs.readSync +
//    StringDecoder + partir por '\n' que rewriteTranscriptStream usa para el mismo archivo.
//    opts.ventana: 'viva' (default, resetea en cada frontera de /compact) | 'todo' (acumula el archivo).
function extraer(file, nMsgs, opts) {
  const ventana = (opts && opts.ventana === 'todo') ? 'todo' : 'viva';
  const R = {
    ventana,
    lineas: 0, lineasVivas: 0, compactaciones: 0,
    escrituras: new Map(), bashEscrituras: new Map(), skills: new Map(), comandos: new Map(),
    commits: [], cwds: new Set(), ramas: new Set(),
    ctxTokens: null,
    mensajesUsuario: [], // ring buffer acotado a nMsgs
    // Lo HISTÓRICO (tramos ya compactados) se CUENTA aparte y se etiqueta; nunca se fusiona con lo vivo.
    previos: { tramos: 0, commits: 0, escrituras: 0, mensajes: 0, ramas: new Set(), cwds: new Set() },
  };
  const pushMsg = (texto, ts) => {
    R.mensajesUsuario.push({ ts: ts || null, texto });
    if (R.mensajesUsuario.length > nMsgs) R.mensajesUsuario.shift();
  };
  // Cierra el tramo vivo: contabiliza lo que se va y deja los colectores en cero para el tramo siguiente.
  const cerrarTramo = () => {
    R.previos.tramos++;
    R.previos.commits += R.commits.length;
    R.previos.escrituras += R.escrituras.size;
    R.previos.mensajes += R.mensajesUsuario.length;
    for (const x of R.ramas) R.previos.ramas.add(x);
    for (const x of R.cwds) R.previos.cwds.add(x);
    R.escrituras.clear(); R.bashEscrituras.clear(); R.skills.clear(); R.comandos.clear();
    R.commits.length = 0; R.mensajesUsuario.length = 0;
    R.ramas.clear(); R.cwds.clear();
    R.lineasVivas = 0;
  };
  const onLine = (raw) => {
    if (!raw || !raw.trim()) return;
    R.lineas++;
    R.lineasVivas++;
    let o;
    try { o = JSON.parse(raw); } catch (_) { return; }

    // Mismo anclaje al boundary que aviso-contexto.sh: un `isCompactSummary:true` RESETEA el ctxTokens
    // acumulado — así el usage PRE-compact (que la llamada interna de resumen deja en disco con el
    // tamaño VIEJO completo) no se reporta como si fuera el contexto vivo tras compactar (FP de
    // staleness, el mismo que el hook ya blinda). Si tras el boundary aún no hay usage nuevo, queda null.
    // Y con `ventana=viva`, esa MISMA frontera cierra el tramo para TODOS los colectores (ver cabecera).
    if (o.isCompactSummary === true) {
      R.compactaciones++;
      R.ctxTokens = null;
      if (ventana === 'viva') cerrarTramo();
    }
    if (typeof o.cwd === 'string' && o.cwd) R.cwds.add(o.cwd);
    if (typeof o.gitBranch === 'string' && o.gitBranch) R.ramas.add(o.gitBranch);

    const usage = o.message && o.message.usage;
    if (usage && o.isSidechain !== true) {
      const t = (usage.input_tokens || 0) + (usage.cache_creation_input_tokens || 0) + (usage.cache_read_input_tokens || 0);
      R.ctxTokens = t; // el ÚLTIMO usage gana (orden del archivo = orden temporal)
    }

    // Mensaje de USUARIO textual (verbatim) — filtra ruido/saludos y el resumen SINTÉTICO del propio
    // /compact (isCompactSummary:true trae type:'user'/role:'user' pero NO lo escribió el usuario).
    if (o.type === 'user' && o.isCompactSummary !== true && o.message && o.message.role === 'user') {
      const c = o.message.content;
      let texto = null;
      if (typeof c === 'string') texto = c;
      else if (Array.isArray(c)) {
        const tb = c.find((b) => b && b.type === 'text' && typeof b.text === 'string');
        if (tb) texto = tb.text;
      }
      if (texto && !isNoisyUserText(texto)) pushMsg(texto, o.timestamp || null);
    }

    // tool_use del ASISTENTE: escrituras, skills, comandos bash + commits.
    const c = o.message && o.message.content;
    if (Array.isArray(c)) {
      for (const b of c) {
        if (!b || b.type !== 'tool_use') continue;
        const i = b.input || {};
        if ((b.name === 'Write' || b.name === 'Edit' || b.name === 'NotebookEdit') && i.file_path) {
          add(R.escrituras, i.file_path);
        }
        if (b.name === 'Skill' && i.skill) add(R.skills, i.skill);
        if (b.name === 'Bash' && i.command) {
          const cmd = String(i.command);
          add(R.comandos, cmd.trim().split(/\s+/).slice(0, 2).join(' '));
          const m = /git commit[^\n]*?-m\s+(["'])([\s\S]*?)\1/.exec(cmd);
          if (m) R.commits.push(m[2].split('\n')[0]);
          for (const d of destinosDeEscrituraBash(cmd)) add(R.bashEscrituras, d);
        }
      }
    }
  };

  const st = fs.statSync(file);
  const fd = fs.openSync(file, 'r');
  const dec = new StringDecoder('utf8');
  const buf = Buffer.allocUnsafe(1 << 20); // 1 MiB — memoria de la pasada acotada al buffer, no al archivo
  let pending = '', pos = 0;
  try {
    for (;;) {
      const n = fs.readSync(fd, buf, 0, buf.length, pos);
      if (n <= 0) break;
      pos += n;
      pending += dec.write(buf.slice(0, n));
      let idx;
      while ((idx = pending.indexOf('\n')) >= 0) { onLine(pending.slice(0, idx)); pending = pending.slice(idx + 1); }
      // Renglón patológico (sin '\n' por decenas de MiB): se descarta, no se acumula sin cota.
      if (pending.length > MAX_LINE_CHARS) { pending = ''; }
    }
    pending += dec.end();
    if (pending.length) onLine(pending);
  } finally { fs.closeSync(fd); }

  return { ...R, bytes: st.size };
}

function renderAndamio(meta, r, ctxRepo) {
  const fecha = new Date().toISOString().replace('T', ' ').slice(0, 16) + ' UTC';
  const viva = r.ventana !== 'todo';
  const escrituras = top(r.escrituras, TOP_N);
  const bashEsc = top(r.bashEscrituras, TOP_N);
  const skills = top(r.skills, TOP_N);
  const comandos = top(r.comandos, TOP_N);
  const lines = [];
  lines.push('# Andamio mecánico del checkpoint (auto-generado — NO es el hilo)');
  lines.push('');
  lines.push(`> Generado por \`bin/checkpoint-mecanico.js\` el ${fecha}, en streaming y sin gastar tokens de`);
  lines.push('> modelo. Es INSUMO para el checkpoint, no lo sustituye: el skill `checkpoint` lee este archivo');
  lines.push('> y FUSIONA lo que aplique al `hilo-mental-actual.md`; el juicio (en qué estamos, decisión');
  lines.push('> abierta, siguiente paso, procedencia) lo sigue poniendo el modelo. Este archivo se PISA en');
  lines.push('> cada corrida — no es durable por sí mismo.');
  lines.push('');
  // Cabecera AUDITABLE: sin esto, su frescura no se puede juzgar al leerlo (y un insumo de frescura
  // desconocida presentado como vigente es el modo de falla que el gate del hilo existe para evitar).
  lines.push('## Corte (para juzgar su frescura)');
  lines.push(`- Ventana: **${viva ? 'TRAMO VIVO' : 'TRANSCRIPT COMPLETO'}**`
    + (viva ? ' — desde la última frontera de `/compact`. Lo anterior se cuenta aparte, no se mezcla.'
            : ' — acumulado de toda la sesión: el trabajo VIEJO puede ganar los top-N por volumen.'));
  lines.push(`- Sesión (sid): ${process.env.CLAUDE_CODE_SESSION_ID || '(no disponible)'}`);
  lines.push(`- Transcript: ${r.lineas} líneas totales · ${r.bytes} bytes · ${r.compactaciones} compactaciones detectadas`);
  if (viva) lines.push(`- Tramo vivo: ${r.lineasVivas} líneas (de las ${r.lineas} del archivo)`);
  lines.push(`- Tokens de contexto del ÚLTIMO usage: ${r.ctxTokens === null ? 'sin dato (nada nuevo tras el último compact)' : r.ctxTokens}`);
  lines.push(`- cwd(s) del tramo: ${[...r.cwds].join(', ') || '(ninguno)'}`);
  lines.push(`- Rama(s) del tramo: ${[...r.ramas].join(', ') || '(ninguna)'}`);
  if (ctxRepo) lines.push(`- Repo (CLAUDE_PROJECT_DIR): ${ctxRepo}`);
  if (viva && r.previos.tramos > 0) {
    lines.push(`- **Tramos anteriores (NO listados arriba):** ${r.previos.tramos} tramos · `
      + `${r.previos.commits} commits · ${r.previos.escrituras} escrituras · ${r.previos.mensajes} mensajes · `
      + `${r.previos.ramas.size} ramas · ${r.previos.cwds.size} cwds. Están en el transcript; `
      + 'córrelo con `--ventana todo` si de verdad quieres el acumulado.');
  }
  lines.push('');
  lines.push(`## 🗂️ Archivos tocados con Write/Edit (exacto) — top ${TOP_N} de ${r.escrituras.size}`);
  for (const e of escrituras) lines.push(`- ${e.item} (${e.n}×)`);
  if (!escrituras.length) lines.push('- (ninguno)');
  lines.push('');
  lines.push(`## 🗂️ Archivos escritos desde Bash (HEURÍSTICA: \`>\`, \`>>\`, \`tee\`) — top ${TOP_N} de ${r.bashEscrituras.size}`);
  lines.push('<!-- No confundir con la lista de arriba: ésta es heurística sobre la línea de comando. No ve');
  lines.push('     `sed -i`, `cp`/`mv`, ni lo que escriba un script invocado. Útil en modo auto, donde buena');
  lines.push('     parte de las escrituras NO pasan por la tool Write/Edit. -->');
  for (const e of bashEsc) lines.push(`- ${e.item} (${e.n}×)`);
  if (!bashEsc.length) lines.push('- (ninguno)');
  lines.push('');
  lines.push('## Skills invocadas');
  for (const e of skills) lines.push(`- ${e.item} (${e.n}×)`);
  if (!skills.length) lines.push('- (ninguna)');
  lines.push('');
  lines.push(`## RESUELTO HOY — mensajes de \`git commit\` (${r.commits.length} en el tramo, últimos ${TOP_N})`);
  for (const m of r.commits.slice(-TOP_N)) lines.push(`- ${m}`);
  if (!r.commits.length) lines.push('- (sin commits detectados en el tramo)');
  lines.push('');
  lines.push(`## Comandos Bash más frecuentes (top ${TOP_N})`);
  for (const e of comandos) lines.push(`- \`${e.item}\` (${e.n}×)`);
  if (!comandos.length) lines.push('- (ninguno)');
  lines.push('');
  lines.push(`## Últimos ${r.mensajesUsuario.length} mensajes del usuario (VERBATIM, para citar con \`[user: "…"]\`)`);
  for (const m of r.mensajesUsuario) {
    const t = m.texto.length > 800 ? m.texto.slice(0, 800) + '…[truncado]' : m.texto;
    lines.push(`- ${m.ts ? `(${m.ts}) ` : ''}"${t.replace(/\n/g, ' ')}"`);
  }
  if (!r.mensajesUsuario.length) lines.push('- (ninguno)');
  lines.push('');
  return lines.join('\n');
}

function morir(codigo, msg) { process.stderr.write(msg + '\n'); process.exit(codigo); }

// ── `--self`: resolver MI PROPIO transcript, para que el SKILL pueda regenerar el andamio sin depender
//    de que haya ocurrido un PreCompact (restricción del dueño: "no que PreCompact sea el único
//    mecanismo"). FALLA CERRADO en un subagente:
//    MEDIDO 2026-09-11 — dentro de un subagente, `CLAUDE_CODE_SESSION_ID` trae el sid del PADRE (con
//    `CLAUDE_CODE_CHILD_SESSION=1` en el entorno). Sin este candado, un subagente regeneraría el andamio
//    del padre creyendo que es el suyo: un artefacto que certifica lo que no verificó.
function resolverSelf(repoRoot) {
  if (process.env.CLAUDE_CODE_CHILD_SESSION === '1') {
    morir(3, '--self rehúsa correr dentro de un SUBAGENTE: CLAUDE_CODE_SESSION_ID es el sid del PADRE,\n'
      + '  así que regeneraría el andamio de OTRA sesión. Que lo corra el hilo principal, o pasa el\n'
      + '  transcript explícito: checkpoint-mecanico.js <transcript.jsonl> --out <andamio.md>');
  }
  const sid = (process.env.CLAUDE_CODE_SESSION_ID || '').trim();
  if (!sid) {
    morir(3, '--self: no hay CLAUDE_CODE_SESSION_ID en el entorno (¿fuera de Claude Code?).\n'
      + '  Pasa el transcript explícito: checkpoint-mecanico.js <transcript.jsonl> --out <andamio.md>');
  }
  if (!sessionLib || typeof sessionLib.projectsDir !== 'function') {
    morir(3, '--self: no encuentro session-lib.js junto a este script, así que no puedo derivar el slug.');
  }
  // 1) la ruta directa: <projects>/<slug del cwd>/<sid>.jsonl — es la que usa el harness.
  const base = repoRoot || process.cwd();
  let directo = null;
  try { directo = path.join(sessionLib.projectsDir(), sessionLib.slugForRepo(base), sid + '.jsonl'); } catch (_) {}
  if (directo && fs.existsSync(directo)) return { file: directo, sid, via: 'slug-del-cwd' };
  // 2) respaldo: barrer todos los slugs por id (read-only; aquí no hay ningún unlink que proteger).
  try {
    const f = sessionLib.findSession(sid);
    if (f && f.file && fs.existsSync(f.file)) return { file: f.file, sid, via: 'findSession' };
  } catch (_) {}
  morir(3, `--self: no encontré el transcript de la sesión ${sid}.\n`
    + `  Probé ${directo || '(sin ruta directa)'} y el barrido por id.`);
}

function main() {
  const o = parseArgs(process.argv.slice(2));
  let selfVia = null;

  if (o.self) {
    const s = resolverSelf(o.repoRoot);
    o.file = s.file;
    selfVia = s.via;
    if (!o.out) o.out = path.join(o.repoRoot || process.cwd(), ANDAMIO_REL);
  }
  if (!o.file) {
    morir(2, 'uso: checkpoint-mecanico.js <transcript.jsonl> [--out <andamio.md>] [--repo-root <path>]\n'
      + '                                 [--n-msgs N] [--ventana viva|todo] [--json]\n'
      + '     checkpoint-mecanico.js --self [--ensure] [--out <andamio.md>]');
  }
  if (!fs.existsSync(o.file)) morir(1, `no existe: ${o.file}`);

  // `--ensure`: regenerar SOLO si el andamio quedó ATRÁS del transcript. El skill lo invoca así en cada
  // checkpoint: si el hook de PreCompact ya lo escribió hace un segundo, esto es un no-op VERIFICADO
  // (lo dice, no calla); si el andamio es viejo o no existe, lo produce. Así el andamio nunca es un
  // insumo de frescura desconocida.
  if (o.ensure) {
    if (!o.out) morir(2, '--ensure necesita --out (o --self, que lo deduce)');
    let mtOut = 0, mtSrc = 0;
    try { mtOut = fs.statSync(o.out).mtimeMs; } catch (_) { mtOut = 0; }
    try { mtSrc = fs.statSync(o.file).mtimeMs; } catch (_) { mtSrc = 0; }
    if (mtOut > 0 && mtOut >= mtSrc) {
      process.stdout.write(JSON.stringify({
        ensure: 'no-op', motivo: 'el andamio ya es igual o más fresco que el transcript',
        out: o.out, andamioMtime: new Date(mtOut).toISOString(), transcriptMtime: new Date(mtSrc).toISOString(),
        self: o.self ? selfVia : null,
      }, null, 1) + '\n');
      return;
    }
  }

  const t0 = Date.now();
  const meta = metaBarata(o.file);
  const r = extraer(o.file, o.nMsgs, { ventana: o.ventana });
  const ms = Date.now() - t0;

  const md = renderAndamio(meta, r, o.repoRoot);
  if (o.out) {
    fs.mkdirSync(path.dirname(o.out), { recursive: true });
    const tmp = o.out + '.tmp.' + process.pid;
    fs.writeFileSync(tmp, md, 'utf8');
    fs.renameSync(tmp, o.out); // atómico: nunca deja el andamio a medias
  }
  // `--ensure` SIEMPRE reporta su resultado (regenerado | no-op): es un comando de ESTADO y el skill
  // lo invoca con --out puesto. Antes el no-op imprimía y el "regenerado" callaba ⇒ el invocador no
  // podía distinguir "lo regeneré" de "falló en silencio".
  if (o.json || !o.out || o.ensure) {
    process.stdout.write(JSON.stringify({
      ensure: o.ensure ? 'regenerado' : undefined,
      ventana: r.ventana, self: o.self ? selfVia : null,
      lineas: r.lineas, lineasVivas: r.lineasVivas, bytes: r.bytes, ms,
      rss_MB: Math.round(process.memoryUsage().rss / (1024 * 1024) * 10) / 10,
      compactaciones: r.compactaciones, ctxTokens: r.ctxTokens,
      cwds: [...r.cwds], ramas: [...r.ramas],
      archivosEscritos: r.escrituras.size, topEscrituras: top(r.escrituras, TOP_N),
      bashEscritos: r.bashEscrituras.size, topBashEscrituras: top(r.bashEscrituras, TOP_N),
      skillsInvocadas: top(r.skills, TOP_N), topComandos: top(r.comandos, TOP_N),
      commitsTotal: r.commits.length, commits: r.commits.slice(-TOP_N),
      mensajesUsuario: r.mensajesUsuario.length,
      // El VERBATIM también en el JSON: son lo más valioso del andamio y, expuesto solo como CONTEO, un
      // consumidor del JSON no puede saber que existe (le pasó a quien corrió el script sin --out).
      mensajesUsuarioTexto: r.mensajesUsuario.map((m) => ({
        ts: m.ts, texto: m.texto.length > 300 ? m.texto.slice(0, 300) + '…[truncado]' : m.texto,
      })),
      tramosPrevios: {
        tramos: r.previos.tramos, commits: r.previos.commits, escrituras: r.previos.escrituras,
        mensajes: r.previos.mensajes, ramas: [...r.previos.ramas], cwds: [...r.previos.cwds],
      },
      out: o.out || null,
    }, null, 1) + '\n');
  }
}

if (require.main === module) main();
module.exports = { extraer, renderAndamio, metaBarata, isNoisyUserText, destinosDeEscrituraBash };
