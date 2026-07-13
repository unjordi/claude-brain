#!/usr/bin/env python3
"""dot2yed.py — convierte un .dot de Graphviz a un .graphml editable en yEd, PRESERVANDO estilo.

Aprovecha que `dot -Tjson` ya calcula posiciones, tamaños y resuelve estilos; traduce eso a
yEd-graphml: ShapeNode por nodo (forma/relleno/borde/etiqueta/color de texto), grupos de yEd por
cada `cluster_*`, y PolyLineEdge por arista. El resultado abre en yEd YA ACOMODADO (con el layout de
Graphviz) y de ahí rearreglas a gusto (p. ej. el cimiento debajo de los flujos).

Uso:  python3 bin/dot2yed.py docs/mapa-flujos.dot docs/mapa-flujos.graphml
Requiere: graphviz (`dot`) en el PATH. Parte del skill de diagramas de la plantilla.
"""
import json, re, subprocess, sys, html

def die(m): sys.stderr.write(m + "\n"); sys.exit(1)

def run_dot_json(dot_path):
    try:
        out = subprocess.run(["dot", "-Tjson", dot_path], capture_output=True, text=True, check=True)
    except FileNotFoundError:
        die("No encuentro `dot` (graphviz) en el PATH.")
    except subprocess.CalledProcessError as e:
        die("dot falló:\n" + e.stderr)
    return json.loads(out.stdout)

def esc(s):  # escapa texto para contenido XML (los &#10; se insertan DESPUÉS de escapar)
    return html.escape(s, quote=True)

def label_to_xml(raw):
    """Convierte un label de dot (con \\l / \\n) a texto yEd con &#10; y detecta alineación."""
    if raw is None: raw = ""
    left = "\\l" in raw                       # \l = línea alineada a la izquierda
    lines = re.split(r"\\[ln]", raw)          # corta en \l o \n
    if lines and lines[-1] == "": lines = lines[:-1]   # quita el vacío tras un \l final
    text = "&#10;".join(esc(x) for x in lines)
    return text, ("left" if left else "center")

def yed_shape(shape, style):
    if shape == "diamond": return "diamond"
    if shape in ("box", "rect", "rectangle", "note", "square"):
        return "roundrectangle" if "rounded" in (style or "") else "rectangle"
    return "roundrectangle"

def dashed(style):
    return "dashed" if "dashed" in (style or "") else "line"

def node_shapenode(o, H):
    cx, cy = map(float, o["pos"].split(","))
    w = float(o.get("width", 1)) * 72.0
    h = float(o.get("height", 0.5)) * 72.0
    x = cx - w / 2.0
    y = H - cy - h / 2.0                       # Graphviz Y-arriba → yEd Y-abajo
    fill = o.get("fillcolor", "#FFFFFF")
    border = o.get("color", "#000000")
    pw = o.get("penwidth", "1")
    fontcolor = o.get("fontcolor", "#000000")
    text, align = label_to_xml(o.get("label", ""))
    shape = yed_shape(o.get("shape", "box"), o.get("style", ""))
    fontname = o.get("fontname", "Dialog")
    fontsize = str(o.get("fontsize", "12")).split(".")[0]
    return (
        f'<node id="{esc(o["name"])}"><data key="d0"><y:ShapeNode>'
        f'<y:Geometry height="{h:.2f}" width="{w:.2f}" x="{x:.2f}" y="{y:.2f}"/>'
        f'<y:Fill color="{fill}" transparent="false"/>'
        f'<y:BorderStyle color="{border}" type="{dashed(o.get("style",""))}" width="{pw}"/>'
        f'<y:NodeLabel alignment="{align}" autoSizePolicy="content" textColor="{fontcolor}" '
        f'fontFamily="{esc(fontname)}" fontSize="{fontsize}" '
        f'modelName="internal" modelPosition="c" xml:space="preserve">{text}</y:NodeLabel>'
        f'<y:Shape type="{shape}"/>'
        f'</y:ShapeNode></data></node>'
    )

