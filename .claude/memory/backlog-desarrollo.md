# Backlog de desarrollo del widget

> Ideas de feature pedidas por unjordi, aún NO implementadas. Un ítem = un slice (ramita → MR →
> develop, squash). Al arrancar uno, muévelo a "en curso"; al cerrarlo con QA, bórralo de aquí y
> deja la huella en `bitacora.md`. Ordenado por lo más reciente arriba.

## [2026-07-11] No desechar el último OAuth bueno al fallar la lectura (tener≠nunca-tener)
**Qué (unjordi, 2026-07-11):** hoy el fetch reescribe `state.json` COMPLETO y sin condición en cada
tick (~9 min); el `basis` se recalcula desde cero (`basis: (if $usage!=null then "oauth" else "cost")`).
Si la lectura OAuth falla —token vencido, un 401, o un parpadeo de red que tumba el `curl`— esa corrida
**aplasta el % real con el estimado local (cost-basis)**, aunque el número real de hace minutos siga
siendo válido. Síntoma real: la Cachy con el token vencido 17h mostraba 5h=0% / semanal=1.1% mientras la
Mac (OAuth vivo) mostraba el real 98% / 50% — MISMA cuenta, números distintos solo por el basis.

**El principio (unjordi, textual):** *"no es lo mismo tener OAuth y perderlo a nunca haberlo tenido; si lo
tuvo y lo perdió, no debería desechar a lo wey."* → tres estados, no dos:
- **Nunca tuvo OAuth** (máquina fresca / sin login) → el estimado LOCAL (cost-basis) es lo mejor que hay. OK.
- **Tuvo OAuth y lo perdió, RECIENTE** (dentro de la ventana 5h/semanal) → **cargar hacia adelante el último
  % real marcado como STALE** (`basis:"oauth-stale"` + `stale_since`), NO aplastarlo con el estimado local.
- **Tuvo OAuth y lo perdió, VIEJO** (fuera de ventana → el número ya no significa) → degradar, pero aun así
  decir "último real: X% a las HH:MM, no puedo refrescar", nunca un 0% con cara de verdad.

**El patrón ya existe a medias:** líneas 42‑50 de `src/bin/claude-brain-fetch` YA cargan hacia adelante el
`resets_at` real del último OAuth cuando cae a fallback (un "próximo lunes" adivinado estaría mal). Solo hay
que **extender ese mismo mecanismo a los porcentajes** (y a `cost_usd`/`tokens`), con el timestamp de staleness.

**Unifica 3 cabos que salieron el mismo día** (NO tres ítems sueltos):
1. **No clobberear** el último-OAuth-bueno (este ítem, el núcleo).
2. **Auto-refresh del token**: el daemon podría refrescar con el `refresh_token` guardado (`claudeAiOauth.refreshToken`)
   en vez de esperar a que el humano abra `claude` — así una máquina inactiva no se queda ciega. (Evaluar riesgo:
   el CLI y Claude.app comparten el slot de credencial; un refresh a destiempo no debe pisar identidad — ya hay
   guard de account-mismatch.)
3. **Marcar visualmente** el modo stale/fallback en las 3 GUIs (⚠ / "estimado local" / "último real HH:MM")
   en vez de un número confiado. Un 0% confiado tapando un 98% real es la trampa de UX que hay que matar.

