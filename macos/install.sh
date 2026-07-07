#!/usr/bin/env bash
# Install the macOS Claude Code quota menu-bar app for the current user.
#
#   ./install.sh              # full install (brain + fetch script + launchd agent + app)
#   ./install.sh --no-app     # only the brain + fetch script + launchd agent (headless)
#   ./install.sh --no-gui     # alias of --no-app (skip the menu-bar app)
#   ./install.sh --no-brain   # skip the Claude-Code brain (hooks/norms); only daemon + app
#   ./install.sh --no-ccusage # don't npm-install ccusage; fall back to npx at runtime
#
# This is the macOS MASTER installer for claude-brain: it lays down the shared Claude-Code brain
# (global hooks, delegation-cost governance, skill, norms) AND the quota daemon + optional app.
# Idempotent.

set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
FETCH_SRC="$ROOT/bin/claude-quota-fetch"
PLIST_SRC="$ROOT/launchd/io.github.unjordi.claude-quota.plist"
LABEL="io.github.unjordi.claude-quota"
BRAIN_INSTALLER="$ROOT/../brain/install-brain.sh"

FETCH_DEST="$HOME/.local/bin/claude-quota-fetch"
PLIST_DEST="$HOME/Library/LaunchAgents/$LABEL.plist"
LIMITS_DEFAULT="$HOME/.config/claude-quota/limits.env"
APPS_DIR="$HOME/Applications"
STATE_FILE="$HOME/Library/Caches/claude-quota/state.json"

SKIP_APP=0
SKIP_CCUSAGE=0
SKIP_BRAIN=0
for arg in "$@"; do
  case "$arg" in
    --no-app)      SKIP_APP=1 ;;
    --no-gui)      SKIP_APP=1 ;;
    --no-brain)    SKIP_BRAIN=1 ;;
    --no-ccusage)  SKIP_CCUSAGE=1 ;;
    *) echo "unknown arg: $arg" >&2; exit 2 ;;
  esac
done

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

if [[ ! -f "$LIMITS_DEFAULT" ]]; then
  echo "==> Seeding default limits at $LIMITS_DEFAULT"
  install -d "$(dirname "$LIMITS_DEFAULT")"
  cat > "$LIMITS_DEFAULT" <<'EOF'
# FALLBACK calibration — only used when the OAuth usage endpoint is
# unreachable (offline, or no Claude Code credentials in the Keychain). When
# the OAuth token is available the widget reads the exact /usage percentages
# and these caps are ignored.
# After editing, reload the agent:
#   launchctl kickstart -k gui/$(id -u)/io.github.unjordi.claude-quota
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
  echo "    (no state.json yet — check /tmp/claude-quota.err.log)"
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
  - To launch at login: System Settings -> General -> Login Items -> add "Claude Quota".

Debug:
  launchctl print gui/$(id -u)/$LABEL | grep -E 'state|last exit'
  cat /tmp/claude-quota.err.log
  jq . "$STATE_FILE"
EOF
