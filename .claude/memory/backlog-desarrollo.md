# Backlog de desarrollo del widget

> Ideas de feature pedidas por unjordi, aún NO implementadas. Un ítem = un slice (ramita → MR →
> develop, squash). Al arrancar uno, muévelo a "en curso"; al cerrarlo con QA, bórralo de aquí y
> deja la huella en `bitacora.md`. Ordenado por lo más reciente arriba.

## [2026-07-10] Inicializar / reconciliar el cerebro GLOBAL + barrer todos los slugs desde el widget
**Qué:** una opción en la pestaña **Cerebro** (extiende la 🩹 curita, que hoy solo cura el cerebro
GLOBAL de la máquina) que:
1. **Inicializa/llena el dashboard-global** (`~/.claude/projects/<slug-del-HOME>/memory/dashboard_cerebro.md`)
   si falta o está vacío — sembrándolo de la plantilla (el bootstrap ya lo hace; esto lo EXPONE en el widget).
2. **Barre TODOS los slugs de proyecto** que el widget conoce y, para cada uno que mapee a un repo git,
   verifica/instala su cerebro: correr su `bootstrap-claude.sh` (instala los hooks GLOBALES de máquina +
   enlaza) y confirmar que su `.claude/` (hooks, settings.json, memoria) esté completo. **Reporta** cuáles
   repos les falta algo y ofrece arreglarlos.

**Por qué:** hoy no hay forma, desde el widget, de VER ni ARREGLAR el estado del cerebro de CADA proyecto
repartido por la máquina — solo del global. Al onboardear a un colega (caso Felipe, 2026-07-10) o al
retomar una máquina, se quiere un "reconciliar todo" de un clic.

**Matices / retos:**
- El widget ya conoce los slugs (`stats.projects` + `~/.claude/projects/<slug>/`), y el fetch ya
  normaliza slug → nombre de repo vía `~/.claude.json` (`.projects`). Reusar esa resolución para hallar
  la RUTA del repo de cada slug.
- **No silencioso:** no todo slug es un repo git clonable, y correr `bootstrap-claude.sh` en cada repo es
  invasivo → el patrón debe ser **detectar + reportar + ofrecer arreglar** (opt-in por repo), no auto-correr.
- Las versiones del cerebro entre repos pueden diferir (plantilla vs claude-brain) — reportar divergencias
  en vez de pisarlas a ciegas.
- **Dónde toca:** `BrainInspector`/`healBrain` de la pestaña Cerebro (macOS `PopoverView.swift`, Linux
  `main.qml`, Windows `PopupForm.cs`), + una pasada nueva que itere slugs→repos.

## [2026-07-10] Mover sesiones (con su transcripción) entre slugs
**Qué:** desde Proyectos/Chats, poder **mover una sesión** de un slug a otro — el `.jsonl` vive en
`~/.claude/projects/<slugA>/<id>.jsonl` y se movería a `<slugB>/`.

**Por qué:** si arrancaste una sesión en el dir/slug equivocado (la lección "inicia la sesión DENTRO del
repo"), queda archivada mal; poder re-archivarla la deja donde corresponde en el widget.

**Matices / retos (decisión de diseño pendiente):**
- El nombre del `.jsonl` = `sessionId`; el **cwd vive DENTRO del transcript** y `claude --resume <id>` lo usa.
  Mover el archivo a otro slug-dir **cambia la agrupación del widget** (que agrupa por slug/cwd) PERO **no**
  cambia el cwd real → el resume seguiría abriendo en el cwd original.
- Por eso hay que definir el ALCANCE: (a) mover el archivo = solo re-categoriza en el widget, o (b) además
  reescribir el cwd en el transcript para re-targetear el `--resume` (más riesgoso: tocar el .jsonl de Claude
  Code). Empezar por (a) con la advertencia clara, y evaluar (b).
- **Dónde toca:** `sessions-extract.js` (agrupa por slug/cwd) + una acción "mover a…" en la UI de
  Proyectos/Chats (las 3 GUIs).
