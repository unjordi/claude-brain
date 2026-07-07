#!/usr/bin/env bash
# Install the Claude Code quota widget for the current user.
#
#   ./install.sh              # full install (brain + fetch script + systemd + plasmoid)
#   ./install.sh --reinstall  # uninstall plasmoid first, then reinstall
#   ./install.sh --no-plasmoid # only the brain + fetch script + systemd timer (no GUI)
#   ./install.sh --no-gui      # alias of --no-plasmoid (skip the desktop widget)
#   ./install.sh --no-brain    # skip the Claude-Code brain (hooks/norms); only daemon + GUI
#
# This is the MASTER installer for claude-brain: it lays down the shared Claude-Code brain
# (global hooks, delegation-cost governance, skill, norms) AND the quota daemon + optional GUI.
# Idempotent.

set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
BIN_SRC="$ROOT/src/bin/claude-quota-fetch"
UNIT_SRC="$ROOT/src/systemd"
PLASMOID_SRC="$ROOT/src/plasmoid"
PLASMOID_ID="io.github.unjordi.claude-quota-widget"
BRAIN_INSTALLER="$ROOT/brain/install-brain.sh"

BIN_DEST="$HOME/.local/bin/claude-quota-fetch"
UNIT_DEST="$HOME/.config/systemd/user"
LIMITS_DEFAULT="$HOME/.config/claude-quota/limits.env"

REINSTALL=0
SKIP_PLASMOID=0
SKIP_CCUSAGE=0
SKIP_BRAIN=0
for arg in "$@"; do
  case "$arg" in
    --reinstall)    REINSTALL=1 ;;
    --no-plasmoid)  SKIP_PLASMOID=1 ;;
    --no-gui)       SKIP_PLASMOID=1 ;;
    --no-brain)     SKIP_BRAIN=1 ;;
    --no-ccusage)   SKIP_CCUSAGE=1 ;;
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
need systemctl
need jq
if [[ "$SKIP_PLASMOID" -eq 0 ]]; then
  need kpackagetool6
fi

echo "==> Ensuring ccusage is installed"
if command -v ccusage >/dev/null 2>&1; then
  echo "    already present ($(command -v ccusage))"
elif [[ "$SKIP_CCUSAGE" -eq 1 ]]; then
  if command -v npx >/dev/null 2>&1; then
    echo "    --no-ccusage set; will fall back to 'npx -y ccusage@latest' at runtime"
  else
    echo "missing: ccusage and npx (need one); rerun without --no-ccusage or install npm" >&2
    exit 1
  fi
elif command -v npm >/dev/null 2>&1; then
  echo "    installing globally via npm"
  npm i -g ccusage
else
  echo "missing: npm (needed to install ccusage); install Node.js or pass --no-ccusage if you have npx" >&2
  exit 1
fi

echo "==> Installing fetch script -> $BIN_DEST"
install -D -m 0755 "$BIN_SRC" "$BIN_DEST"

if [[ ! -f "$LIMITS_DEFAULT" ]]; then
  echo "==> Seeding default limits at $LIMITS_DEFAULT"
  install -d "$(dirname "$LIMITS_DEFAULT")"
  cat > "$LIMITS_DEFAULT" <<'EOF'
# FALLBACK calibration — only used when the OAuth usage endpoint is
# unreachable (offline, or no ~/.claude/.credentials.json). When Claude Code's
# OAuth token is available the widget reads the exact /usage percentages and
# these caps are ignored.
# After editing, run: systemctl --user restart claude-quota.service
#
# Basis is API-EQUIVALENT COST (USD), not raw tokens — cache-read tokens
# dominate raw counts and Anthropic weights them ~0.1x. Calibrate:
#   CAP = (the popup's "$ used") / (the /usage fraction)
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

echo "==> Installing systemd user units -> $UNIT_DEST"
install -D -m 0644 "$UNIT_SRC/claude-quota.service" "$UNIT_DEST/claude-quota.service"
install -D -m 0644 "$UNIT_SRC/claude-quota.timer"   "$UNIT_DEST/claude-quota.timer"

echo "==> Reloading systemd user manager"
systemctl --user daemon-reload

echo "==> Enabling timer"
systemctl --user enable --now claude-quota.timer

echo "==> Priming cache with one run"
systemctl --user start claude-quota.service || true
sleep 1
if [[ -f "$HOME/.cache/claude-quota/state.json" ]]; then
  echo "    state.json written:"
  jq -c '{status, five: .five_hour.percent, wk: .weekly.percent}' \
     "$HOME/.cache/claude-quota/state.json" | sed 's/^/    /'
else
  echo "    (no state.json yet — check: journalctl --user -u claude-quota.service)"
fi

if [[ "$SKIP_PLASMOID" -eq 0 ]]; then
  if [[ "$REINSTALL" -eq 1 ]]; then
    echo "==> Removing existing plasmoid (if any)"
    kpackagetool6 -t Plasma/Applet -r "$PLASMOID_ID" 2>/dev/null || true
  fi
  echo "==> Installing plasmoid"
  if kpackagetool6 -t Plasma/Applet -l 2>/dev/null | grep -q "^${PLASMOID_ID}$"; then
    kpackagetool6 -t Plasma/Applet -u "$PLASMOID_SRC"
  else
    kpackagetool6 -t Plasma/Applet -i "$PLASMOID_SRC"
  fi
fi

cat <<EOF

Done.

The Claude-Code brain is installed globally (hooks + delegation-cost governance + norms in
  ~/.claude). See README.md; re-run any time (idempotent). Skip it with --no-brain.

Next steps:
  - Right-click your Plasma panel -> Add or Manage Widgets -> search "Claude Code Quota"
  - Drag it onto the panel (or into the system tray slot).
  - Hover for the breakdown; tune caps in: $LIMITS_DEFAULT

Debug:
  systemctl --user status claude-quota.timer
  journalctl --user -u claude-quota.service -n 20
  cat ~/.cache/claude-quota/state.json | jq .
EOF
