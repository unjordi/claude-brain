#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Oraculo de QA del andamio mecanico.

Mide contra el transcript REAL y CONGELADO de la sesion del 2026-09-11 (40 082 lineas, 193 MB,
14 compactaciones) — no contra un fixture. Se congelo a proposito: el vivo crece mientras se mide y
las aserciones no pueden apuntar a un blanco movil.

VERDAD ESTABLECIDA del tramo vivo (ultima frontera de compactacion en la linea 39278), verificada a mano:
  · 5 commits, LOS CINCO hechos con la bandera de archivo `-F -` y heredoc (la forma que obliga la norma
    de mensajes en prosa curada, porque son multilinea). El extractor hoy ve UNO y lo renderiza como "…".
  · 7 invocaciones de integracion por squash desde el foro (4 PRs distintos: 405, 389, 407, 406), que hoy
    no cuentan como trabajo resuelto aunque SON la forma en que este flujo integra.
  · mensajes del usuario mezclados con plomeria del harness.
  · una escritura capturada con la variable RHREC3 sin expandir.

Uso: qa-andamio.py <ruta al checkpoint-mecanico.js>   → PASS/FAIL por hallazgo; exit 1 si algo falla.
"""
import json, subprocess, sys, os, re

AQUI = os.path.dirname(os.path.abspath(__file__))  # el fixture vive junto a este archivo
TRANSCRIPT = os.path.join(AQUI, 'transcript-hoy.jsonl')
JS = sys.argv[1] if len(sys.argv) > 1 else '/Users/unjordi/code/cortex/bin/checkpoint-mecanico.js'
if not os.path.exists(TRANSCRIPT):
    print('falta el transcript congelado:', TRANSCRIPT); sys.exit(2)

r = subprocess.run(['node', JS, TRANSCRIPT, '--json'], capture_output=True, text=True)
if r.returncode != 0:
    print('el extractor fallo:', (r.stderr or r.stdout)[:400]); sys.exit(1)
d = json.loads(r.stdout)

res = []
def chk(id_, desc, ok, detalle):
    res.append((bool(ok), id_, desc, detalle))

def texto(x, *claves):
    if isinstance(x, str):
        try: x = json.loads(x)
        except Exception: return x
    if isinstance(x, dict):
        for k in claves:
            if x.get(k): return str(x[k])
        return json.dumps(x, ensure_ascii=False)
    return str(x)

commits = [texto(c, 'msg', 'texto', 'mensaje', 'subject') for c in d.get('commits', [])]
blob = ' || '.join(commits)
ESPERADOS = ['docs(potencia): inventario de red auditado',
             'test(rehidratar-hilo): el aviso de perdida calla',
             'docs(guards): dos disparos en falso del merge-squash-guard']
def presente(e):
    return any(e.lower().replace('perdida','p') in (c.lower().replace('pérdida','p').replace('perdida','p')) for c in commits)
faltan = [e for e in ESPERADOS if not presente(e)]
elididos = [c for c in commits if c.strip() in ('…', '...', '')]
chk('A-1', 've los 5 commits hechos con `-F -` y heredoc, con su asunto real',
    not faltan and not elididos,
    '%d detectados; faltan %d de los 3 verificados a mano%s' % (
        len(commits), len(faltan), ('; %d renderizados como "…"' % len(elididos)) if elididos else ''))

MERGES = ['fix(gitignore): el andamio', 'feat(continuidad)', 'feat(residuo)']
hay = sum(1 for m in MERGES if m in blob)
chk('A-1b', 'cuenta las integraciones por squash del foro como trabajo resuelto',
    hay >= 2, '%d de 3 asuntos de integracion presentes' % hay)

msgs = [texto(m, 'texto', 'text', 'content') for m in d.get('mensajesUsuarioTexto', [])]
RUIDO = re.compile(r'<local-command-|<task-notification|<command-name>|<system-reminder|'
                   r'^\s*##\s*Context Usage|^\s*/compact\s*$|\x1b\[')
sucios = [m for m in msgs if RUIDO.search(m or '')]
REALES = ['haz los merges en ese orden', 'rrelo sobre tu transcript']
sobreviven = [x for x in REALES if any(x in m for m in msgs)]
chk('A-2', 'las citas excluyen la plomeria del harness y conservan las reales',
    not sucios and len(sobreviven) == len(REALES),
    '%d citas · %d con plomeria%s · reales presentes: %d de %d' % (
        len(msgs), len(sucios),
        (' → %s' % [m[:34] for m in sucios[:3]]) if sucios else '', len(sobreviven), len(REALES)))

env = dict(os.environ)
env['CLAUDE_CODE_CHILD_SESSION'] = '1'
env['CLAUDE_CODE_SESSION_ID'] = '38014d8e-75b3-43fe-bf33-1cd18107dc21'
rs = subprocess.run(['node', JS, '--self', '--json'], capture_output=True, text=True, env=env)
chk('A-3', '--self no rechaza al hilo principal por CHILD_SESSION=1',
    'SUBAGENTE' not in (rs.stderr + rs.stdout),
    ((rs.stderr or rs.stdout).strip().split('\n')[0][:86]) or 'corrio')

top = [texto(c, 'item') for c in d.get('topComandos', [])]
NAV = re.compile(r'^\s*(cd|ls|pwd|cat|head|tail|wc|echo|which|find|grep)\b')
nav = [t for t in top if NAV.match(t)]
chk('A-4', 'el top de comandos no lo domina la navegacion',
    bool(top) and len(nav) <= len(top) // 3,
    '%d de %d son navegacion%s' % (len(nav), len(top), (' → %s' % [t[:26] for t in nav[:4]]) if nav else ''))

esc = [texto(e, 'item') for e in d.get('topBashEscrituras', [])]
tmp = [e for e in esc if e.startswith('/tmp') or e.startswith('/private/tmp')]
chk('A-5', 'las escrituras temporales no desplazan al trabajo del repo',
    bool(esc) and len(tmp) <= len(esc) // 2,
    '%d de %d son temporales' % (len(tmp), len(esc)))

convar = [e for e in esc if '$' in e]
chk('A-6', 'no guarda rutas con variables sin expandir',
    not convar, (', '.join(e[:52] for e in convar)) if convar else 'ninguna')

# ── B-1 · basura en la lista de escrituras: destinos que no son archivos, o con puntuacion
#         de la sintaxis pegada (que ademas DUPLICAN la entrada limpia del mismo archivo)
import os.path as _op
basura = [e for e in esc
          if e.rstrip().endswith(('",', "',", '"', "'", ',', ';', ')'))
          or e in ('/to-do',)
          or _op.basename(e).startswith('/')]
dup = [e for e in esc if any(o != e and e.startswith(o) for o in esc)]
chk('B-1', 'la lista de escrituras no trae destinos basura ni duplicados por puntuacion',
    not basura and not dup,
    ('basura: %s' % [b[:44] for b in basura] if basura else 'sin basura') +
    (' · duplicados: %s' % [d[:44] for d in dup] if dup else ''))

# ── B-2 · el "top" debe estar ORDENADO por frecuencia: si se despriorizan grupos, el render
#         miente al lector, que lee una lista aparentemente ordenada donde un 37x va bajo un 1x
ns = [c.get('n') for c in d.get('topComandos', []) if isinstance(c, dict) and 'n' in c]
mono = all(ns[i] >= ns[i+1] for i in range(len(ns)-1)) if ns else False
chk('B-2', 'el top de comandos se renderiza ordenado por frecuencia',
    mono,
    'frecuencias en orden de render: %s%s' % (
        ns, '' if mono else ' → el de %dx cae en la posicion %d' % (max(ns), ns.index(max(ns))+1)))

print('\n=== QA DEL ANDAMIO · contra el transcript real del 2026-09-11 ===')
fails = 0
for ok, id_, desc, det in res:
    print('  %s %-4s · %s\n            %s' % ('PASS' if ok else 'FAIL', id_, desc, det))
    fails += 0 if ok else 1
print('\n==> %d PASS · %d FAIL' % (len(res) - fails, fails))
sys.exit(1 if fails else 0)
