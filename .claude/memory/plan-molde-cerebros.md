---
name: plan-molde-cerebros
description: Plan PLANCHADO (listo para ejecutar en frío) para aplicar el molde canónico del CLAUDE.md a los cerebros elegibles de ~/code. Acordado con unjordi 2026-08-03 noche; ejecutar cuando lo pida.
metadata:
  type: project
---

# Plan planchado — upgrade de cerebros al MOLDE canónico

> **Estado:** acordado y planchado 2026-08-03; **NO ejecutado** (unjordi: "déjalo listo para mañana").
> Ejecutar solo cuando unjordi lo pida. Todo en RAMAS, nada se mergea sin su QA.

## 🎯 Misión
Aplicar el **molde canónico** (el que pulimos hoy y "se nota la diferencia" en games-master) a los cerebros elegibles que aún no lo tienen.

**El molde:** `CLAUDE.md = FIRMA` (misión/identidad + mapa de capacidades + reglas duras + `@.claude/memory/MEMORY.md`) · `MEMORY.md = índice + árbol + detalle 1:1`. **Referencias de oro** (ya hechas, para copiar el patrón): **games-master**, **cps** (el ref para repos con CLAUDE+AGENTS), **claude-brain** (`claude-brain.firma-wt`, #35).

## ✅ Repos IN (solo estos dos)
| Repo | Firma actual | Patrón a aplicar |
|---|---|---|
| `cenam_contnac` | solo `AGENTS.md` (~3145 líneas), rama `develop` | CREAR `CLAUDE.md`-firma + `@import MEMORY`; **AGENTS.md queda INTACTO** |
| `registros_bats_y_buses` (fluxcore) | `CLAUDE.md`(51)+`AGENTS.md`(3444), rama de trabajo su mini | Reestructurar `CLAUDE.md`→firma + `@import`; **AGENTS.md INTACTO** |

## ⛔ Repos OUT (duros — NO tocar)
- **Ya rehechos:** games · cps · claude-brain · powerscripts.
- **Activos (otro claude trabajando):** `potenciaDatabases` (databases-master) · `pisamrpclaude`.
- **`plantilladotnet`** — es la plantilla .NET *y* la base donde corro. NO tocar.
- **`mfx_infraestructuradigital`** — no tiene entry-point; unjordi dijo "tampoco lo toques" (queda para sesión revisada).

## 🔧 Cómo ejecutar (recetario)
1. **Fan-out autorizado** (unjordi dio OK 2026-08-03): 1 agente por repo en **worktree AISLADO** (`isolation: "worktree"`). Yo orquesto, reviso diffs, no niñereo.
2. **Patrón para repos con AGENTS.md gigante** (ambos IN lo tienen): el `CLAUDE.md` se vuelve el **entry-point firma** que apunta a AGENTS (contrato de arquitectura, **se deja intacto**) + MEMORY. ⛔ **NO reescribir/destripar el AGENTS.md** — sería destructivo y no-transitivo; solo se crea/ordena la firma y el árbol/índice en MEMORY.
3. **Git:** rama `chore/molde-firma` por repo → commit → push → **MR preparado, NO mergeado**. La integración a develop/mini la decide unjordi con su QA (ve el diff y "se nota la diferencia").
4. **Dualidad** donde aplique (no mutar `brain/` de un repo-fuente).
5. **Parity-check** verde donde exista.

## 📤 Entregable
Tabla-resumen: repo → rama → qué cambió → link del diff. Todo en ramas para QA de unjordi.

## Relación con otras tareas
- Complementa (no depende de) el **release del brain** (#24), que sigue parqueado por red + su `!`.
- Buen prerrequisito opcional: **codificar el molde como estándar** (#36) para que el fan-out sea reproducible — se puede hacer como primer paso (leyendo games/cps/brain como referencia).
