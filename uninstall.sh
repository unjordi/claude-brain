#!/usr/bin/env bash
# Remove the Claude Code quota widget AND the shared Claude-Code brain. Idempotent.
#
#   ./uninstall.sh            # remove everything (widget + brain)
#   ./uninstall.sh --keep-cfg # keep ~/.config/claude-quota/limits.env
#   ./uninstall.sh --no-brain # remove only the widget; leave the Claude-Code brain installed

set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
BRAIN_UNINSTALLER="$ROOT/brain/uninstall-brain.sh"

PLASMOID_ID="io.github.unjordi.claude-quota-widget"
KEEP_CFG=0
SKIP_BRAIN=0
for arg in "$@"; do
  case "$arg" in
    --keep-cfg) KEEP_CFG=1 ;;
    --no-brain) SKIP_BRAIN=1 ;;
    *) echo "unknown arg: $arg" >&2; exit 2 ;;
  esac
done

if [[ "$SKIP_BRAIN" -eq 0 ]]; then
  if [[ -f "$BRAIN_UNINSTALLER" ]]; then
    echo "==> Removing the Claude-Code brain (global hooks, delegation-cost governance, norms)"
    bash "$BRAIN_UNINSTALLER"
  else
    echo "==> (brain uninstaller not found at $BRAIN_UNINSTALLER — skipping)"
  fi
fi

echo "==> Stopping and disabling timer"
systemctl --user disable --now claude-brain.timer 2>/dev/null || true

echo "==> Removing systemd user units"
rm -f "$HOME/.config/systemd/user/claude-brain.timer"
rm -f "$HOME/.config/systemd/user/claude-brain.service"
systemctl --user daemon-reload || true

echo "==> Removing fetch script"
rm -f "$HOME/.local/bin/claude-brain-fetch"

echo "==> Removing plasmoid"
if command -v kpackagetool6 >/dev/null 2>&1; then
  kpackagetool6 -t Plasma/Applet -r "$PLASMOID_ID" 2>/dev/null || true
fi

echo "==> Removing cache"
rm -rf "$HOME/.cache/claude-brain"

if [[ "$KEEP_CFG" -eq 0 ]]; then
  echo "==> Removing config"
  rm -rf "$HOME/.config/claude-quota"
fi

echo "Done."
