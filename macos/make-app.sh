#!/usr/bin/env bash
# Build the release binary and assemble ClaudeQuota.app under build/.
# Prints the absolute path to the assembled .app on success.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
APP_NAME="Claude Quota"
APP="$ROOT/build/$APP_NAME.app"

swift build -c release --package-path "$ROOT" >&2
BIN="$(swift build -c release --package-path "$ROOT" --show-bin-path)/ClaudeQuota"

# Generate the app icon (build/AppIcon.icns) if it isn't there yet. Cheap, so
# regenerate when missing; delete build/AppIcon.icns to force a rebuild.
ICNS="$ROOT/build/AppIcon.icns"
if [[ ! -f "$ICNS" ]]; then
    "$ROOT/make-icon.sh" >&2
fi

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/ClaudeQuota"
cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"
cp "$ICNS" "$APP/Contents/Resources/AppIcon.icns"

# Empaqueta el cerebro DENTRO del app para que el botón "Completar/actualizar cerebro global"
# de la pestaña Cerebro pueda correr install-brain.sh sin depender de dónde esté el clon del repo.
if [[ -d "$ROOT/../brain" ]]; then
    rm -rf "$APP/Contents/Resources/brain"
    cp -R "$ROOT/../brain" "$APP/Contents/Resources/brain"
fi

# Versión EMBEBIDA para el autoupdate (winturbo-style): el SHA + la fecha del commit con que se
# buildeó y la ruta del clon, para que la app compare contra GitHub y sepa desde dónde re-jalar.
_sha="$(git -C "$ROOT" rev-parse --short HEAD 2>/dev/null || echo unknown)"
_date="$(git -C "$ROOT" show -s --format=%cI HEAD 2>/dev/null || echo "")"
_repo="$(cd "$ROOT/.." 2>/dev/null && pwd || echo "")"
_branch="$(git -C "$ROOT" rev-parse --abbrev-ref HEAD 2>/dev/null || echo "")"
printf '{"sha":"%s","date":"%s","repo":"%s","branch":"%s"}\n' \
  "$_sha" "$_date" "$_repo" "$_branch" > "$APP/Contents/Resources/version.json"

# Ad-hoc codesign so Gatekeeper/TCC treat it as a stable identity across rebuilds.
codesign --force --sign - "$APP" >&2 2>/dev/null || true

echo "$APP"
