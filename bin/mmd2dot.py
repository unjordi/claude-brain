#!/usr/bin/env python3
"""mmd2dot.py — convierte un `erDiagram` de Mermaid a Graphviz DOT que se renderiza BONITO.

El motivo: Mermaid `erDiagram` no controla el layout de los self-loops (una entidad relacionada
consigo misma, p. ej. `AC ||--o{ AC : "IDPADRE"`) → los dibuja como loops enormes que cruzan todo
el diagrama. Graphviz sí los dibuja compactos, pegados a la tabla. Este puente lee el Mermaid y
emite un `.dot` con nodos-tabla HTML-like (estilo lavanda tipo Mermaid default), crow's-foot
APROXIMADO con arrowheads de Graphviz y self-loops limpios. Ninguna relación se omite.

Encadena natural con `dot2yed.py`: mmd2dot (Mermaid→DOT) → dot2yed (DOT→yEd) si quieres editar a mano.

Uso:
    python3 bin/mmd2dot.py -i entrada.mmd  -o salida.dot
    python3 bin/mmd2dot.py -i doc.md       -o salida.dot   # extrae el 1er bloque ```mermaid
    python3 bin/mmd2dot.py -i doc.md       -o salida.dot --png salida.png [--dpi 150]
    python3 bin/mmd2dot.py -i doc.md       -o salida.dot --rankdir TB

Requiere: solo stdlib de Python 3. Para --png: graphviz (`dot`) en el PATH.
Soporta HOY: `erDiagram` (entidades con bloque de atributos + relaciones, self-refs incluidas).
NO soporta aún: flowchart / graph / classDiagram / stateDiagram / sequenceDiagram (ver el .md del skill).
"""
import argparse, html, re, subprocess, sys

# ── Estilo lavanda (Mermaid default) ────────────────────────────────────────
HEADER_BG = "#DDD6FE"   # morado claro para el header de cada tabla
BODY_BG   = "#EDE9FE"   # lavanda muy claro para las filas
LINE      = "#6c5ce7"   # morado para bordes/edges/texto de relación
FONT      = "Helvetica"

# ── Mapa de cardinalidad Mermaid → arrowhead de Graphviz ────────────────────
# Crow's-foot NO es nativo en Graphviz; se APROXIMA concatenando primitivas:
#   crow = pata de gallo (muchos) · tee = barra (uno) · odot = círculo hueco (cero/opcional).
# El símbolo de "forma" (crow/tee) va PEGADO a la entidad; el círculo de opcionalidad, por fuera.
#   ||  exactamente uno   → tee
#   |o / o|  cero o uno   → tee + odot   (barra + círculo)
#   }o / o{  cero o muchos→ crow + odot  (pata + círculo)
#   }| / |{  uno o muchos → crow + tee   (pata + barra)
_CAT_ARROW = {
    "one":       "tee",
    "zero_one":  "teeodot",
    "zero_many": "crowodot",
    "one_many":  "crowtee",
}
# Tokens de cardinalidad Mermaid (los del lado izquierdo y derecho son espejo) → categoría.
_CARD_CAT = {
    "||": "one",
    "|o": "zero_one", "o|": "zero_one",
    "}o": "zero_many", "o{": "zero_many",
    "}|": "one_many",  "|{": "one_many",
}


def die(m):
    sys.stderr.write("mmd2dot: " + m + "\n")
    sys.exit(1)


def read_mermaid(path):
    """Lee el .mmd entero, o extrae el 1er bloque ```mermaid de un .md."""
    try:
        raw = open(path, encoding="utf-8").read()
    except FileNotFoundError:
        die(f"no encuentro el archivo de entrada: {path}")
    m = re.search(r"```+\s*mermaid\s*\n(.*?)```+", raw, re.DOTALL | re.IGNORECASE)
    if m:
        return m.group(1)
    if path.lower().endswith(".md"):
        die("no encontré ningún bloque ```mermaid en el .md")
    return raw  # .mmd (u otro): el archivo ES el mermaid


