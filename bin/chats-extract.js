#!/usr/bin/env node
/*
 * chats-extract.js — Extractor robusto de la lista de conversaciones del app
 * de escritorio de Claude, leyendo su cache LOCAL de IndexedDB. Sin red.
 *
 * Uso:
 *   node chats-extract.js [ruta]
 *
 *   [ruta] puede ser:
 *     - el directorio IndexedDB del app
 *       (~/Library/Application Support/Claude/IndexedDB) [default en macOS]
 *     - el subdirectorio ..._0.indexeddb.blob
 *     - un archivo de blob concreto (p.ej. .../blob/1/1b/1b24)
 *
 * Salida (stdout): JSON array de {uuid, title, summary, model, updated_at, created_at}
 * ordenado por updated_at descendente (más reciente primero).
 *
 * Cómo funciona:
 *   1) Hace un snapshot del dir IndexedDB a /tmp (la DB está viva) y trabaja ahí.
 *   2) Localiza el blob que contiene "conversations_v2".
 *   3) El blob = 3 bytes de envoltorio Blink + stream Snappy. Descomprime Snappy.
 *   4) El resultado es structured-clone de Blink que envuelve una carga V8
 *      ValueSerializer. Se deserializa el GRAFO de objetos V8 completo
 *      (objetos/arrays/refs/fechas/strings latin1+utf8+utf16le).
 *   5) Se recorre el grafo y se cosechan los objetos que "parecen" conversación.
 */

const fs = require('fs');
const os = require('os');
const path = require('path');

// Ruta default del dir IndexedDB del app de escritorio de Claude, por OS.
function defaultIdbDir(HOME) {
  if (process.platform === 'darwin')
    return path.join(HOME, 'Library', 'Application Support', 'Claude', 'IndexedDB');
  if (process.platform === 'win32')
    return path.join(process.env.APPDATA || path.join(HOME, 'AppData', 'Roaming'), 'Claude', 'IndexedDB');
  return path.join(HOME, '.config', 'Claude', 'IndexedDB');   // linux (Electron)
}

// ------------------------------------------------------------------ Snappy
// Descompresor de bloque Snappy (raw, sin framing). Suficiente para el blob.
function snappyDecompress(buf, start = 0) {
  let p = start;
  let len = 0, sh = 0;
  while (true) {
    const b = buf[p++];
    len |= (b & 0x7f) << sh;
    sh += 7;
    if (!(b & 0x80)) break;
    if (sh > 35) throw new Error('snappy: preamble length overflow');
  }
  const out = Buffer.alloc(len);
  let o = 0;
  while (o < len) {
    const tag = buf[p++];
    const t = tag & 3;
    if (t === 0) {
      let l = tag >> 2;
      if (l >= 60) {
        const n = l - 59;
        l = 0;
        for (let i = 0; i < n; i++) l |= buf[p++] << (8 * i);
      }
      l += 1;
      buf.copy(out, o, p, p + l);
      p += l; o += l;
    } else {
      let off, l;
      if (t === 1) { l = ((tag >> 2) & 7) + 4; off = ((tag >> 5) << 8) | buf[p++]; }
      else if (t === 2) { l = (tag >> 2) + 1; off = buf[p] | (buf[p + 1] << 8); p += 2; }
      else { l = (tag >> 2) + 1; off = (buf[p] | (buf[p + 1] << 8) | (buf[p + 2] << 16) | (buf[p + 3] << 24)) >>> 0; p += 4; }
      if (off === 0 || off > o) throw new Error('snappy: bad copy offset');
      for (let i = 0; i < l; i++) { out[o] = out[o - off]; o++; }
    }
  }
  return { out, end: p };
}

// Encuentra un stream Snappy válido dentro del blob (probando offsets pequeños)
// que contenga el marcador dado. Devuelve el buffer descomprimido.
function snappyFromBlob(buf, marker) {
  for (let s = 0; s < Math.min(buf.length, 64); s++) {
    try {
      const { out } = snappyDecompress(buf, s);
      if (out.includes(marker)) return out;
    } catch (_) { /* sigue probando */ }
  }
  return null;
}

// -------------------------------------------------- V8 ValueSerializer parser
class V8Reader {
  constructor(buf) {
    this.b = buf;
    this.p = 0;
    this.ids = [];        // objetos indexados por id (para '^' referencias)
    this.version = 0;
  }
  u8() { return this.b[this.p++]; }
  varint() {
    let n = 0, sh = 0;
    while (true) {
      const b = this.b[this.p++];
      n += (b & 0x7f) * Math.pow(2, sh);   // usa aritmética float p/ >32 bits
      sh += 7;
      if (!(b & 0x80)) break;
    }
    return n;
  }
  zigzag() {
    const n = this.varint();
    return (n % 2 ? -(n + 1) / 2 : n / 2);
  }
  double() {
    const v = this.b.readDoubleLE(this.p);
    this.p += 8;
    return v;
  }
  register(obj) { this.ids.push(obj); return obj; }

