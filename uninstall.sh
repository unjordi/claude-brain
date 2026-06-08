#!/usr/bin/env bash
# Remove the Claude Code quota widget. Idempotent.
#
#   ./uninstall.sh            # remove everything
#   ./uninstall.sh --keep-cfg # keep ~/.config/claude-quota/limits.env

set -euo pipefail

PLASMOID_ID="com.jamesh.claudequota"
KEEP_CFG=0
for arg in "$@"; do
  case "$arg" in
    --keep-cfg) KEEP_CFG=1 ;;
    *) echo "unknown arg: $arg" >&2; exit 2 ;;
  esac
done

echo "==> Stopping and disabling timer"
systemctl --user disable --now claude-quota.timer 2>/dev/null || true

echo "==> Removing systemd user units"
rm -f "$HOME/.config/systemd/user/claude-quota.timer"
rm -f "$HOME/.config/systemd/user/claude-quota.service"
systemctl --user daemon-reload || true

echo "==> Removing fetch script"
rm -f "$HOME/.local/bin/claude-quota-fetch"

echo "==> Removing plasmoid"
if command -v kpackagetool6 >/dev/null 2>&1; then
  kpackagetool6 -t Plasma/Applet -r "$PLASMOID_ID" 2>/dev/null || true
fi

echo "==> Removing cache"
rm -rf "$HOME/.cache/claude-quota"

if [[ "$KEEP_CFG" -eq 0 ]]; then
  echo "==> Removing config"
  rm -rf "$HOME/.config/claude-quota"
fi

echo "Done."