def parse_er(src):
    """Parsea un `erDiagram`. Devuelve (entities, relations).
    entities: dict nombre -> lista de dicts {type,name,key,comment}
    relations: lista de dicts {left,right,lcat,rcat,label,dashed}
    """
    if "erDiagram" not in src:
        die("la entrada no contiene un `erDiagram` (por ahora solo soporto erDiagram).")
    # nos quedamos con lo que sigue a la palabra erDiagram
    src = src[src.index("erDiagram") + len("erDiagram"):]

    entities, relations = {}, []
    lines = src.splitlines()
    i, n = 0, len(lines)

    rel_re = re.compile(
        r'^\s*([A-Za-z_]\w*)\s+'          # entidad izquierda
        r'([|}o{][|o{}])(--|\.\.)([|o{}][|o{}])'  # lcard sep rcard
        r'\s+([A-Za-z_]\w*)\s*'           # entidad derecha
        r'(?::\s*(.*))?\s*$'              # : label (opcional)
    )
    # atributo dentro de un bloque:  TYPE NAME [PK|FK|UK ...] ["comentario"]
    attr_re = re.compile(
        r'^\s*([\w<>\[\]().,-]+)\s+([\w]+)'   # tipo  nombre
        r'((?:\s+(?:PK|FK|UK))*)'              # keys
        r'(?:\s+"([^"]*)")?\s*$'               # comentario opcional
    )

    while i < n:
        line = lines[i].strip()
        i += 1
        if not line or line.startswith("%%"):
            continue
        # ¿abre bloque de entidad?  NOMBRE {
        mblock = re.match(r'^([A-Za-z_]\w*)\s*\{\s*$', line)
        if mblock:
            ent = mblock.group(1)
            attrs = entities.setdefault(ent, [])
            while i < n and lines[i].strip() != "}":
                a = attr_re.match(lines[i].strip())
                if a:
                    keys = a.group(3).split()
                    attrs.append({
                        "type": a.group(1),
                        "name": a.group(2),
                        "key": "PK" if "PK" in keys else ("FK" if "FK" in keys else ""),
                        "comment": a.group(4) or "",
                    })
                i += 1
            i += 1  # consume el '}'
            continue
        # ¿relación?
        mr = rel_re.match(line)
        if mr:
            left, lcard, sep, rcard, right, label = mr.groups()
            entities.setdefault(left, entities.get(left, []))
            entities.setdefault(right, entities.get(right, []))
            label = (label or "").strip().strip('"')
            relations.append({
                "left": left, "right": right,
                "lcat": _CARD_CAT.get(lcard, "one"),
                "rcat": _CARD_CAT.get(rcard, "one"),
                "label": label, "dashed": (sep == ".."),
            })
            continue
        # línea suelta que solo nombra una entidad
        msolo = re.match(r'^([A-Za-z_]\w*)\s*$', line)
        if msolo:
            entities.setdefault(msolo.group(1), entities.get(msolo.group(1), []))

    if not entities and not relations:
        die("no encontré entidades ni relaciones en el erDiagram.")
    return entities, relations


def esc(s):
    return html.escape(str(s), quote=True)


def node_label(ent, attrs):
    """Nodo tabla HTML-like: header con el nombre + una fila por columna (tipo, nombre, key, comentario)."""
    rows = [
        f'<TR><TD COLSPAN="4" BGCOLOR="{HEADER_BG}" ALIGN="CENTER">'
        f'<B>{esc(ent)}</B></TD></TR>'
    ]
    for a in attrs:
        key = f'<B>{esc(a["key"])}</B>' if a["key"] else ""
        name = f'<B>{esc(a["name"])}</B>' if a["key"] == "PK" else esc(a["name"])
        comment = (f'<FONT COLOR="#7c6fb0"><I>{esc(a["comment"])}</I></FONT>'
                   if a["comment"] else "")
        rows.append(
            f'<TR>'
            f'<TD BGCOLOR="{BODY_BG}" ALIGN="LEFT"><FONT COLOR="#6b6b8a">{esc(a["type"])}</FONT></TD>'
            f'<TD BGCOLOR="{BODY_BG}" ALIGN="LEFT">{name}</TD>'
            f'<TD BGCOLOR="{BODY_BG}" ALIGN="LEFT">{key}</TD>'
            f'<TD BGCOLOR="{BODY_BG}" ALIGN="LEFT">{comment}</TD>'
            f'</TR>'
        )
    table = (
        '<<TABLE BORDER="0" CELLBORDER="1" CELLSPACING="0" CELLPADDING="5">'
        + "".join(rows) +
        '</TABLE>>'
    )
    return table


