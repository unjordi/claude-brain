#!/usr/bin/env bash
# Generate macos/build/AppIcon.icns from the shared SVG masters (assets/icon.svg + icon-small.svg).
#
# Identidad "Claude Brain": squircle grafito + cerebro crema + chispa de Claude naranja. El SVG es la
# ÚNICA fuente (texto, versionable); aquí se rasteriza por tamaño y se empaqueta en .icns.
#   - Tamaños GRANDES (>=128): assets/icon.svg (con surcos + chispa fina, se lee con detalle).
#   - Tamaños CHICOS (16/32): assets/icon-small.svg (cerebro simple + chispa gruesa, lee nítido en el
#     login item del daemon y el menú — el arte detallado se volvería un blob a 16px).
# Requiere rsvg-convert (librsvg): brew install librsvg.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
ASSETS="$ROOT/../assets"
BIG="$ASSETS/icon.svg"
SMALL="$ASSETS/icon-small.svg"
BUILD="$ROOT/build"
ICONSET="$BUILD/AppIcon.iconset"
ICNS="$BUILD/AppIcon.icns"

command -v rsvg-convert >/dev/null 2>&1 || { echo "make-icon: falta rsvg-convert (brew install librsvg)" >&2; exit 1; }
[ -f "$BIG" ] && [ -f "$SMALL" ] || { echo "make-icon: faltan los SVG en $ASSETS" >&2; exit 1; }

mkdir -p "$BUILD"
rm -rf "$ICONSET"; mkdir -p "$ICONSET"
render() { rsvg-convert -w "$2" -h "$2" "$1" -o "$ICONSET/$3"; }

# Slots CHICOS (16/32 pt) -> arte simplificado.
render "$SMALL" 16   "icon_16x16.png"
render "$SMALL" 32   "icon_16x16@2x.png"
render "$SMALL" 32   "icon_32x32.png"
render "$SMALL" 64   "icon_32x32@2x.png"
# Slots GRANDES (128 pt+) -> arte con detalle.
render "$BIG"  128  "icon_128x128.png"
render "$BIG"  256  "icon_128x128@2x.png"
render "$BIG"  256  "icon_256x256.png"
render "$BIG"  512  "icon_256x256@2x.png"
render "$BIG"  512  "icon_512x512.png"
render "$BIG"  1024 "icon_512x512@2x.png"

iconutil -c icns "$ICONSET" -o "$ICNS"
echo "make-icon: $ICNS"
