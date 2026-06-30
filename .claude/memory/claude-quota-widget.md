---
name: claude-quota-widget
description: "Widget KDE+macOS de límites de uso de Claude; repo propio github.com/unjordi/claude-quota-widget (fork de fuziontech restyleado al look FelixDes)"
metadata: 
  node_type: memory
  type: project
  originSessionId: f59bc25a-fdde-4d83-80c0-f29da9699946
---

Widget de escritorio open-source que muestra los límites de uso de Claude ("Tus límites de uso" de claude.ai: sesión 5h + semanal).

**Ubicación canónica (desde 2026-06-30):** repo propio **`github.com/unjordi/claude-quota-widget`** (fork público de fuziontech), clonado en `~/code/claude-quota-widget`. Es la **fuente de verdad ÚNICA**: el código y el "cerebro" de Claude (memoria/skills en `.claude/`) viajan juntos por el repo. En otra máquina (la MacBook): clonar el repo y correr `bash .claude/bootstrap-claude.sh` una vez (enlaza la memoria al slug de esa máquina; las skills se autocargan). `origin` = tu fork; `upstream` = fuziontech (para jalar mejoras / eventual PR upstream). **Ya NO vive en `scripts/`** (se extrajo el 2026-06-30 para no duplicar ni dejar rastros que confundan). Antes era al revés: canónico en `scripts/` + Google Drive, y este clon estaba dormido.

**Decisión (2026-06-29):** forkear `github.com/fuziontech/claude-quota-widget` (MIT, KDE Plasma 6 + app macOS Swift, muestra dinero API-equiv vía ccusage, lee endpoint read-only) y darle el LOOK del de la KDE Store `github.com/FelixDes/claude-kde-usage-widget` (más bonito pero solo KDE, sin dinero, y su método QUEMA cuota: hace una petición real por refresh). Base = fuziontech; FelixDes = referencia visual.

**Dato técnico clave:** los datos reales salen del endpoint OAuth `https://api.anthropic.com/api/oauth/usage` (el mismo de `/usage` de Claude Code), autenticando con el token de `~/.claude/.credentials.json`. fuziontech lo lee read-only (no gasta cuota). El % es exacto; el `$` es API-equivalente estimado por ccusage. NO es API pública documentada → puede romperse.

**Estado:** instalado y corriendo en CachyOS (`basis: oauth`, semanal 45% clavado con claude.ai). Popup tipo tarjeta "Claude Limits" + indicador de bandeja de 2 filas con mini-barras. Paleta: **naranja tipo FelixDes** (rojo solo >90%). Icono: **speedometer** (era el martillo `applications-development`, que salía feo en el selector de widgets). Instalado vía `kpackagetool6 -t Plasma/Applet -i/-u <path>/src/plasmoid` (no hay `just`; preview con `plasmoidviewer -a <path>` + spectacle, recargar con `kquitapp6 plasmashell && kstart plasmashell`). ccusage instalado global con pkexec (su binario nativo necesitó `chmod +x`).

