---
name: diseno-sync-sesiones
description: Mecanismo para que las SESIONES/transcripts de Claude Code viajen con un repo git y se pueda `claude --resume` en otra máquina (Mac↔Cachy↔Windows). Es la "v2 opcional" que diseno-unificar-cerebro marcó (curado→ahora crudo-comprimido). Motor verificado 2026-07-23.
metadata:
  type: project
---

# Sync de sesiones cross-máquina — `claude --resume` tras `git pull`

> **Estado (2026-07-23) — LIBERADO A MAIN.** Motor + wrapper construidos, verificados end-to-end
> (round-trip export→import cross-máquina perfecto) y **liberados a main**: MR **#182→develop** +
> release **#183→main** (2026-07-23). `bin/claude-session` vive en `origin/main` y está desplegado en
> `~/.local/bin/`. La decisión de wiring de git quedó **resuelta = Opción A** (rama de transporte orphan
> `sesiones/<usuario>`). **Falta (NO construido aún, manual por ahora):** el auto-import en `SessionStart`
> y el botón "Exportar al repo" del widget — hoy export/import son **por CLI** (`claude-session`).
> Es la **v2** que `plantilladotnet/.claude/memory/diseno-unificar-cerebro.md` (líneas 156-157) dejó
> marcada como "opcional NO enfilada: sincronizar transcripts crudos… mejor curado, no crudo". unjordi
> la enfiló. Resolución del trade-off crudo/curado: **crudo pero COMPRIMIDO (gzip) + opt-in** (solo las
> sesiones que marcas viajan → no se arrastra basura ni se infla el repo con las de 100 MB).

## El problema (verificado leyendo el CLI v2.1.218, no hipótesis)
- Cada sesión es UN archivo `~/.claude/projects/<slug>/<sessionId>.jsonl`. El `<slug>` se DERIVA del
  cwd absoluto (cada char no-alfanumérico → `-`). **El slug NO vive dentro del jsonl** (solo es el
  nombre del dir); el `cwd` SÍ está en muchas líneas.
- `claude --resume <id>` busca en el slug del **cwd actual**. En otra máquina el repo vive en otra
  ruta (`/Users/…` Mac vs `/home/…` Cachy vs `C:\…` Win) → **slug distinto + cwd interno equivocado**.
  Un copy crudo NO basta: hay que re-sluggear + reescribir el cwd de cada línea.
- No hay `claude compact` headless (confirmado): un hook NO puede disparar compactación, solo
  reaccionar. `SessionEnd`/`PreCompact`/`PostCompact` reciben `transcript_path`+`cwd`+`session_id` →
  sirven para EXPORTAR automático, no para adelgazar. (Por eso el adelgazado = gzip, no compact.)
- Los transcripts pesan **decenas–cientos de MB** (vi 79/91/101 MB) y traen **datos sensibles** (log
  completo, posibles secretos pegados). Por eso NO van crudos a git compartido.

## Decisiones de unjordi (2026-07-23, registradas)
1. **Canal = git, SOLO en el espacio personal de unjordi (su mini-develop `DevelopUnjordi`)** — nunca a
   `develop`/`main` ni a los clones de la plantilla. (Descartado: el canal Drive/NAS fuera de git.)
2. **Alcance = opt-in** — solo las sesiones que unjordi marca explícitamente viajan (señal natural: las
   que ya nombró en el widget → `sesiones-alias.json`). No auto-exportar todo.
3. **RESUELTA → Opción A (rama de transporte dedicada `sesiones/<usuario>`).** Es lo que se construyó:
   `.claude/sessions/` gitignored en develop/mini + rama orphan que jamás se mergea. Cero fricción, sin
   guard nuevo. (Detalle abajo en "Wiring de git".)

## Motor (CONSTRUIDO y verificado — brain `bin/`)
- **`session-lib.js`** — helpers COMPARTIDOS (fuente única, no divergir; misma disciplina que
  `analizar-comando-git.sh`): `slugFromCwd`, `findSession`, `rewriteCwd`, `firstCwd`,
  `titleFromTranscript` (lee el `custom-title`/`ai-title` que el CLI nuevo ya mete al jsonl),
  `sessionAliases`/`writeAlias`. `session-move.js` **refactorizado** para consumirla (comportamiento
  idéntico). (Pendiente menor: migrar también `sessions-extract.js` a la lib — baja prioridad, es leaf.)
