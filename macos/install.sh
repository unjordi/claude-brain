#!/usr/bin/env bash
# Install the macOS Claude Code quota menu-bar app for the current user.
#
#   ./install.sh              # full install (brain + fetch script + launchd agent + app)
#   ./install.sh --no-app     # only the brain + fetch script + launchd agent (headless)
#   ./install.sh --no-gui     # alias of --no-app (skip the menu-bar app)
#   ./install.sh --no-brain   # skip the Claude-Code brain (hooks/norms); only daemon + app
#   ./install.sh --no-ccusage # don't npm-install ccusage; fall back to npx at runtime
#   ./install.sh --no-claude-code # skip auto-installing the Claude Code CLI (the widget measures IT)
#
# This is the macOS MASTER installer for claude-brain: it lays down the shared Claude-Code brain
# (global hooks, delegation-cost governance, skill, norms) AND the quota daemon + optional app.
# Idempotent.

set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
FETCH_SRC="$ROOT/bin/claude-brain-fetch"
PLIST_SRC="$ROOT/launchd/io.github.unjordi.claude-brain.plist"
LABEL="io.github.unjordi.claude-brain"
BRAIN_INSTALLER="$ROOT/../brain/install-brain.sh"

FETCH_DEST="$HOME/.local/bin/claude-brain-fetch"
PLIST_DEST="$HOME/Library/LaunchAgents/$LABEL.plist"
# Config del widget: con el rebrand COMPLETO (2026-07) pasó a ~/.config/claude-brain (el código lee
# de ahí). "Borra el previo por completo": NO se migra la config vieja; se instala limpia (defaults).
LIMITS_DEFAULT="$HOME/.config/claude-brain/limits.env"
APPS_DIR="$HOME/Applications"
STATE_FILE="$HOME/Library/Caches/claude-brain/state.json"

SKIP_APP=0
SKIP_CCUSAGE=0
SKIP_BRAIN=0
SKIP_CLAUDE_CODE=0
for arg in "$@"; do
  case "$arg" in
    --no-app)         SKIP_APP=1 ;;
    --no-gui)         SKIP_APP=1 ;;
    --no-brain)       SKIP_BRAIN=1 ;;
    --no-ccusage)     SKIP_CCUSAGE=1 ;;
    --no-claude-code) SKIP_CLAUDE_CODE=1 ;;
    *) echo "unknown arg: $arg" >&2; exit 2 ;;
  esac
done

# --- "Borra el previo por completo" (regla 2026-07-15) -----------------------------------------
# El rebrand claude-quota -> claude-brain NO migra ni conserva nada del install viejo: lo ELIMINA y
# reinstala limpio. Idempotente y fail-safe: si nada viejo existe, cada paso es un no-op silencioso.
OLD_LABEL="io.github.unjordi.claude-quota"
OLD_PLIST="$HOME/Library/LaunchAgents/$OLD_LABEL.plist"
OLD_FETCH="$HOME/.local/bin/claude-quota-fetch"
OLD_APP="$HOME/Applications/Claude Quota.app"
OLD_CACHE="$HOME/Library/Caches/claude-quota"
OLD_CONFIG="$HOME/.config/claude-quota"
echo "==> Eliminando cualquier instalación previa 'claude-quota' (install limpio)"
# 1) Baja y elimina el LaunchAgent viejo (que no queden 2 daemons).
launchctl bootout "gui/$(id -u)/$OLD_LABEL" 2>/dev/null || true
launchctl unload "$OLD_PLIST" 2>/dev/null || true
rm -f "$OLD_PLIST" "$OLD_FETCH"
# 2) Cierra y borra la app vieja (que no queden 2 apps en la barra).
osascript -e 'tell application "Claude Quota" to quit' 2>/dev/null || true
pkill -f "Claude Quota.app/Contents/MacOS/ClaudeQuota" 2>/dev/null || true
rm -rf "$OLD_APP"
# 3) Borra el cache y la config VIEJOS por completo (no migramos: se regeneran limpios).
rm -rf "$OLD_CACHE" "$OLD_CONFIG"

# Asegura que ~/.local/bin (donde viven el fetch y, típicamente, el CLI `claude`) esté en el PATH,
# en zsh Y bash (macOS default es zsh, pero no asumas). Idempotente por marcador; crea el rc si falta.
# Lo aplica también a ESTE proceso para que los pasos siguientes vean lo recién instalado.
ensure_path_local_bin() {
  local marker="# claude-brain: ~/.local/bin en el PATH (claude, claude-brain-fetch)"
  local block
  printf -v block '\n%s\ncase ":$PATH:" in *":$HOME/.local/bin:"*) ;; *) export PATH="$HOME/.local/bin:$PATH" ;; esac\n' "$marker"
  local f
  for f in "$HOME/.zshrc" "$HOME/.bashrc" "$HOME/.bash_profile"; do
    if [[ -e "$f" ]] && grep -qF "$marker" "$f" 2>/dev/null; then continue; fi
    printf '%s' "$block" >> "$f"
  done
  case ":$PATH:" in *":$HOME/.local/bin:"*) ;; *) export PATH="$HOME/.local/bin:$PATH" ;; esac
}