**Rebrand a unjordi (PR #67, merged a develop):** Id plasmoide `io.github.unjordi.claude-quota-widget`, bundle/launchd macOS `io.github.unjordi.claude-quota`. Swap de Id en vivo YA hecho (viejo `fuziontech` desinstalado, nuevo instalado) → unjordi debe RE-AGREGAR el widget (tray + escritorio). Authors=unjordi (sin email) + crédito fuziontech. LICENSE MIT original intacta.

**Popup de 3 pestañas (PR #69, 2026-06-29):** riel de pestañas vertical a la IZQUIERDA + StackLayout. (1) **Límites** (lo original). (2) **Resumen**: tarjetas (tokens, días activos, modelo favorito, racha actual/larga, costo) + heatmap tipo GitHub. (3) **Modelos**: barras apiladas por día (color por modelo) + tabla con in/out y %. Datos de un `stats.json` que el `fetch` arma con `ccusage daily --json --breakdown` (LOCAL). **Fase 2 del Resumen LISTA (PR #70):** Sesiones (nº de .jsonl), Mensajes (líneas user/assistant) y Hora pico (histograma de timestamps → hora local −6) se calculan de los transcripts crudos `~/.claude/projects/**/*.jsonl` con grep/awk (no jq, por los ~155 MB; corre ~4s). Resumen quedó en 9 tarjetas 3×3 + heatmap. Confirmado bello en vivo (las 3 tarjetas de fase 2 con datos reales).

**Gotchas de iteración en vivo (me costaron mucho preview):**
- `kpackagetool6 -u <pkg>` **NO reemplaza archivos si `KPlugin.Version` no cambió** (ni `-r`+`-i` fue fiable). Para actualizar el instalado al iterar: **`command cp -rf src/plasmoid/contents/. ~/.local/share/plasma/plasmoids/<id>/contents/`** + recargar plasmashell. Para release real, **bumpear la Version**.
- El **`cp` de unjordi está aliaseado a `cp -i`** → sin TTY responde "no" y no sobrescribe. Usar **`command cp`**.
- **`plasmoidviewer` cachea/ignora el default de propiedades** (ej. `currentTab`): mostraba siempre la pestaña 0. Verificar otras pestañas EN VIVO en el panel (clic), no con plasmoidviewer.

**Replicación multi-OS:** macOS YA existe (app Swift de barra de menú en `macos/`, rebrandeada) → en la MacBook: clonar este repo y correr `macos/install.sh` (necesita Xcode CLT, jq, Node). **Windows NO existe upstream** (fuziontech es solo KDE+macOS) → hay que CONSTRUIR uno nuevo (misma lógica: leer `~/.claude/.credentials.json` + endpoint OAuth; UI p.ej. app de bandeja .NET/WinForms). Pendiente.

**El "$ duplicado" NO es bug (verificado 2026-06-29):** five_hour y weekly mostraban el mismo `cost_usd` porque hoy es LUNES (inicio de semana) y el único uso de la semana == el bloque de 5h activo. ccusage weekly buckets: el semanal arranca bajo al inicio de la semana (= solo el bloque de 5h activo) y sube/se separa del bloque de 5h conforme avanza la semana. El código jala bien block vs weekly de fuentes distintas. **Matiz real (no arreglable):** con `basis=oauth` el % es exacto (todas las superficies) pero el `$` lo estima ccusage de transcripts LOCALES de esta máquina → puede subestimar. Idea pendiente: etiquetar `≈ $X (local)` para que no parezca roto.

**Indicador de bandeja (system tray) — 2 gotchas resueltos (2026-06-29):** (1) las mini-barras del pill compacto COLAPSABAN a ancho 0 en la bandeja → la barra necesita `Layout.minimumWidth` (no solo `preferredWidth`). (2) el widget se EMPALMABA con los íconos vecinos → la bandeja/panel reserva espacio de `Layout.minimumWidth/preferredWidth/maximumWidth` de la compactRepresentation, NO de `implicitWidth` solo; sin esos hints, el contenido ancho se desborda sobre el vecino. Etiqueta del $ quedó `(API equiv local)`. unjordi lo tiene EN LA BANDEJA (no en el panel) y así le gusta.

**Pendientes:** ~~verificar pill de 2 filas en vivo~~ (LISTO); ~~rebrandear metadata a unjordi~~ (LISTO); ~~crear fork en GitHub bajo unjordi~~ (LISTO 2026-06-30: `unjordi/claude-quota-widget` público, este repo); construir la versión de **Windows** (no existe upstream); eventual publicación en KDE Store. Si quiere paleta Nord en vez de naranja, ver [[kde-tema-opaco]] (la mecánica de propagación quedó en la skill `paridad-terminal` del repo scripts/, que NO viajó a este repo).
