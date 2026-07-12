---
name: cambiar-icono
description: >
  Cambia o regenera el ícono del widget claude-brain (el cerebro + chispa de Claude) en las 3
  plataformas Y el ícono del login item del daemon. Fuente única = SVG; render por plataforma con
  rsvg/iconutil/packer .ico; login item vía NSWorkspace.setIcon. Incluye los gotchas reales
  (regenerar SIEMPRE, no reusar el .icns rancio; NO usar Rez; reventar la caché de íconos).
---

# cambiar-icono — el ícono de Claude Brain en las 3 plataformas + login item

Repo `~/code/claude-quota-widget` (GitHub `unjordi/claude-brain`). El ícono es **cerebro crema + chispa
naranja de Claude sobre squircle grafito**. Identidad establecida el 2026-07-11 (antes era un medidor,
de cuando el widget se llamaba "Claude Quota").

## Fuente ÚNICA: dos SVG (texto, versionable — NO hay binarios de arte en el repo salvo el .ico)
- `assets/icon.svg` — **arte grande** (≥128px): cerebro con surcos + chispa fina de 12 rayos.
- `assets/icon-small.svg` — **variante chica** (≤32px): cerebro simple (sin surcos finos) + chispa
  gruesa de 8 rayos, para que a 16px (login item, menú) lea NÍTIDO y no un blob.

Para cambiar el diseño: edita los SVG, renderiza a PNG para autoevaluar (`rsvg-convert -w 512 icon.svg
-o /tmp/x.png` y míralo), itera. Luego regenera los assets por plataforma (abajo).

## Requisitos
- `rsvg-convert` (librsvg) — rasteriza el SVG. macOS: `brew install librsvg` (el `install.sh` lo mete
  a prereqs). Linux: `librsvg2-bin`.
- `python3` — para empacar el `.ico` de Windows (no dependemos de ImageMagick).
- macOS: `iconutil` + `swift` (vienen con Xcode CLT).

## Regenerar por plataforma
- **macOS (.icns):** `bash macos/make-icon.sh` → rasteriza los SVG en el .iconset (chica en 16/32,
  grande en 128+) y arma `macos/build/AppIcon.icns`. `make-app.sh` lo copia a la `.app`.
- **Linux (plasmoid):** el SVG grande vive en `src/plasmoid/contents/icons/claude-brain.svg` y
  `metadata.json` tiene `"Icon": "claude-brain"`. Si cambias el arte, re-copia `assets/icon.svg` ahí.
- **Windows (.ico):** regenera `windows/src/ClaudeQuota/ClaudeBrain.ico` con el packer: rsvg-convert a
  PNGs (16/32 de la chica, 48/64/128/256 de la grande) → python empaca un .ico multi-tamaño (PNG-
  embedded, válido Vista+). Ver el bloque en la bitácora del 2026-07-11 o reusar el mismo script.

## Login item del daemon (el ícono del `claude-brain-fetch` en "Elementos de inicio")
El daemon es un **script pelón** → macOS le pone el genérico "exec". Se le incrusta el ícono como
**ícono CUSTOM del archivo** vía `macos/set-icon.swift` (que usa `NSWorkspace.setIcon`). Lo hace el
`install.sh` de macOS tras instalar el fetch. Manual:
`swift macos/set-icon.swift macos/build/AppIcon.icns ~/.local/bin/claude-brain-fetch`

## GOTCHAS (aprendidos a la mala el 2026-07-11)
1. **Regenerar SIEMPRE desde el SVG, NO "solo si falta".** `make-app.sh` y el paso de fetch-icon del
   `install.sh` corren `make-icon.sh` incondicionalmente. Si solo regeneraran cuando falta, un
   `build/AppIcon.icns` rancio (el medidor de una versión anterior) se quedaría pegado y se instalaría
   el ícono viejo — bug real que salió en el QA (el login item mostraba el medidor).
2. **NO uses `Rez`/`SetFile`** para el ícono del archivo: dejan el resource fork a medias (286 bytes
   rotos). `NSWorkspace.setIcon` (set-icon.swift) lo escribe bien (fork ~214KB + flag C).
3. **Reventar la caché de íconos** tras cambiarlo, si no macOS muestra el viejo: `killall
   iconservicesagent Dock Finder`; reabre el pane de Login Items / re-loguéate.
4. **Verificar el ícono REAL de un archivo** (no la caché): un swift chiquito con
   `NSWorkspace.shared.icon(forFile:)` → PNG, y míralo. Así se cazó que el fork tenía el medidor.

## Cierre
El diseño lo aprueba unjordi visualmente (es un asset). Build+render verdes = verificado técnicamente,
NO listo. Publica por el flujo de git con la skill `publicar-widget`.
