---
name: diagramar
description: Producir un diagrama/flowchart eligiendo el flujo correcto según su DESTINO. Para EDITAR/acomodar a mano — modelar en .dot (Graphviz) y convertir con bin/dot2yed.py a .graphml editable en yEd, preservando layout y estilo. Para VERSE en GitHub/docs — Mermaid dentro de un .md VERSIONADO (GitHub lo renderiza nativo). Regla dura incluida: un diagrama entregable NUNCA queda solo como artefacto local gitignorado ni widget efímero del chat. Úsala al dibujar mapas de flujos, arquitecturas, jerarquías o cualquier diagrama del proyecto.
---

# Diagramar — el flujo correcto según el DESTINO del diagrama

Hay DOS destinos posibles para un diagrama, y cada uno tiene SU flujo. Elegir mal cuesta: un
`.graphml` no se ve en GitHub, y un Mermaid no se acomoda a mano en yEd. **Pregúntate primero:
¿este diagrama es para que un humano lo REACOMODE, o para que se VEA en el repo?**

## Flujo 1 — diagrama para EDITAR / acomodar a mano (yEd)

Para mapas densos donde el layout automático no basta y un humano va a rearreglar nodos a gusto
(p. ej. el mapa maestro de flujos del cerebro):

1. **Modela en `.dot` (Graphviz).** El `.dot` es la FUENTE: texto plano, diffeable, versionable.
   Usa `subgraph cluster_*` para agrupar (se vuelven grupos de yEd), `fillcolor`/`color`/
   `fontcolor` para el estilo y `\l` para líneas alineadas a la izquierda.
2. **Convierte con dot2yed:**
   ```sh
   python3 ~/.cortex/bin/dot2yed.py entrada.dot salida.graphml
   ```
   (En un clon del repo: `python3 bin/dot2yed.py …`.) Aprovecha que `dot -Tjson` YA calculó
   posiciones, tamaños y estilos → el `.graphml` abre en yEd **ya acomodado** con el layout de
   Graphviz, con ShapeNode por nodo, grupo yEd por cada `cluster_*` y PolyLineEdge por arista.
3. **Afina en yEd** (mover grupos, enderezar aristas, jerarquía visual) y exporta la vista que
   necesites (SVG/PNG).

**Requiere:** graphviz (`dot` en el PATH) — sin él, dot2yed muere con mensaje claro.
**Qué se versiona:** el `.dot` (fuente) sí, si es doc de record; el `.graphml` y el `.png` son
artefactos **regenerables** (no se versionan — ver el `.gitignore` del repo como ejemplo).

## Flujo 2 — diagrama para VERSE en GitHub / docs (Mermaid)

Para diagramas que el equipo debe poder VER navegando el repo (README, `docs/*.md`):