def group_open(o, H):
    x0, y0, x1, y1 = map(float, o["bb"].split(","))
    gx, gw = x0, x1 - x0
    gy, gh = H - y1, y1 - y0
    border = o.get("color", "#8A8A8A")
    text, _ = label_to_xml(o.get("label", ""))
    gid = esc(o["name"])
    gn = (
        f'<y:GroupNode>'
        f'<y:Geometry height="{gh:.2f}" width="{gw:.2f}" x="{gx:.2f}" y="{gy:.2f}"/>'
        f'<y:Fill hasColor="false" transparent="true"/>'
        f'<y:BorderStyle color="{border}" type="line" width="1.6"/>'
        f'<y:NodeLabel alignment="left" autoSizePolicy="node_width" textColor="{border}" '
        f'backgroundColor="#1B1712" modelName="internal" modelPosition="t" '
        f'xml:space="preserve"> {text}</y:NodeLabel>'
        f'<y:Shape type="roundrectangle"/>'
        f'<y:State closed="false" closedHeight="80" closedWidth="120" innerGraphDisplayEnabled="false"/>'
        f'<y:Insets bottom="16" left="16" right="16" top="24"/>'
        f'<y:BorderInsets bottom="0" left="0" right="0" top="0"/>'
        f'</y:GroupNode>'
    )
    return (
        f'<node id="{gid}" yfiles.foldertype="group"><data key="d0">'
        f'<y:ProxyAutoBoundsNode><y:Realizers active="0">{gn}{gn}</y:Realizers></y:ProxyAutoBoundsNode>'
        f'</data><graph edgedefault="directed" id="{gid}:">'
    )

def edge_xml(e, idx, name_of):
    src = name_of.get(e["tail"]); tgt = name_of.get(e["head"])
    if src is None or tgt is None: return ""
    color = e.get("color", "#B0A89F")
    style = dashed(e.get("style", ""))
    text, _ = label_to_xml(e.get("label", ""))
    fontcolor = e.get("fontcolor", "#8A8078")
    lbl = (f'<y:EdgeLabel textColor="{fontcolor}" xml:space="preserve">{text}</y:EdgeLabel>'
           if text else "")
    return (
        f'<edge id="e{idx}" source="{esc(src)}" target="{esc(tgt)}"><data key="d1"><y:PolyLineEdge>'
        f'<y:LineStyle color="{color}" type="{style}" width="1.3"/>'
        f'<y:Arrows source="none" target="standard"/>{lbl}'
        f'</y:PolyLineEdge></data></edge>'
    )

def main():
    if len(sys.argv) != 3:
        die("Uso: python3 bin/dot2yed.py <entrada.dot> <salida.graphml>")
    dot_path, out_path = sys.argv[1], sys.argv[2]
    d = run_dot_json(dot_path)
    H = float(d["bb"].split(",")[3])
    objs = d.get("objects", [])
    name_of = {o["_gvid"]: o["name"] for o in objs if "name" in o}

    clusters = [o for o in objs if str(o.get("name", "")).startswith("cluster")]
    child_gvids = set()
    for c in clusters: child_gvids.update(c.get("nodes", []))

    parts = ['<?xml version="1.0" encoding="UTF-8"?>',
             '<graphml xmlns="http://graphml.graphdrawing.org/xmlns" '
             'xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance" '
             'xmlns:y="http://www.yworks.com/xml/graphml" xmlns:yed="http://www.yworks.com/xml/yed/3" '
             'xsi:schemaLocation="http://graphml.graphdrawing.org/xmlns '
             'http://www.yworks.com/xml/schema/graphml/1.1/ygraphml.xsd">',
             '<key for="node" id="d0" yfiles.type="nodegraphics"/>',
             '<key for="edge" id="d1" yfiles.type="edgegraphics"/>',
             '<graph edgedefault="directed" id="G">']

    n_nodes = n_groups = 0
    # nodos SUELTOS (no dentro de un cluster) primero
    for o in objs:
        if str(o.get("name", "")).startswith("cluster"): continue
        if "pos" not in o: continue
        if o["_gvid"] in child_gvids: continue
        parts.append(node_shapenode(o, H)); n_nodes += 1
    # cada cluster como GRUPO con sus hijos
    by_gvid = {o["_gvid"]: o for o in objs}
    for c in clusters:
        parts.append(group_open(c, H)); n_groups += 1
        for gv in c.get("nodes", []):
            o = by_gvid.get(gv)
            if o and "pos" in o:
                parts.append(node_shapenode(o, H)); n_nodes += 1
        parts.append('</graph></node>')

    for i, e in enumerate(d.get("edges", [])):
        x = edge_xml(e, i, name_of)
        if x: parts.append(x)

    parts.append('</graph></graphml>')
    open(out_path, "w", encoding="utf-8").write("\n".join(parts) + "\n")
    sys.stderr.write(f"OK → {out_path}  ({n_nodes} nodos, {n_groups} grupos, {len(d.get('edges',[]))} aristas)\n")

if __name__ == "__main__":
    main()
