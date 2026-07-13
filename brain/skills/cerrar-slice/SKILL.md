---
name: cerrar-slice
description: Ejecuta el ritual de CIERRE de un slice — verifica (build/tests/lint según tu stack), actualiza la memoria, confirma con el usuario, lo lleva por el flujo de git (ramita→MR/PR→develop) y cosecha los aprendizajes genéricos a skills/cerebro global. Úsala cuando creas que terminaste un slice, para no declarar "listo" sin evidencia ni saltarte el flujo.
---

# Cerrar un slice (definición de terminado + flujo)

Encapsula la **"definición de terminado" con evidencia** y el **flujo de git**. Lo refuerzan los hooks
**Stop** (`dod-verificar`, bloquea "listo" sin evidencia), **git-branch-guard** (bloquea push a
develop/main), **confirmar-merge-develop** (exige tu OK expreso antes de integrar) y **recordar-dashboard**
(en el push te recuerda el dashboard + doc=realidad = el Paso 2 de aquí). Sigue el orden — no te saltes
pasos. Versión **genérica** (agnóstica de stack): sirve para cualquier proyecto que use este cerebro.

## 1. Verifica (evidencia real, no tu memoria del chat)
- Corre la **verificación técnica que aplique a tu stack** y **CITA la salida real** (0 errores):
  build + tests + lint. Ejemplos: `npm run build && npm test`, `dotnet build && dotnet test`,
  `cargo build && cargo test`, `go build ./... && go test ./...`, `pytest`, `make`.
- Revisa el **contrato de arquitectura** (`AGENTS.md` si el repo lo tiene) si tocaste capas/estructura.
  Si es **MIGRACIÓN**: revisa el inventario de paridad **Y** el módulo real de la app legada; marca el
  ítem como migrado solo si pasó la verificación.
- **Runtime-safe, no solo compila:** para cambios de **API / DTO / repos / SQL**, corre un **smoke E2E**
  (en Docker si aplica) que golpee el endpoint/flujo tocado — build+unit NO ven bugs de runtime (una
  firma que rompe la materialización Dapper → 500; `Ok(string)` text/plain que cuelga un diálogo; SQL
  dinámico mal armado → 0 filas; todos pasaron build+tests y reventaron en vivo, incluso llegaron a producción).
- **Cambio DESTRUCTIVO = pausa + OK.** Si el diff ELIMINA funcionalidad/entidades/tablas o mucho código,
  es destructivo y **NO transitivo** aunque un doc lo respalde: preséntalo al usuario como PÉRDIDA explícita
  ("esto borra X que costó Y") y pide su OK ANTES de ejecutarlo/cerrarlo. (En un caso real se aplanó un esquema de
  permisos jerárquico de meses amparado en `AGENTS.md`, sin avisar que era una pérdida.)
- Recuerda: **verde técnico ≠ LISTO.** Es *verificado técnicamente*: peldaño necesario, insuficiente
  para declarar LISTO (falta (1) confirmación funcional del usuario o (2) su autorización expresa).

## 2. Actualiza la memoria Y la doc (en la misma tanda — doc = realidad)
Modelo de estado: **`estado-proyecto.md` = hub vivo** (dónde estamos + backlog + prioridad); **`bitacora.md`
= log append-only**. Un dato en UN lugar (bitácora=qué pasó, estado=qué sigue), no en tres (ver skill `orquestar-fanout`).
- `.claude/memory/estado-proyecto.md`: mueve el ítem a **HECHO** (commit+fecha al mergear); registra
  **DECISIONES**; lo descartado a propósito va en **FUERA POR DECISIÓN** (no en pendiente). **Estado
  BIDIRECCIONAL:** ni dejes "pendiente" algo que YA está hecho, ni marques "hecho" algo sin verificar —
  la doc miente en ambos sentidos y cuesta auditorías (en un caso real el usuario forzó 3 por esto).
- **Appendea UNA línea al FINAL** de `.claude/memory/bitacora.md` (`- fecha · rama · quién · qué`)
  con `>>` (`printf '%s\n' '- …' >> bitacora.md`), **no** con un Edit que reescriba: el append-al-final
  es lo que deja que varias sesiones/agentes escriban la misma bitácora sin pisarse (dos `>>` no chocan;
  un Edit tropieza con "File modified since read").
- Si la feature creció, deja su nota `.claude/memory/<feature>.md` y enlázala en `MEMORY.md`.
- **doc = realidad (NO se pregunta):** si cambiaste comportamiento, config, rutas, una interfaz o un
  hook/skill, actualiza la doc que lo **DESCRIBE** en ESTA misma tanda — README (p. ej. el árbol del
  cerebro + el conteo de checks de `test-brain.sh`), `docs/`, comentarios. **Rastrea las copias** (un
  `grep` del nombre/valor viejo): una doc desincronizada YA es una doc que miente. **RELEE el
  ENCABEZADO/resumen de apertura del doc, no solo la línea que tocaste** — el "arriba" es lo primero que
  se lee; un encabezado stale ("Dos hitos cerrados") mientras el cuerpo ya avanzó es la trampa más común
  (pasó en un caso real varias veces). Y si dos números/valores describen lo mismo (una badge y la prosa), que
  coincidan — desincronizados YA mienten.