if [[ "$SKIP_BRAIN" -eq 0 ]]; then
  if [[ -f "$BRAIN_INSTALLER" ]]; then
    echo "==> Installing the Claude-Code brain (global hooks, delegation-cost governance, norms)"
    bash "$BRAIN_INSTALLER"
  else
    echo "==> (brain installer not found at $BRAIN_INSTALLER — skipping)"
  fi
fi

echo "==> Checking prerequisites"
need() { command -v "$1" >/dev/null 2>&1 || { echo "missing: $1" >&2; exit 1; }; }
need jq
if [[ "$SKIP_APP" -eq 0 ]]; then
  need swift
fi
# rsvg-convert (librsvg): rasteriza el SVG del ícono (app + login item del daemon). Opcional pero
# recomendado; sin él, el ícono no se (re)genera y queda el genérico.
if ! command -v rsvg-convert >/dev/null 2>&1; then
  if command -v brew >/dev/null 2>&1; then echo "==> Instalando librsvg (para el ícono de Claude Brain)"; brew install librsvg || true
  else echo "warn: falta rsvg-convert (brew install librsvg) — el ícono no se (re)generará"; fi
fi

echo "==> Ensuring ccusage is available"
if command -v ccusage >/dev/null 2>&1; then
  echo "    already present ($(command -v ccusage))"
elif [[ "$SKIP_CCUSAGE" -eq 1 ]]; then
  if command -v npx >/dev/null 2>&1; then
    echo "    --no-ccusage set; will fall back to 'npx -y ccusage@latest' at runtime"
  else
    echo "missing: ccusage and npx (need one); install Node.js or drop --no-ccusage" >&2
    exit 1
  fi
elif command -v npm >/dev/null 2>&1; then
  echo "    installing globally via npm"
  npm i -g ccusage
else
  echo "missing: npm (needed to install ccusage); install Node.js or pass --no-ccusage if you have npx" >&2
  exit 1
fi

echo "==> Installing fetch script -> $FETCH_DEST"
install -d "$(dirname "$FETCH_DEST")"
install -m 0755 "$FETCH_SRC" "$FETCH_DEST"

# chats-extract.js / sessions-extract.js / session-move.js junto al fetch (el fetch corre los
# extractores con node -> chats.json / sessions.json; session-move.js lo invoca la GUI al "Mover a…").
CHATS_SRC="$ROOT/../bin/chats-extract.js"
[[ -f "$CHATS_SRC" ]] && install -m 0755 "$CHATS_SRC" "$(dirname "$FETCH_DEST")/chats-extract.js"
SESSIONS_SRC="$ROOT/../bin/sessions-extract.js"
[[ -f "$SESSIONS_SRC" ]] && install -m 0755 "$SESSIONS_SRC" "$(dirname "$FETCH_DEST")/sessions-extract.js"
SESSIONMOVE_SRC="$ROOT/../bin/session-move.js"
[[ -f "$SESSIONMOVE_SRC" ]] && install -m 0755 "$SESSIONMOVE_SRC" "$(dirname "$FETCH_DEST")/session-move.js"

# Ícono del daemon en "Elementos de inicio": claude-brain-fetch es un script pelón → macOS le pone el
# genérico "exec". Le incrustamos el ícono de Claude Brain como ícono CUSTOM del archivo vía
# NSWorkspace.setIcon (set-icon.swift), reusando AppIcon.icns (trae la variante chica nítida en 16/32).
# Fail-safe: sin swift/rsvg o sin icns, se salta (el daemon corre igual, solo sin ícono bonito).
ICNS="$ROOT/build/AppIcon.icns"
bash "$ROOT/make-icon.sh" >/dev/null 2>&1 || true   # regenera SIEMPRE desde el SVG (no reusar un .icns rancio)
if [[ -f "$ICNS" && -f "$ROOT/set-icon.swift" ]] && command -v swift >/dev/null 2>&1; then
  if swift "$ROOT/set-icon.swift" "$ICNS" "$FETCH_DEST" 2>/dev/null; then
    echo "    ícono de Claude Brain incrustado en el daemon (login item)"
  fi
fi

