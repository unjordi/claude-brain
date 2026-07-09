#!/usr/bin/env node
/*
 * sessions-extract.js — lista las sesiones de Claude Code por proyecto, para el dropdown
 * "resumir sesión" del tab Proyectos. Lee ~/.claude/projects/<slug>/*.jsonl (o CLAUDE_CONFIG_DIR).
 * SIN red. Salida (stdout): JSON array [{id, project, cwd, updated_at, label}] ordenado por
 * más reciente. Cada .jsonl es una sesión (nombre = sessionId); se resume con `claude --resume <id>`.
 */
const fs = require('fs');
const os = require('os');
const path = require('path');

const PER_PROJECT = 12;   // tope de sesiones recientes por proyecto (acota la I/O del daemon)

function projectsDir() {
  const cfg = process.env.CLAUDE_CONFIG_DIR;
  const base = (cfg && cfg.length) ? cfg : path.join(os.homedir(), '.claude');
  return path.join(base, 'projects');
}

// Lee el prefijo del transcript (basta con los primeros bytes) y saca el cwd + el primer mensaje
// de usuario (etiqueta). Las primeras líneas (mode/permission/file-history) traen cwd=null.
function meta(file) {
  let txt = '';
  try {
    const fd = fs.openSync(file, 'r');
    const buf = Buffer.alloc(65536);
    const n = fs.readSync(fd, buf, 0, buf.length, 0);
    fs.closeSync(fd);
    txt = buf.toString('utf8', 0, n);
  } catch (_) { return { cwd: null, label: null }; }

  let cwd = null, label = null;
  for (const line of txt.split('\n')) {
    if (!line.trim()) continue;
    let o; try { o = JSON.parse(line); } catch (_) { continue; }   // la última línea puede venir cortada
    if (!cwd && typeof o.cwd === 'string' && o.cwd) cwd = o.cwd;
    if (!label && o.type === 'user' && o.message) {
      const c = o.message.content;
      let t = null;
      if (typeof c === 'string') t = c;
      else if (Array.isArray(c)) {
        const x = c.find(e => e && e.type === 'text' && typeof e.text === 'string');
        t = x ? x.text : null;
      }
      if (t) { t = t.replace(/\s+/g, ' ').trim(); if (t) label = t.slice(0, 80); }
    }
    if (cwd && label) break;
  }
  return { cwd, label };
}

function main() {
  const dir = projectsDir();
  let slugs;
  try {
    slugs = fs.readdirSync(dir, { withFileTypes: true }).filter(e => e.isDirectory()).map(e => e.name);
  } catch (_) { process.stdout.write('[]\n'); return; }

  const out = [];
  for (const slug of slugs) {
    const sdir = path.join(dir, slug);
    let files;
    try {
      files = fs.readdirSync(sdir)
        .filter(f => f.endsWith('.jsonl'))
        .map(f => ({ f, m: fs.statSync(path.join(sdir, f)).mtimeMs }));
    } catch (_) { continue; }
    files.sort((a, b) => b.m - a.m);
    for (const { f, m } of files.slice(0, PER_PROJECT)) {
      const { cwd, label } = meta(path.join(sdir, f));
      const realCwd = cwd || slug.replace(/^-/, '/').replace(/-/g, '/');   // fallback lossy si no hubo cwd
      out.push({
        id: f.replace(/\.jsonl$/, ''),
        project: path.basename(realCwd) || slug,
        cwd: realCwd,
        updated_at: new Date(m).toISOString(),
        label: label || '(sesión)',
      });
    }
  }
  out.sort((a, b) => (Date.parse(b.updated_at) || 0) - (Date.parse(a.updated_at) || 0));
  process.stdout.write(JSON.stringify(out, null, 2) + '\n');
}
main();