  readValue() {
    // consume tags de versión (0xFF) y bytes de padding (0x00). V8 escribe un
    // kPadding (0x00) antes de un two-byte string para alinear el UTF-16.
    while (this.b[this.p] === 0xff || this.b[this.p] === 0x00) {
      if (this.b[this.p] === 0xff) { this.p++; this.version = this.varint(); }
      else this.p++;
    }
    const tag = this.u8();
    switch (tag) {
      case 0x5f: return undefined;              // '_' undefined
      case 0x2d: return undefined;              // '-' the hole -> undefined
      case 0x30: return null;                   // '0' null
      case 0x54: return true;                   // 'T' true
      case 0x46: return false;                  // 'F' false
      case 0x49: return this.zigzag();          // 'I' int32
      case 0x55: return this.varint();          // 'U' uint32
      case 0x4e: return this.double();          // 'N' double
      case 0x44: return new Date(this.double());// 'D' date
      case 0x22: return this.oneByteString();   // '"' latin1
      case 0x53: return this.utf8String();      // 'S' utf8
      case 0x63: return this.twoByteString();   // 'c' utf16le
      case 0x6f: return this.jsObject();        // 'o'
      case 0x41: return this.denseArray();      // 'A'
      case 0x61: return this.sparseArray();     // 'a'
      case 0x3b: return this.jsMap();           // ';'
      case 0x27: return this.jsSet();           // "'"
      case 0x5e: return this.ids[this.varint()];// '^' object reference
      case 0x6e: return this.double();          // 'n' NumberObject
      default:
        throw new Error('V8: tag desconocido 0x' + tag.toString(16) + ' @ ' + (this.p - 1));
    }
  }
  oneByteString() {
    const len = this.varint();
    const s = this.b.toString('latin1', this.p, this.p + len);
    this.p += len;
    return s;
  }
  utf8String() {
    const len = this.varint();
    const s = this.b.toString('utf8', this.p, this.p + len);
    this.p += len;
    return s;
  }
  twoByteString() {
    const len = this.varint();               // byteLength
    const s = this.b.toString('utf16le', this.p, this.p + len);
    this.p += len;
    return s;
  }
  jsObject() {
    const obj = this.register({});
    while (this.b[this.p] !== 0x7b) {          // '{' fin de objeto
      const key = this.readValue();
      const val = this.readValue();
      obj[key] = val;
    }
    this.p++;                                  // consume '{'
    this.varint();                             // numProperties
    return obj;
  }
  denseArray() {
    const len = this.varint();
    const arr = this.register(new Array(len));
    for (let i = 0; i < len; i++) arr[i] = this.readValue();
    while (this.b[this.p] !== 0x24) {          // '$' fin
      const key = this.readValue();
      const val = this.readValue();
      arr[key] = val;
    }
    this.p++;                                  // consume '$'
    this.varint();                             // numProperties
    this.varint();                             // length
    return arr;
  }
  sparseArray() {
    const maxLen = this.varint();
    const arr = this.register(new Array(maxLen));
    while (this.b[this.p] !== 0x40) {          // '@' fin
      const key = this.readValue();
      const val = this.readValue();
      arr[key] = val;
    }
    this.p++;                                  // consume '@'
    this.varint();                             // numProperties
    this.varint();                             // length
    return arr;
  }
  jsMap() {
    const m = this.register(new Map());
    while (this.b[this.p] !== 0x3a) {          // ':' fin
      const k = this.readValue();
      const v = this.readValue();
      m.set(k, v);
    }
    this.p++;
    this.varint();
    return m;
  }
  jsSet() {
    const s = this.register(new Set());
    while (this.b[this.p] !== 0x2c) {          // ',' fin
      s.add(this.readValue());
    }
    this.p++;
    this.varint();
    return s;
  }
}

// Deserializa la carga V8 dentro del buffer Blink descomprimido.
function parseV8(buf) {
  // El payload V8 real empieza en el ultimo `ff <ver>` seguido de un tag de
  // inicio de valor (tipicamente 'o'). Antes hay envoltorio Blink.
  let start = -1;
  for (let i = 0; i + 2 < buf.length; i++) {
    if (buf[i] === 0xff && buf[i + 1] < 0x20 && buf[i + 2] === 0x6f) { start = i; break; }
  }
  if (start < 0) throw new Error('no se encontro payload V8 (ff <ver> 6f)');
  const r = new V8Reader(buf);
  r.p = start;
  return r.readValue();
}

// ------------------------------------------------- cosecha de conversaciones
const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

function looksLikeConversation(o) {
  if (!o || typeof o !== 'object' || Array.isArray(o)) return false;
  if (typeof o.uuid !== 'string' || !UUID_RE.test(o.uuid)) return false;
  if (typeof o.name !== 'string') return false;                 // titulo
  // Debe oler a conversacion (tiene updated_at) y NO ser una organizacion/
  // cuenta (esas traen `id` y marcadores como rate_limit_tier/billing_type).
  if (!('updated_at' in o)) return false;
  if ('id' in o || 'rate_limit_tier' in o || 'billing_type' in o) return false;
  return true;
}