**Dónde toca:** `src/bin/claude-brain-fetch` + `macos/bin/claude-brain-fetch` (la lógica de basis + carry-forward);
Windows `QuotaService` (misma lógica en C#); el badge de estado en las 3 GUIs (Swift/QML/WinForms). **No urge**
(el caso se auto-cura al refrescar el token), pero es correctez de datos: el widget no debe mentir con cara de verdad.

## [2026-07-11] Arreglar el extractor de Chats (formato del app de escritorio cambió)
**Qué:** `bin/chats-extract.js` devuelve `[]` aunque el IndexedDB del app de escritorio TIENE datos
(~2.5 MB, app corriendo con chats activos) → la pestaña Chats se auto-oculta. El app de Claude **cambió
el formato de su cache** (update); el parser Snappy+V8/Blink de `chats-extract.js` ya no reconoce las
conversaciones. **NO es pérdida de datos** (los chats están en el app + claude.ai); es que nuestro lector
quedó desfasado. **Qué hacer:** re-ingeniería-inversa del nuevo formato (como el build original — un
snapshot del IndexedDB + inspeccionar el envelope/estructura) y actualizar `chats-extract.js`. Aplica a
las 3 plataformas (el extractor es compartido). **Fragilidad inherente:** leer un cache privado no
documentado se rompe con cada update del app → considerar si vale la pena mantenerlo vs. deprecar la
pestaña Chats. unjordi: al backlog, no urge (2026-07-11).

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

## [2026-07-11] Contexto al renombrar una sesión (+ sugerir nombre)
**Qué (unjordi, 2026-07-11):** al abrir "Renombrar sesión" es **difícil saber qué nombre poner** — el
diálogo solo trae la etiqueta actual (el 1er mensaje). Ofrecer contexto del CONTENIDO de la sesión:
(a) mostrar el **resumen** que ya trae (viene en inglés — el que server-genera claude.ai/el app), y
(b) un **botoncito "Sugerir nombre"** que —AVISANDO que cuesta tokens— genere un nombre corto del contenido.
**Matices:** el resumen en inglés ya lo extrae `chats-extract.js` para chats, pero las SESIONES de Claude
Code (`~/.claude/projects/<slug>/*.jsonl`) no traen resumen server-generado → habría que derivarlo del
transcript (primeros/últimos mensajes) o llamar a un modelo (de ahí el "cuesta tokens" + botón opt-in).
Decidir la fuente del resumen. **Dónde toca:** `sessions-extract.js` (exponer más contexto por sesión) +
el diálogo de rename (mostrar resumen + botón sugerir) en las 3 GUIs. Emparenta con el rename ya hecho (c/d).

## [2026-07-10] Mover sesiones entre slugs — CON TODO lo que conlleva
**Qué:** desde Proyectos/Chats, **mover una sesión** de un slug a otro. unjordi (2026-07-11) lo quiere
**completo**: no solo el `.jsonl`, sino **TODO lo que conlleva** — la **transcripción**, las **memorias
específicas de esa sesión** (si las hay), y su **estadística de consumo de tokens** (que se re-atribuya al
slug destino).

**Por qué:** si arrancaste una sesión en el dir/slug equivocado (la lección "inicia la sesión DENTRO del
repo"), queda archivada mal; re-archivarla debe llevarse TODO su rastro al slug correcto.

**Matices / retos (decisión de diseño pendiente):**
- `.jsonl` = `sessionId`; el **cwd vive DENTRO del transcript** y `claude --resume <id>` lo usa. Mover el
  archivo re-agrupa en el widget PERO no cambia el cwd → el resume seguiría en el cwd original salvo que se
  reescriba el cwd en el transcript (riesgoso: tocar el .jsonl de Claude Code).
- **La estadística de tokens** la calcula ccusage por proyecto/slug leyendo los transcripts → al mover el
  `.jsonl` al otro slug-dir, ccusage ya lo re-atribuye SOLO (no hay que tocar nada aparte); verificar.
- **Memorias específicas de sesión:** hoy la memoria es por-REPO (`.claude/memory/`), no por-sesión; si se
  quiere memoria por-sesión movible, es un concepto nuevo a definir.
- **Alcance:** (a) mover archivo = re-categoriza en widget + re-atribuye tokens; (b) además reescribir cwd
  para re-targetear `--resume`. Empezar por (a) con la advertencia; evaluar (b).
- **Dónde toca:** `sessions-extract.js` + acción "mover a…" en la UI (3 GUIs).