- **Dashboard GLOBAL** (`dashboard_cerebro.md`, memoria de ESTA máquina): **appendea** una línea al FINAL
  de su Bitácora con `>>` (no con un Edit) — así no chocas con las otras sesiones de Claude que tocan ese
  archivo a la vez. Ajusta Mapa/Infra/Cabos (secciones curadas, con Edit) solo si cambió el layout de
  repos/memoria/proyectos.
- **(fan-out)** limpia los worktrees zombies con `limpiar-worktrees.sh` (deja anotado el pendiente de
  los que sigan vivos).

## 3. Confirma CON EL USUARIO antes del MR/PR
Commit y push a la **ramita** van libres, sin pedir permiso. Pero **antes de integrar a develop,
PREGÚNTALE al usuario si el slice queda cerrado.** El merge a develop no se hace sin esa confirmación
(un release a main, tampoco — eso lo decide el humano deliberadamente).

## 4. Flujo de git (tras el OK del usuario) — **integra con SQUASH**
La ramita se colapsa a **UN commit limpio** en develop (lo exige el hook `merge-squash-guard`).

```bash
# GitLab (glab):
git push -u origin feat/<tema>
glab mr create --source-branch feat/<tema> --target-branch develop \
  --squash-before-merge --remove-source-branch --title "…" --description "…" --yes
glab mr merge <id> --squash --squash-message "$(cat resumen.md)" \
  --auto-merge --remove-source-branch --yes                     # 1–3 devs → auto-merge

# GitHub (gh):
git push -u origin feat/<tema>
gh pr create --base develop --fill
gh pr merge <id> --squash --auto                                # 1–3 devs → auto-merge

git checkout develop && git pull --ff-only && git branch -d feat/<tema>
```

### El mensaje-resumen (`--squash-message`) — redáctalo bien, es lo que queda en develop
Los N commits granulares de la ramita **desaparecen** del histórico de develop; solo queda este mensaje.
Escríbelo como un **resumen curado en prosa**: título Conventional en español + un cuerpo que cuenta el
**cambio neto y su porqué**. **NO** pegues la lista de commits ni el ruido de "quité el botón / lo regresé
/ hotfix del hotfix" — eso es exactamente lo que el squash borra. Termina con el `Co-Authored-By`.

> Gotcha `glab`: es `--auto-merge`, no `--auto`. El guard bloquea el literal `glab mr merge` como dato
> (p. ej. en un grep o una descripción) → pásalo por variable/archivo, no en texto plano.
> El candado server-side definitivo es proteger las ramas + `squash_option=always` (GitLab).
>
> Gotchas de commit (destilados de un caso real): el mensaje largo va por **heredoc** (`git commit -F -`) o un
> archivo ÚNICO en `/tmp` — **NUNCA dentro del repo** (se cuela al árbol) ni reutilizando uno viejo
> (commit con mensaje equivocado → `--amend`). Y **no encadenes `git commit`/`push` dentro de loops de
> espera en background** (`pgrep`/`pkill`): se truncan y dejan el commit a medias — separa "esperar a que
> algo esté listo" (foreground/Monitor) de las acciones git (atómicas).

## 5. Cosecha de aprendizaje Y de herramientas (¿es genérico? ¿sobrevive al reinicio?)
Antes de dar por cerrado el slice, pregúntate: **¿dejó una lección reutilizable** (un gotcha, una
convención, un patrón, o hasta una skill nueva)? No lo dejes en "ya me acordaré" — cosecharlo es parte
del cierre, no un extra.
- **Genérica** (no atada a este proyecto) → promuévela en la MISMA tanda a la **skill** que le toque
  y/o al **cerebro global** (`claude-brain` / los hooks y normas de `~/.claude`). Es el punto de
  curación manual: tú y el usuario deciden qué merece subir (no todo sube — evita ensuciar el global
  con ruido específico del proyecto).
- **Específica del proyecto** → ya quedó en la memoria del repo (Paso 2); no la subas al global.

**Persiste las HERRAMIENTAS que construiste en scratch (no solo las lecciones).** Un script/tool
reusable que armaste durante el slice (un extractor, un `analyze.py`, un one-off que resultó útil)
vive en el **scratchpad de la sesión / `/tmp` / un worktree** — y eso **muere al reiniciar la app o
cerrar el worktree**. Si es semilla reusable (no scratch de exploración de un solo uso), **cópialo al
repo** en esta misma tanda (p. ej. `scripts/<tema>/`) y **commitéalo**. Y si un doc o el backlog ya
**referencia una ruta** de esas herramientas (`scripts/etl-ots/`…), **que esa ruta exista** — una
referencia a un archivo que no está es otra doc que miente. (Regla destilada de un catch real (2026-07):
la maquinaria ETL vivía solo en el scratchpad y la sesión nueva no la encontraba.)

Un hook puede *recordar* este paso, pero no *juzgar* si cosechaste bien (lección vs herramienta,
reusable vs scratch) — por eso vive aquí.