1. **Escribe Mermaid dentro de un `.md` VERSIONADO** (bloque ` ```mermaid `). GitHub (y GitLab)
   lo renderizan nativo: cero toolchain, el diff del diagrama es texto legible en el MR.
2. Mantenlo **legible**: dirección `TB` o `LR` según densidad; `subgraph` por capa; varios
   diagramas chicos antes que uno sobrecargado; leyenda de colores si usas `style`.
3. Ejemplo de record en este repo: [`docs/mapa-cerebro.md`](../../../docs/mapa-cerebro.md) (el
   mapa del cerebro por capas).

**Gotchas de Mermaid en GitHub:** etiquetas con paréntesis/acentos van entre comillas
(`NODO["texto (con paréntesis)"]`); saltos de línea con `<br/>`; `**negrita**` NO renderiza
dentro de etiquetas normales (usa `<b>…</b>`); `<` y `>` literales como `&lt;`/`&gt;`.

## Flujo 3 — Mermaid FEO → Graphviz HERMOSO (mmd2dot)

**Cuándo:** tienes un `erDiagram` de Mermaid que se ve MAL — típicamente por **relaciones
reflexivas** (una entidad consigo misma, p. ej. `AC ||--o{ AC : "IDPADRE"`), que Mermaid dibuja
como **loops enormes que cruzan todo el diagrama** porque no controla el layout de los self-loops.
Graphviz sí los dibuja compactos, pegados a la tabla. Úsalo también cuando quieras **editar el ER a
mano** (Graphviz/yEd) o un render de más calidad para un PDF/entregable. Ninguna relación se omite
para que se vea bien — **todas** (reflexivas incluidas) quedan en el DOT.

```sh
# Mermaid (.mmd) o el 1er bloque ```mermaid de un .md  →  DOT (+ PNG opcional)
python3 ~/.cortex/bin/mmd2dot.py -i esquema.md -o esquema.dot --png esquema.png
# rankdir: LR (default, tablas ER se leen a lo ancho) o TB
python3 ~/.cortex/bin/mmd2dot.py -i esquema.mmd -o esquema.dot --rankdir TB
```
(En un clon del repo: `python3 bin/mmd2dot.py …`.) Vive junto a `dot2yed.py` en `bin/` del repo.

Emite nodos-tabla HTML-like (header con el nombre + una fila por columna: tipo, nombre, **PK** en
negrita, comentario en itálica), estilo lavanda tipo Mermaid default (header `#DDD6FE`, cuerpo
`#EDE9FE`, bordes/edges morados `#6c5ce7`, Helvetica) y **self-loops LIMPIOS**. Crow's-foot no es
nativo en Graphviz → se **aproxima** con arrowheads: `||`→`tee`, `|o`/`o|`→`teeodot`,
`}o`/`o{`→`crowodot`, `}|`/`|{`→`crowtee`. **Soporta HOY solo `erDiagram`** (no flowchart /
classDiagram / stateDiagram / sequenceDiagram).

**Encadena con dot2yed:** `mmd2dot.py` (Mermaid→DOT) → si además quieres reacomodar a mano,
`dot2yed.py` (DOT→yEd) sobre el `.dot` que salió. Es el puente que conecta el Flujo 2 (lo que ya
está en Mermaid) con el Flujo 1 (editar en yEd) sin volver a dibujar nada.

## Cuándo usar cuál

| Necesidad | Flujo |
|---|---|
| Un humano va a REARREGLAR el layout a mano | 1 — `.dot` → dot2yed → yEd |
| Verse al navegar el repo (README/docs/MR) | 2 — Mermaid en `.md` versionado |
| Un `erDiagram` de Mermaid se ve feo (self-loops/relaciones cruzadas) y lo quiero HERMOSO | 3 — `mmd2dot.py` (Mermaid→DOT→PNG); encadena a Flujo 1 si además vas a editarlo |
| Ambas (mapa denso Y visible) | Ambos: `.dot` como fuente editable + un espejo Mermaid en docs — y los DOS se actualizan en la misma tanda |

## Reglas duras (no negociables)

- **Un diagrama entregable NUNCA queda solo como artefacto local gitignorado ni como widget
  efímero del chat.** Un mockup/diagrama que solo vive en el preview del chat no sobrevive ni al
  scroll (caso real, jul 2026: un mockup aprobado se borró de AMBOS lados y costó días
  re-sincronizarse). Si se mostró, **se guarda a archivo versionado en el MISMO turno** (norma
  "mockups a archivo versionado"). Los flowcharts del cerebro vivieron meses gitignorados → en
  GitHub no se veía NADA; `docs/mapa-cerebro.md` es el antídoto.
- **Doc = realidad:** el diagrama describe algo — cuando ESO cambie (un hook, un flujo, una
  ruta), el diagrama se actualiza **en la MISMA tanda** que el cambio, no "después". Un diagrama
  que miente es peor que no tener diagrama. Si el diagrama tiene fuente Y espejo (`.dot` +
  Mermaid), la tanda incluye a AMBOS.
- **Entregable = auto-contenido (leyenda + normas).** Un flowchart entregable lleva SIEMPRE su
  **LEYENDA** (qué significa cada forma/color/flecha) y, cuando aplique, las **NORMAS** que rigen el
  flujo. Es lo que lo hace legible **por sí solo**: quien lo abre entiende la notación y las reglas
  del juego sin tener que preguntar ni reconstruir el contexto. Un diagrama pelón no es entregable.
- **QA visual de un diagrama que generaste tú:** ábrelo, no dejes solo la ruta. **OJO con SVG en
  macOS:** `open archivo.svg` suele caer en **Preview, que NO renderiza SVG** (sale en blanco) →
  ábrelo en un **navegador** (`open -a "Google Chrome" archivo.svg`, o Safari). PNG/PDF sí van bien
  con `open`/Preview; en Linux, `xdg-open` respeta el navegador por defecto.