function collectConversations(root) {
  const found = new Map();          // uuid -> registro (dedup)
  const seen = new Set();           // objetos ya visitados (evita ciclos)
  const stack = [root];
  while (stack.length) {
    const node = stack.pop();
    if (!node || typeof node !== 'object') continue;
    if (seen.has(node)) continue;
    seen.add(node);
    if (node instanceof Date) continue;
    if (node instanceof Map) { for (const v of node.values()) stack.push(v); continue; }
    if (node instanceof Set) { for (const v of node) stack.push(v); continue; }
    if (looksLikeConversation(node) && !found.has(node.uuid)) {
      found.set(node.uuid, {
        uuid: node.uuid,
        title: node.name,
        summary: typeof node.summary === 'string' ? node.summary : null,
        model: typeof node.model === 'string' ? node.model : null,
        updated_at: normDate(node.updated_at),
        created_at: normDate(node.created_at),
      });
    }
    if (Array.isArray(node)) { for (const v of node) stack.push(v); }
    else { for (const k in node) stack.push(node[k]); }
  }
  const list = [...found.values()];
  list.sort((a, b) => (Date.parse(b.updated_at || b.created_at || 0) || 0) -
                      (Date.parse(a.updated_at || a.created_at || 0) || 0));
  return list;
}

function normDate(v) {
  if (v == null) return null;
  if (v instanceof Date) return v.toISOString();
  if (typeof v === 'number') return new Date(v).toISOString();
  if (typeof v === 'string') return v;         // ya es ISO
  return null;
}

// ------------------------------------------------------------------ IO / main
function resolveBlobBuffer(inputPath) {
  const HOME = os.homedir();
  let idbInput = inputPath || defaultIdbDir(HOME);

  const st = fs.existsSync(idbInput) ? fs.statSync(idbInput) : null;
  if (!st) throw new Error('ruta no existe: ' + idbInput);

  // Si es un archivo, se asume que es el blob directamente.
  if (st.isFile()) {
    return fs.readFileSync(idbInput);
  }

  // Es un directorio: snapshot a /tmp (la DB esta viva) y busca el blob.
  const snap = fs.mkdtempSync(path.join(os.tmpdir(), 'idb-snap-'));
  fs.cpSync(idbInput, snap, { recursive: true });   // cross-OS (sin depender de `cp`)

  // localiza el directorio blob dentro del snapshot
  const blobRoot = findBlobDir(snap);
  if (!blobRoot) throw new Error('no se hallo dir *.indexeddb.blob bajo ' + snap);

  // busca el archivo de blob que contiene el marcador de conversaciones
  const marker = Buffer.from('conversations_v2');
  const hit = grepBlob(blobRoot, marker);
  if (!hit) throw new Error('no se hallo blob con "conversations_v2" bajo ' + blobRoot);
  return fs.readFileSync(hit);
}

function findBlobDir(root) {
  const entries = fs.readdirSync(root, { withFileTypes: true });
  for (const e of entries) {
    if (e.isDirectory() && e.name.endsWith('.indexeddb.blob')) return path.join(root, e.name);
  }
  // por si el input ya era .../IndexedDB con subdirs
  for (const e of entries) {
    if (e.isDirectory()) {
      const sub = findBlobDir(path.join(root, e.name));
      if (sub) return sub;
    }
  }
  return null;
}

function grepBlob(dir, marker) {
  const stack = [dir];
  const hits = [];
  while (stack.length) {
    const d = stack.pop();
    for (const e of fs.readdirSync(d, { withFileTypes: true })) {
      const full = path.join(d, e.name);
      if (e.isDirectory()) stack.push(full);
      else {
        try {
          const buf = fs.readFileSync(full);
          // El blob esta comprimido; el marcador no aparece en claro salvo en
          // el propio header. Se prueba descomprimiendo con Snappy.
          if (snappyFromBlob(buf, marker)) hits.push({ full, size: buf.length });
        } catch (_) {}
      }
    }
  }
  if (!hits.length) return null;
  // el mas grande suele ser el cache completo de conversaciones
  hits.sort((a, b) => b.size - a.size);
  return hits[0].full;
}

function main() {
  const input = process.argv[2];
  const blob = resolveBlobBuffer(input);
  const marker = Buffer.from('conversations_v2');
  const decomp = snappyFromBlob(blob, marker) || (() => {
    // por si el blob no estuviera comprimido
    if (blob.includes(marker)) return blob;
    throw new Error('el blob no contiene "conversations_v2" (ni crudo ni Snappy)');
  })();
  const graph = parseV8(decomp);
  const chats = collectConversations(graph);
  process.stdout.write(JSON.stringify(chats, null, 2) + '\n');
}

main();
