#!/usr/bin/env bash
# Regenera windows/src/ClaudeBrain/ClaudeBrain.ico desde los SVG maestros (assets/icon.svg +
# icon-small.svg). Es el ícono de la APP/exe (ventana, barra de tareas, Agregar/Quitar programas);
# el ícono VIVO del tray lo dibuja TrayIconRenderer.cs en código (barras de cuota), no este .ico.
#
# Empaca un .ico multi-tamaño PNG-embedded (válido Vista+): 16/32 del arte chico (asterisco grueso,
# lee nítido) y 48/64/128/256 del arte grande (con detalle). NO dependemos de ImageMagick: rsvg-convert
# rasteriza y python empaca. Espejo Windows de macos/make-icon.sh.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BIG="$ROOT/assets/icon.svg"
SMALL="$ROOT/assets/icon-small.svg"
OUT="$ROOT/windows/src/ClaudeBrain/ClaudeBrain.ico"

command -v rsvg-convert >/dev/null 2>&1 || { echo "make-ico: falta rsvg-convert (brew install librsvg / apt install librsvg2-bin)" >&2; exit 1; }
command -v python3 >/dev/null 2>&1 || { echo "make-ico: falta python3" >&2; exit 1; }
[ -f "$BIG" ] && [ -f "$SMALL" ] || { echo "make-ico: faltan los SVG en $ROOT/assets" >&2; exit 1; }

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
render() { rsvg-convert -w "$2" -h "$2" "$1" -o "$TMP/$2.png"; }
render "$SMALL" 16
render "$SMALL" 32
render "$BIG"   48
render "$BIG"   64
render "$BIG"   128
render "$BIG"   256

python3 - "$OUT" "$TMP" 16 32 48 64 128 256 <<'PY'
import sys, struct
out, tmp, *sizes = sys.argv[1:]
sizes = [int(s) for s in sizes]
blobs = []
for s in sizes:
    with open(f"{tmp}/{s}.png", "rb") as f:
        blobs.append((s, f.read()))
# ICONDIR (6) + N * ICONDIRENTRY (16), luego los PNG.
n = len(blobs)
header = struct.pack("<HHH", 0, 1, n)   # reserved=0, type=1 (icon), count
offset = 6 + 16 * n
entries, data = b"", b""
for s, blob in blobs:
    b = 0 if s >= 256 else s            # 0 == 256 en el formato ICO
    entries += struct.pack("<BBBBHHII", b, b, 0, 0, 1, 32, len(blob), offset)
    data += blob
    offset += len(blob)
with open(out, "wb") as f:
    f.write(header + entries + data)
print(f"make-ico: {out} ({n} tamaños: {sizes})")
PY
