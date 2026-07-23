---
name: diseno-sync-sesiones
description: Mecanismo para que las SESIONES/transcripts de Claude Code viajen con un repo git y se pueda `claude --resume` en otra máquina (Mac↔Cachy↔Windows). Es la "v2 opcional" que diseno-unificar-cerebro marcó (curado→ahora crudo-comprimido). Motor verificado 2026-07-23.
metadata:
  type: project
---

# Sync de sesiones cross-máquina — `claude --resume` tras `git pull`

> **Estado (2026-07-23):** motor construido y **verificado técnicamente** (round-trip export→import
> perfecto); wiring de git (dónde viven los commits) + despliegue en instaladores + release PENDIENTE
> de una decisión de unjordi. Rama: `feat/sync-sesiones-cross-maquina` (brain, desde develop).
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
3. **PENDIENTE (a decidir):** *cómo* mantenerlo fuera de develop/clones — rama de transporte dedicada
   `sesiones/<usuario>` (recomendada, cero fricción de integración) vs commit en la mini + guard/CI que
   lo despoje antes del MR a develop. (Detalle abajo en "Wiring de git".)

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

## Wiring de git (LA decisión pendiente)
- **Opción A — rama de transporte dedicada `sesiones/<usuario>` (RECOMENDADA).** `.claude/sessions/`
  queda **gitignored en develop/mini** (nunca sube por accidente en un feature/MR). Las sesiones se
  commitean con `git add -f` SOLO en `sesiones/unjordi`, que **jamás se mergea** a develop → viaja
  Mac↔Cachy por `git push/pull origin sesiones/unjordi`, y como los clones nacen de develop/main,
  **nunca las ven**. Cero fricción, **sin guard nuevo que bloquee merges**.
- **Opción B — en la mini + guard.** Commit en `DevelopUnjordi`; un guard/CI `sesiones-fuera-de-develop`
  bloquea/despoja `.claude/sessions/` en el MR mini→develop. Más fiel al literal "en mi mini", pero
  **fricción cada integración** + guard nuevo que bloquea (delicado por la norma de guardarraíles).

## Wiring restante (tras la decisión)
- **Despliegue:** añadir `session-lib.js`/`session-export.js`/`session-import.js` a los 3 instaladores
  (`install.sh` raíz + `macos/install.sh` + `brain/install-brain.sh`), junto a `session-move.js`.
- **Auto-import al retomar:** hook `SessionStart` (o paso de `sesion-inicio`) que corre
  `session-import.js --repo <cwd>` (idempotente, barato) → tras `git pull` en Cachy las sesiones se
  siembran solas y el picker de `--resume` ya las lista.
- **Export opt-in:** wrapper `claude-session export <id>` + botón en el widget ("Exportar al repo").
- **Doc:** `ecosistema-claude.md` (sección Sesiones ya no dice "no construido"), `mapa-cerebro.md`,
  README del brain, MANIFEST si aplica.
- **Secreto:** el `secret-scan` por-repo ya escanea lo que ENTRA a git → cubre el commit de sesiones
  (AWS/OpenAI/Anthropic/GitHub/GitLab/PEM). Es una red, no garantía total → anotarlo en la doc.

## Herencia / multi-dev
Genérico (vive en el brain, viaja por bootstrap). Cada dev exporta SUS sesiones a SU rama de transporte
`sesiones/<usuario>`; nadie ve las de otro (privacidad) — es transporte cross-MÁQUINA del mismo dev, NO
compartir sesiones entre devs (eso sería otra cosa). Encaja con la capa de cosecha semanal de
`diseno-unificar-cerebro.md`: los aprendizajes CURADOS siguen yendo a `aprendizajes.md` (git-shared);
esto solo mueve el CRUDO comprimido para poder retomar la MISMA sesión en otra compu.