- **`session-export.js <id> --repo <ruta> [--name "…"] [--force]`** — localiza el jsonl, lo **gzip**ea a
  `<repo>/.claude/sessions/<id>.jsonl.gz` + sidecar `<id>.meta.json` (origen cwd/slug/máquina/plataforma/
  título/tamaños/fecha). NO toca git. Idempotente (pide `--force` para re-embarcar).
- **`session-import.js --repo <ruta> [--force] [--only <id>] [--dry-run]`** — por cada `.jsonl.gz`:
  gunzip → **reescribe el cwd al del repo LOCAL** → escribe `~/.claude/projects/<slug-local>/<id>.jsonl`
  → restaura el alias del meta. Idempotente (salta si ya existe local, salvo `--force`).

### Evidencia de la verificación (2026-07-23, home de juguete `CLAUDE_CONFIG_DIR`)
Export de una sesión (24 KB) → import a un repo con **ruta distinta** → el import derivó el slug local,
reescribió 7 ocurrencias de cwd, quedó **idéntico byte a byte salvo el cwd** (`diff` normalizado = 0),
restauró el alias, y el re-import **saltó** (idempotente). gzip: 2.7x en archivo chico (mucho más en los
grandes, que son JSON repetitivo).

## Wiring de git (RESUELTO → Opción A, construida)
- **Opción A — rama de transporte dedicada `sesiones/<usuario>` (ELEGIDA Y CONSTRUIDA).** `.claude/sessions/`
  queda **gitignored en develop/mini** (nunca sube por accidente en un feature/MR). Las sesiones se
  commitean con `git add -f` SOLO en `sesiones/unjordi`, que **jamás se mergea** a develop → viaja
  Mac↔Cachy por `git push/pull origin sesiones/unjordi`, y como los clones nacen de develop/main,
  **nunca las ven**. Cero fricción, **sin guard nuevo que bloquee merges**.
- **Opción B — en la mini + guard.** Commit en `DevelopUnjordi`; un guard/CI `sesiones-fuera-de-develop`
  bloquea/despoja `.claude/sessions/` en el MR mini→develop. Más fiel al literal "en mi mini", pero
  **fricción cada integración** + guard nuevo que bloquea (delicado por la norma de guardarraíles).

## Cómo se USA hoy (CLI, ya desplegado)
Parado **dentro del repo** con el que la sesión debe viajar (el wrapper deriva el repo de `git rev-parse
--show-toplevel`):
- `claude-session export <sessionId> [--name "etiqueta"]` — gzip la sesión → la commitea a la rama
  orphan `sesiones/<usuario>` → `git push`. OPT-IN (solo la que nombras).
- `claude-session import [--force]` — en la OTRA máquina, tras `git pull`: baja la rama de transporte y
  siembra las sesiones en el slug local (reescribe el cwd) → el picker de `claude --resume` ya las lista.
- `claude-session list` — qué hay embarcado en la rama de transporte.

## Wiring — estado
- ✅ **Motor + wrapper + despliegue en instaladores** (`install.sh` raíz + `macos/install.sh` +
  `windows/install.ps1`; `brain/install-brain.sh` es de hooks/skills, no aplica) — HECHO y liberado.
- ✅ **Doc:** `ecosistema-claude.md` sección Sesiones actualizada (ya no dice "no construido").
- ❌ **Auto-import al retomar** (hook `SessionStart`/paso de `sesion-inicio` que corra
  `claude-session import` idempotente tras `git pull`) — **NO construido**. Hoy el import es manual.
- ❌ **Botón "Exportar al repo" en el widget** — **NO construido**. Hoy el export es por CLI.
- **Secreto:** el `secret-scan` por-repo ya escanea lo que ENTRA a git → cubre el commit de sesiones
  (AWS/OpenAI/Anthropic/GitHub/GitLab/PEM). Es una red, no garantía total.

## Herencia / multi-dev
Genérico (vive en el brain, viaja por bootstrap). Cada dev exporta SUS sesiones a SU rama de transporte
`sesiones/<usuario>`; nadie ve las de otro (privacidad) — es transporte cross-MÁQUINA del mismo dev, NO
compartir sesiones entre devs (eso sería otra cosa). Encaja con la capa de cosecha semanal de
`diseno-unificar-cerebro.md`: los aprendizajes CURADOS siguen yendo a `aprendizajes.md` (git-shared);
esto solo mueve el CRUDO comprimido para poder retomar la MISMA sesión en otra compu.