# --- CLI `claude` + PATH (el widget MIDE a claude; sin él no hay qué medir) --------------------
# Espeja la lógica de install.ps1 (fix #67, Windows): si `claude` no está en el PATH pero YA existe
# en ~/.local/bin (caso real de Felipe), solo hay que exponer el PATH; si no existe, se instala con
# el instalador nativo (mismo origen que claude.ai/install.ps1 de Windows). Sáltalo con --no-claude-code.
if [[ "$SKIP_CLAUDE_CODE" -eq 0 ]]; then
  if command -v claude >/dev/null 2>&1; then
    echo "==> claude ya está en el PATH ($(command -v claude))"
  elif [[ -x "$HOME/.local/bin/claude" ]]; then
    echo "==> claude está en ~/.local/bin pero fuera del PATH — lo expongo (ver abajo)"
  else
    echo "==> Instalando el CLI de Claude Code (instalador nativo)"
    curl -fsSL https://claude.ai/install.sh | bash \
      || echo "    no pude instalarlo automáticamente; hazlo a mano: curl -fsSL https://claude.ai/install.sh | bash"
  fi
fi
echo "==> Asegurando ~/.local/bin en el PATH (zsh + bash)"
ensure_path_local_bin

if [[ ! -f "$LIMITS_DEFAULT" ]]; then
  echo "==> Seeding default limits at $LIMITS_DEFAULT"
  install -d "$(dirname "$LIMITS_DEFAULT")"
  cat > "$LIMITS_DEFAULT" <<'EOF'
# FALLBACK calibration — only used when the OAuth usage endpoint is
# unreachable (offline, or no Claude Code credentials in the Keychain). When
# the OAuth token is available the widget reads the exact /usage percentages
# and these caps are ignored.
# After editing, reload the agent:
#   launchctl kickstart -k gui/$(id -u)/io.github.unjordi.claude-brain
#
# Basis is API-EQUIVALENT COST (in USD), not raw tokens — cache-read tokens
# dominate raw counts and Anthropic weights them ~0.1x. Calibrate:
#   CAP = (the popover's "$ used") / (the /usage fraction)
# Rough starting points (eyeballed against /usage on Max 20x):
#   Pro     : FIVE_HOUR_CAP_USD=2.5  WEEKLY_CAP_USD=250
#   Max 5x  : FIVE_HOUR_CAP_USD=11   WEEKLY_CAP_USD=1200
#   Max 20x : FIVE_HOUR_CAP_USD=45   WEEKLY_CAP_USD=4800
FIVE_HOUR_CAP_USD=45
WEEKLY_CAP_USD=4800
WARN_PCT=60
CRIT_PCT=85

# (e) Sync entre máquinas (opt-in): comparte un snapshot de uso vía una carpeta que tu nube ya
# replica, y el widget muestra un toggle "esta máquina / todas". "auto" autodetecta Google Drive;
# o pon una ruta explícita. Ausente/vacío = off (100% local, no sube nada).
# SYNC_DIR=auto
EOF
fi

echo "==> Installing launchd agent -> $PLIST_DEST"
install -d "$(dirname "$PLIST_DEST")"
sed "s#__FETCH__#$FETCH_DEST#g" "$PLIST_SRC" > "$PLIST_DEST"

echo "==> (Re)loading launchd agent"
launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
launchctl bootstrap "gui/$(id -u)" "$PLIST_DEST"
launchctl kickstart -k "gui/$(id -u)/$LABEL" || true

echo "==> Priming cache with one run"
sleep 2
if [[ -f "$STATE_FILE" ]]; then
  echo "    state.json written:"
  jq -c '{status, five: .five_hour.percent, wk: .weekly.percent}' "$STATE_FILE" | sed 's/^/    /'
else
  echo "    (no state.json yet — check /tmp/claude-brain.err.log)"
fi

if [[ "$SKIP_APP" -eq 0 ]]; then
  echo "==> Building app bundle"
  APP="$("$ROOT/make-app.sh")"
  install -d "$APPS_DIR"
  rm -rf "$APPS_DIR/$(basename "$APP")"
  cp -R "$APP" "$APPS_DIR/"
  INSTALLED_APP="$APPS_DIR/$(basename "$APP")"
  echo "    installed -> $INSTALLED_APP"
  echo "==> Launching"
  open "$INSTALLED_APP"
fi

cat <<EOF

Done.

The Claude-Code brain is installed globally (hooks + delegation-cost governance + norms in
  ~/.claude). See ../README.md; re-run any time (idempotent). Skip it with --no-brain.

Next steps:
  - Look for the colored % pill in your menu bar (top-right). Click it for the breakdown.
  - Tune caps in: $LIMITS_DEFAULT
  - To launch at login: System Settings -> General -> Login Items -> add "Claude Brain Widget".

Debug:
  launchctl print gui/$(id -u)/$LABEL | grep -E 'state|last exit'
  cat /tmp/claude-brain.err.log
  jq . "$STATE_FILE"
EOF
