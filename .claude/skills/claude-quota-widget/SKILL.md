---
name: claude-quota-widget
description: >
  Trabaja el widget de límites de uso de Claude de unjordi (sesión 5h + semanal,
  como "Tus límites de uso" de claude.ai) que vive en su repo propio
  github.com/unjordi/claude-quota-widget (clonado en ~/code/claude-quota-widget).
  Úsalo para instalarlo/actualizarlo en CachyOS/KDE, macOS o la VM de Windows,
  restylearlo (look del de la KDE Store: tarjeta naranja + indicador de bandeja de
  2 filas con mini-barras), tocar la fuente de datos (endpoint OAuth /usage +
  ccusage), arreglar el icono/empalme en la bandeja, o construir la versión que
  falta (Windows). Fork MIT de github.com/fuziontech/claude-quota-widget.
---

# claude-quota-widget — widget de límites de uso de Claude (multi-OS)

Fork de `github.com/fuziontech/claude-quota-widget` (MIT) restyleado al look del de
la KDE Store (`github.com/FelixDes/claude-kde-usage-widget`), conservando el costo
"$ API equiv" que FelixDes no trae. Detalle e historia: memoria [[claude-quota-widget]].

## Dónde vive (importante)
- **Canónico (desde 2026-06-30):** repo propio **`github.com/unjordi/claude-quota-widget`**
  (fork público de fuziontech), clonado en `~/code/claude-quota-widget`. **Fuente de verdad
  única:** código + cerebro de Claude (`.claude/memory` y `.claude/skills`) viajan juntos por
  el repo. **Edita siempre aquí.** A otra máquina (MacBook): `git clone` + `bash
  .claude/bootstrap-claude.sh` una vez. `origin`=tu fork, `upstream`=fuziontech.
- **Ya NO vive en `scripts/`** (estaba ahí + Drive hasta el 2026-06-30; se extrajo para no
  duplicar). Si ves una copia en `scripts/claude-quota-widget/`, es obsoleta.
- Rebrandeado al namespace **`io.github.unjordi.*`**. LICENSE MIT original (copyright
  fuziontech) intacta — no borrarla; el crédito se conserva.

## Fuente de datos (las 3 plataformas la comparten)
- Endpoint **`https://api.anthropic.com/api/oauth/usage`** (el mismo de `/usage` de
  Claude Code), token OAuth de `~/.claude/.credentials.json`. Es **read-only, no gasta
  cuota**. Da los **%** exactos (todas las superficies) y los resets reales.
- El **$** es API-equivalente estimado por **ccusage** (transcripts LOCALES de esa
  máquina) → se etiqueta **"(API equiv local)"** para que no parezca roto cuando
  coincide con el % (p. ej. el primer día de la semana, ver memoria).
- Pipeline: un script `fetch` (bash en Linux/mac) corre cada 5 min (systemd timer /
  launchd) y escribe `~/.cache/claude-quota/state.json` (límites) y
  `~/.cache/claude-quota/stats.json` (stats); la UI solo lee esos caches.
- **`stats.json`** alimenta las pestañas Resumen/Modelos (todo LOCAL de esa máquina):
  - `days[]` / `models[]` salen de **`ccusage daily --json --breakdown`** (¡el `--json`
    es obligatorio o devuelve tabla y rompe el jq!).
  - Sesiones / Mensajes / Hora pico salen de parsear los transcripts crudos
    `~/.claude/projects/**/*.jsonl` con **grep/awk (NO jq**, pesan ~cientos de MB):
    sesiones = nº de `.jsonl`; mensajes = líneas `"type":"user|assistant"`; hora pico =
    histograma de `"timestamp"` ajustado a hora local (`date +%z`, ojo octal: usar `10#`).