def build_dot(entities, relations, rankdir):
    out = []
    out.append("digraph ER {")
    out.append(f'  rankdir={rankdir};')
    out.append('  graph [bgcolor="white", splines=true, nodesep=0.55, ranksep=0.9, pad=0.3];')
    out.append(f'  node  [shape=plain, fontname="{FONT}", fontsize=11];')
    out.append(f'  edge  [color="{LINE}", fontname="{FONT}", fontsize=10, '
               f'fontcolor="{LINE}", penwidth=1.3, dir=both];')
    out.append("")
    # nodos
    for ent in entities:
        out.append(f'  "{ent}" [label={node_label(ent, entities[ent])}];')
    out.append("")
    # aristas
    for r in relations:
        tail = _CAT_ARROW[r["lcat"]]     # cardinalidad izquierda → arrowtail (pegada al nodo izq)
        head = _CAT_ARROW[r["rcat"]]     # cardinalidad derecha  → arrowhead (pegada al nodo der)
        attrs = [f'arrowtail={tail}', f'arrowhead={head}']
        if r["label"]:
            attrs.append(f'label="{r["label"]}"')
        if r["dashed"]:
            attrs.append('style=dashed')
        if r["left"] == r["right"]:
            # self-loop LIMPIO: puerto fijo + peso alto para que Graphviz lo mantenga pegado y chico
            attrs.append('constraint=false')
        out.append(f'  "{r["left"]}" -> "{r["right"]}" [{", ".join(attrs)}];')
    out.append("}")
    return "\n".join(out) + "\n"


def render_png(dot_path, png_path, dpi):
    try:
        subprocess.run(["dot", f"-Gdpi={dpi}", "-Tpng", dot_path, "-o", png_path],
                       check=True, capture_output=True, text=True)
    except FileNotFoundError:
        die("no encuentro `dot` (graphviz) en el PATH — instala graphviz para usar --png.")
    except subprocess.CalledProcessError as e:
        die("dot falló al renderizar el PNG:\n" + e.stderr)


def main():
    ap = argparse.ArgumentParser(
        description="Convierte un erDiagram de Mermaid a Graphviz DOT (self-loops limpios).")
    ap.add_argument("-i", "--input", required=True, help="entrada .mmd o .md (extrae el 1er ```mermaid)")
    ap.add_argument("-o", "--output", required=True, help="salida .dot")
    ap.add_argument("--png", help="además, renderiza a este PNG con `dot`")
    ap.add_argument("--dpi", type=int, default=150, help="DPI del PNG (default 150)")
    ap.add_argument("--rankdir", default="LR", choices=["LR", "TB", "RL", "BT"],
                    help="dirección del layout (default LR: las tablas ER se leen mejor a lo ancho)")
    args = ap.parse_args()

    src = read_mermaid(args.input)
    entities, relations = parse_er(src)
    dot = build_dot(entities, relations, args.rankdir)
    open(args.output, "w", encoding="utf-8").write(dot)
    sys.stderr.write(
        f"OK → {args.output}  ({len(entities)} entidades, {len(relations)} relaciones, "
        f"{sum(1 for r in relations if r['left'] == r['right'])} self-loops)\n")
    if args.png:
        render_png(args.output, args.png, args.dpi)
        sys.stderr.write(f"OK → {args.png}  (dot -Tpng -Gdpi={args.dpi})\n")


if __name__ == "__main__":
    main()
