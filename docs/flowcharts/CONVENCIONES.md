# Convenciones de los flowcharts del cerebro — FUENTE ÚNICA de notación

> Nace del pase COLECTIVO de la auditoría 2026-07-29 + correcciones de unjordi (2026-07-29 noche): el set
> no cerraba como sistema (🔴 rojo con sentidos opuestos, solo 2/11 con leyenda, numeración circulada
> desfasada −1). Este doc fija UNA notación para TODA la serie (01–14, ver §9). **Todo flowchart DEBE seguirlo** e incrustar la
> clave de leyenda. Es la regla dura de `diagramar` ("un diagrama entregable lleva leyenda + normas y se
> versiona") aplicada al set.

## 1. Formas
- **Rectángulo** (`shape=box`) = paso / acción · **Redondeado** (`style="rounded,filled"`) = inicial/terminal
- **Rombo** (`shape=diamond`) = decisión · **Cluster** (`subgraph cluster_*`) = agrupación de un flujo/evento

## 2. Colores — 🔴 rojo = DENY, NUNCA hueco (arreglo clave del colectivo)
| Valencia | Relleno / borde | Cuándo |
|---|---|---|
| 🟢 OK / pasa | `fillcolor="#e8f5e9" color="#2e7d32"` | camino feliz, guard que deja pasar |
| 🟠 aviso / ASK | `fillcolor="#fff8e1" color="#f9a825"` | nudge (hook no bloqueante), pregunta de consentimiento |
| 🟡 latente / frágil | `color="#c9a227"` | funciona HOY pero sin garantía (supuesto sin serializar, acoplamiento frágil). Ni bug ni deuda "por construir": riesgo latente aceptado. |
| 🔴 **DENY / bloqueo** | `fillcolor="#ffebee" color="#c62828"` | **guard RECHAZANDO = sistema OK.** RESERVADO a esto. |
| 🚧 hueco / deuda | `fillcolor="#f5f5f5" color="#9e9e9e" style="dashed,filled"` + 🚧 | algo roto/por construir. NUNCA rojo. |
| ⬜ neutro | `fillcolor="#eceff1" color="#607d8b"` | paso sin valencia |
| ⚠ ESCRIBE git | nodo + `penwidth=3 color="#c62828"` + ⚠ | el paso MUTA git (commit/push/branch -d) |

Mnemónico: **rojo relleno = acción rechazada (bien); gris punteado = hueco (mal).**

## 3. LA LEYENDA DE CADA CHART = EL ÁRBOL COMPLETO DEL README (íntegro, en TODOS los flowcharts)
La leyenda que va incrustada en **CADA** flowchart es el **árbol COMPLETO del cerebro** tal como vive en
`README.md` (el bloque cercado que arranca en «🔒 Hooks Forzosos»): las **4 familias con TODAS sus piezas** y el emoji CANÓNICO de cada una —
NO una selección, NO una clave compacta de colores. Cada chart lo lleva **íntegro**, para que se lea solo
sin abrir el README. **Fuente única = el README** (para no driftear, doc=realidad): el bloque de leyenda de
cada `.dot` se **GENERA desde el árbol del README** (un helper lo lee y emite el subgrafo — no se teclea a
mano en cada chart, eso sería N copias que driftean). No hay una lámina de leyenda suelta: el mismo
generador (`gen-leyenda-arbol.sh`) alimenta la leyenda incrustada de cada chart.

**Las 4 familias con TODAS sus piezas y su emoji canónico NO se transcriben aquí a propósito** (doc=realidad
+ fuente única): una copia tecleada a mano de la fuente vuelve a driftear (pasó — la copia que vivía aquí se
quedó atrás del README con hooks de menos y un status stale). Para ver el árbol completo, mira **el bloque
cercado que arranca en «🔒 Hooks Forzosos» de `README.md`** (la fuente) o **la leyenda ya incrustada en
cualquier `.dot`** (byte-idéntica, la genera `gen-leyenda-arbol.sh` desde ese mismo bloque).

**Regla:** el emoji de cada pieza es el CANÓNICO del árbol del README (nada de inventar 🔒/💾/⚙ genéricos por pieza; el emoji de familia 🔒🔔📜💡 sí clasifica).

## 4. Flechas
Sólida = flujo/secuencia · Punteada (`style=dashed`) + etiqueta = referencia cruzada a otro chart, o "se deriva de".

## 5. Rotulado por NÚMERO DE ARCHIVO (se elimina el circulado −1)
Título del chart empieza con su nº de archivo (`06 · Declarar LISTO al fin de turno`); cross-refs citan por
nº de archivo ("ver **05**"), NUNCA circulado ①②③ (iba desfasado −1 sin índice).

## 6. Fan-out compartido de un comando git en Bash = 9 hooks PreToolUse/Bash (raíz común de 03 y sus zooms 06/07/08)
Un comando `Bash` con git dispara **9 hooks PreToolUse/Bash** EN PARALELO (sin despachador, precedencia
`deny>ask>allow`) + hooks PostToolUse. Los 9 pre (confirmado en la función `ev_de` de `install-brain.sh`,
que mapea todos ellos a `PreToolUse|Bash`): 🚧 git-branch-guard · 🔗 merge-squash-guard · ✋ confirmar-merge-develop · 🕵️ secret-scan
· 📊 recordar-dashboard · 🖥️ entorno-maquina-guard · 🕰️ rama-vieja · 🌳 proteger-arbol · 🚧 no-bypass-deploy *(4 pueden DENY: los 3 de
git + secret-scan)*. De esos 9, **8 INSPECCIONAN git**; el 9º —**no-bypass-deploy**— corre en el mismo fan-out pero
**NO-OPEA sobre un comando git** (solo actúa ante un instalador/deploy corrido a mano). En PostToolUse sobre ese Bash
corren 📈 aviso-contexto y 🎼 recordar-orquestar (toda tool) + 🔀 hud-stale y 🧹 barrer-ramas (Bash) — ninguno bloquea; los
charts hacen foco en 📈 aviso-contexto (el watermark). El chart **03** es la VISTA de conjunto; sus **ZOOMS**
—**06** (ruta de merge), **07** (secret-scan + proteger-arbol), **08** (nudges del push)— abren con esta MISMA raíz de 9
y hacen zoom sobre su subconjunto de git-guards. Prohibido "cascada secuencial" o "los 2 hooks".

## 7. Leyenda a incrustar en cada `.dot` = el ÁRBOL COMPLETO del README (generado, NO tecleado)
Cada flowchart incrusta DOS cosas dentro de un `subgraph cluster_leyenda`:
1. **El árbol COMPLETO del README** — las 4 familias con TODAS sus piezas y su emoji canónico. Es la
   leyenda principal. Se **GENERA desde el árbol de `README.md`** (un helper lo lee y emite este subgrafo);
   NO se copia a mano en cada chart → fuente única, sin drift. Al cambiar el README, se re-genera y los
   5 charts se actualizan de una (doc=realidad).
2. **Mini-clave de VALENCIA de color** (secundaria, decodifica el RELLENO de los nodos del diagrama; ver §2).

```dot
  subgraph cluster_leyenda {
    label="LEYENDA — árbol completo del cerebro (fuente: README.md)"; labeljust="l"; fontsize=10;
    color="#b0bec5"; style="rounded"; fontname="Helvetica-Bold"; node [fontsize=9, fontname="Helvetica"];
    // (1) ÁRBOL COMPLETO — GENERADO desde el árbol del README (4 familias × TODAS sus piezas, emoji canónico):
    //       🔒 Forzosos · 🔔 Automático · 📜 Normas · 💡 Skills   (lo rellena el generador, no a mano)
    arbol [shape=plaintext, label=<...árbol completo renderizado desde README.md...>];
    // (2) mini-clave de VALENCIA de color (fija):
    lg_ok  [shape=box, style="filled", fillcolor="#e8f5e9", color="#2e7d32", label="🟢 OK / pasa"];
    lg_ask [shape=box, style="filled", fillcolor="#fff8e1", color="#f9a825", label="🟠 aviso / ASK"];
    lg_lat [shape=box, style="filled", fillcolor="#2b2b2b", color="#c9a227", label="🟡 latente / frágil"];
    lg_dny [shape=box, style="filled", fillcolor="#ffebee", color="#c62828", label="🔴 DENY (guard OK)"];
    lg_gap [shape=box, style="dashed,filled", fillcolor="#f5f5f5", color="#9e9e9e", label="🚧 hueco / deuda"];
    lg_git [shape=box, style="filled", fillcolor="#eceff1", color="#c62828", penwidth=3, label="⚠ ESCRIBE git"];
    lg_ok -> lg_ask -> lg_dny -> lg_gap -> lg_git [style=invis];
  }
```

## 8. Fuente versionada (regla dura)
Cada flowchart = `.dot` (fuente) + `.svg` (vista) en `docs/flowcharts/`; `.png`/`.graphml` regenerables → gitignored.
Render de UNO: `dot -Tsvg archivo.dot -o archivo.svg`. Regenerar TODOS (rutina, checa graphviz): `bash docs/flowcharts/gen-charts.sh` (además avisa si algún chart quedó ignorado). ⚠️ **Trampa del catch-all**: `docs/flowcharts/*` está gitignored por default → un chart NUEVO se pierde en `git add` salvo que le agregues su línea `!` en `.gitignore`. Cambió el código que un chart describe → se actualiza el `.dot` **y su `.svg`** en la misma tanda (doc=realidad).

## 9. La serie completa (01–14) y el mapeo del rescate 2026-08-07
La serie **01–05** es la columna de VISTA de conjunto (rehecha 2026-08-01, fiel al código). Los **06–14** se
**re-canonizaron el 2026-08-07** desde los SVG huérfanos que habían quedado *gitignored SIN `.dot` ni leyenda*
(deuda de mantenimiento, no basura): se les creó su `.dot` fuente, se inyectó la leyenda-árbol, se corrigió el
`doc=realidad` (p. ej. `dod-verificar` y `confirmar-merge-develop` hoy usan un **juez-LLM**, no el pilón de regex viejo)
y se re-numeró para eliminar las colisiones (había dos 03, dos 04, dos 05) y el circulado −1.

| Nº actual | Título | Rol | Huérfano viejo (nombre · circulado) |
|---|---|---|---|
| 01 | Instalación / actualización del cerebro | vista | (ya tracked) |
| 02 | Ciclo de vida de la sesión | vista | (ya tracked; era «①») |
| 03 | Enforcement de los git-guards (fan-out de 9) | VISTA de conjunto | (ya tracked) |
| 04 | Delegación / orquestar fan-out | VISTA de conjunto | (ya tracked) |
| 05 | Continuidad: checkpoint→compact→rehidratar | vista | (ya tracked) |
| 06 | Integrar una rama a develop/main | zoom de 03 (merge) | `03-integrar-rama-a-developmain` · ② |
| 07 | Comando git en Bash: guards que lo inspeccionan | zoom de 03 | `04-comando-git-en-bash-guards-que-lo-inspec` · ③ |
| 08 | Al hacer push: nudges | zoom de 03 | `05-al-hacer-push-nudges` · ④ |
| 09 | Declarar «LISTO» al fin de turno (dod-verificar) | detalle | `06-declarar-listo-al-fin-de-turno` · ⑤ |
| 10 | Cerrar un slice: ritual de pasos | detalle | `07-cerrar-un-slice-ritual-de-pasos` · ⑥ |
| 11 | Delegar un Task/agente | zoom de 04 | `08-delegar-un-taskagente` · ⑦ |
| 12 | Orquestar un fan-out sin niñera | zoom de 04 | `09-orquestar-un-fan-out-sin-ninera` · ⑧ |
| 13 | Normas: el cimiento | cimiento | `10-normas-el-cimiento` · 📜 |
| 14 | Referencia: libs compartidas + skills de stack | referencia | `11-referencia-libskill-de-stack` · 🔩 |

> **VISTA vs ZOOM — decisión de diseño abierta (para unjordi).** 03/04 son las vistas de conjunto que
> CONSOLIDARON (2026-08-01) el material que 06/07/08 (git-guards) y 11/12 (delegación) muestran EN DETALLE.
> CONVENCIONES §6 avala esta coexistencia (una VISTA + sus ZOOMS), y por eso el rescate CONSERVA todo. Si en
> algún momento se decide que las vistas hacen redundantes a los zooms (o viceversa), es una poda DELIBERADA
> del humano — no la fuerza este rescate. Los SVG huérfanos originales siguen en el árbol de trabajo local
> (gitignored, sin `.dot`); pueden borrarse a mano: quedaron SUPERSEDIDOS por su versión versionada aquí.