## Instalar / actualizar por OS
- **CachyOS / KDE Plasma 6:** `cd ~/code/claude-quota-widget`
  - Instalar/actualizar: `kpackagetool6 -t Plasma/Applet -i src/plasmoid`
    (o `-u` para upgrade). Recargar: `kquitapp6 plasmashell && (kstart plasmashell &)`.
  - **ccusage:** `pkexec npm i -g ccusage` (npm prefix=/usr necesita root); si el
    binario nativo queda sin +x: `pkexec chmod +x /usr/lib/node_modules/ccusage/node_modules/@ccusage/ccusage-linux-x64/bin/ccusage`.
  - **Cambiar el `Id` en metadata.json obliga a quitar y re-agregar** el widget.
  - **Iteración en vivo — gotchas (importantes):**
    - `kpackagetool6 -u` **NO reemplaza los archivos si `KPlugin.Version` no cambió**
      (ni `-r`+`-i` fue fiable). Para ver tus cambios al iterar: **`command cp -rf
      src/plasmoid/contents/. ~/.local/share/plasma/plasmoids/<id>/contents/`** y luego
      `kquitapp6 plasmashell && (kstart plasmashell &)`. Para release, **bumpear Version**.
    - El **`cp` de unjordi está aliaseado a `cp -i`** (pregunta y sin TTY responde "no");
      usar **`command cp`**.
    - **`plasmoidviewer` cachea/ignora el default de propiedades** (ej. `currentTab`) y
      `spectacle -b -n -a/-f` en Wayland es inconsistente → para verificar pestañas
      distintas, **mejor en vivo en el panel (clic) y pedir screenshot a unjordi**.
- **macOS:** `cd ~/code/claude-quota-widget/macos && ./install.sh`
  (necesita Xcode CLT `xcode-select --install`, `jq` via brew, Node). App de barra de
  menú en Swift + agente launchd. Bundle `io.github.unjordi.claude-quota`.
- **Windows (VM):** NO existe upstream (fuziontech es solo KDE+macOS). Hay que
  **construir uno nuevo**: misma lógica (leer `~/.claude/.credentials.json` o
  `%USERPROFILE%\.claude\.credentials.json`, pegar al endpoint OAuth, parsear igual),
  UI sugerida = app de bandeja .NET/WinForms autoarrancable. Para distribuirla por
  GitHub con auto-update/WinForms hay una skill `winturbo-distro` en el repo scripts/
  (no viajó a este repo).

## Convenciones de diseño (look FelixDes + paridad)
- Acento **naranja** `#e8884a`; escala a rojo `#dc3545` solo **>90%** (aviso de throttle).
- Popup = **3 pestañas con riel vertical a la IZQUIERDA** (StackLayout): **Límites**
  (sesión 5h + semanal), **Resumen** (9 tarjetas 3×3 + heatmap tipo GitHub de actividad)
  y **Modelos** (barras apiladas por día, color por modelo, + tabla con in/out y %).
  Cada modelo tiene color fijo (`modelPalette`); `prettyModel()` formatea
  `claude-opus-4-8`→"Opus 4.8". Tarjeta = componente `StatCard`.
- Etiquetas en **español**, footer "datos reales · ⟳ 5 min · act. …".
- Indicador de panel/bandeja = **2 filas** `5h / 7d` con mini-barra + % + `⟳reset`.
- Icono del plasmoide: **`speedometer`** (no `applications-development`, que sale martillo).
- Si algún día se quiere paleta Nord en vez de naranja, ver memoria [[kde-tema-opaco]]
  (la mecánica de propagar un look quedó en la skill `paridad-terminal` del repo scripts/,
  que no viajó aquí).

## Gotchas de la bandeja (system tray) — ya resueltos, NO regresarlos
- La mini-barra necesita **`Layout.minimumWidth`** (no solo `preferredWidth`) o
  colapsa a ancho 0 y desaparece.
- La `compactRepresentation` debe declarar **`Layout.minimumWidth/preferredWidth/maximumWidth`**
  (no basta `implicitWidth`) o el system tray no le reserva ancho y **se empalma** con
  los íconos vecinos.

## Git (repo propio github.com/unjordi/claude-quota-widget)
Aplica la NORMA de unjordi: nunca push directo a `main`; ramita `feat/fix/chore/…` desde
`main` → PR (`gh pr create --repo unjordi/claude-quota-widget --base main`) → merge
server-side (con 1–3 devs, merge al instante; `gh pr merge --merge`). Si la rama activa tiene
WIP sin commitear, usa **git worktree**. `upstream` (fuziontech) solo para jalar mejoras o
PR de vuelta al original.
