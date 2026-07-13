---
name: orquestar-fanout
description: >
  Orquestar un fan-out de agentes SIN NIÑERA: asignar ítems autocontenidos del backlog, y que al
  terminar cada agente su avance quede registrado y su worktree limpio AUTOMÁTICAMENTE — no
  monitoreándolos a mano. Define el modelo de estado (2 archivos, sin redundancia) y el contrato de
  reporte. Úsalo cuando delegues trabajo paralelizable a varios agentes.
---

# orquestar-fanout — fan-out con auto-reporte (sin niñera)

El hueco que cierra: los agentes hacían el trabajo pero NO reportaban; el estado del proyecto
dependía de que el humano lo pidiera y monitoreara a mano. Esta skill hace del **auto-reporte el
default** y mata la redundancia de dónde vive el estado.

## Modelo de estado — DOS archivos, roles claros (cero redundancia)
- **`.claude/memory/estado-proyecto.md`** = la **fuente de verdad**: dónde estamos + **BACKLOG VIVO**
  (pendientes autocontenidos, con prioridad + HELD "esperan tu decisión" + follow-ups + justificación).
  **Aquí empiezas siempre.** Lo **cura el orquestador** (no los agentes en paralelo → cero conflictos).
- **`.claude/memory/bitacora.md`** = **log cronológico append-only** (qué se cerró y cuándo). `merge=union`
  → parallel-safe. **Aquí APPENDAN los agentes/orquestador** una línea por slice.
- Regla anti-redundancia: **el mismo dato NO se escribe en 3 lados.** bitácora = *qué pasó*;
  estado-proyecto = *qué sigue*. El estado "actual" se DERIVA (leer ambos), no se triplica.
- La lista de **TodoWrite** del harness es **scratch de sesión** — el backlog DURABLE es
  estado-proyecto.md. No confundas una con la otra.

## Regla dura de AISLAMIENTO (lo que evita que un agente te coma trabajo)
**Todo agente que MUTE archivos o COMMITEE corre en un WORKTREE AISLADO, NUNCA en el árbol de trabajo
COMPARTIDO/principal.** Spawnéalo con `isolation: "worktree"` (el Agent tool crea un worktree fresco) o
dale tú un worktree disjunto. El árbol principal es SOLO del orquestador (o del humano). **Por qué muerde:**
un agente que corre `git reset`/`checkout`/`rebase` en el árbol compartido puede **mover el HEAD y dejar
huérfanos los commits del orquestador** → la fuente queda a medias y el build compila eso (lección REAL de
cps, 2026-07: un agente de verificación se metió al árbol principal, reseteó HEAD y orfanó un commit; se
recuperó por cherry-pick, pero casi se pierde). Si un ítem NO se puede aislar en su worktree, **lo hace el
orquestador**, no un agente suelto en el árbol compartido. Lo respalda el guard `proteger-arbol` (avisa
antes de un git destructivo que orfanaría commits sin pushear).

## El flujo (lo que hace el orquestador)
1. **Asigna:** saca del backlog (estado-proyecto.md) ítems **autocontenidos** (uno que un agente
   pueda cerrar solo, sin depender de otro en vuelo). Reparte **archivos disjuntos** (regla anti-choque)
   y **cada agente que toque código va en su WORKTREE AISLADO** (ver regla dura arriba).
2. **Contrato del agente:** cada agente DEVUELVE, además del trabajo:
   - `qué hizo` (el cambio neto),
   - `línea-de-bitácora` curada (prosa, no el pegote de commits),
   - `pendiente` que deje para otro (o "ninguno"),
   - `worktree`: `limpio` (rama mergeada) o `dejado-con-<nota>`.
3. **Cierra el loop (AUTOMÁTICO al terminar cada agente — lo recuerda el hook `delegacion-reporte`):**
   - **APPENDA** la línea a `bitacora.md`.
   - **ACTUALIZA/cierra** el ítem en `estado-proyecto.md` (backlog vivo).
   - **WORKTREE:** corre `limpiar-worktrees.sh` (borra los de ramas ya mergeadas; los vivos/a-medias
     los DEJA y anota su pendiente en la bitácora para quien lo retome).
   → No monitoreas a los agentes: el reporte y la limpieza son el cierre estándar.

## Hooks/tools que lo sostienen
- **`delegacion-gate`** (PreToolUse/Task) — consentimiento de costo por ventana de 5h (ver el flujo de gasto).
- **`delegacion-reporte`** (PostToolUse/Task) — tras cada subagente, recuerda registrar avance + limpiar worktree.
- **`limpiar-worktrees.sh`** — barre worktrees zombies (rama mergeada) y anota los vivos en la bitácora.
- **`proteger-arbol`** (PreToolUse/Bash) — avisa antes de un git DESTRUCTIVO (`reset --hard`/`checkout -f`/`rebase`/`branch -D`) que orfanaría commits sin pushear; antídoto al "agente reseteó HEAD en el árbol compartido".
- **`precompact-volcar-estado`** (PreCompact) — antes de compactar, vuelca avance/decisiones/pendientes.

## Anti-patrones
- ❌ Monitorear agentes "de niñera" y actualizar el estado a mano al final. → El auto-reporte es el default.
- ❌ Escribir el mismo pendiente en estado-proyecto Y bitácora Y un backlog aparte. → Un dato, un lugar.
- ❌ Dejar worktrees zombies acumulándose. → `limpiar-worktrees.sh` al cerrar la ola.
- ❌ Asignar ítems NO autocontenidos (que dependen de otro agente en vuelo). → Serialízalos o únelos.
- ❌ Dejar que un agente mute/commitee en el árbol de trabajo COMPARTIDO (o corra `git reset`/`checkout`/`rebase` ahí). → Worktree AISLADO por agente, o lo hace el orquestador. Es lo que orfanó un commit en cps.
