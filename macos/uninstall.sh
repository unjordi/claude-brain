#!/usr/bin/env bash
# Remove the macOS Claude Code quota app, agent, and fetch script.
#
#   ./uninstall.sh            # remove everything (keeps limits.env)
#   ./uninstall.sh --purge    # also remove ~/.config/claude-quota and the cache

set -euo pipefail

LABEL="io.github.unjordi.claude-quota"
FETCH_DEST="$HOME/.local/bin/claude-quota-fetch"
PLIST_DEST="$HOME/Library/LaunchAgents/$LABEL.plist"
APP_DEST="$HOME/Applications/Claude Quota.app"
CONFIG_DIR="$HOME/.config/claude-quota"
CACHE_DIR="$HOME/Library/Caches/claude-quota"

PURGE=0
[[ "${1:-}" == "--purge" ]] && PURGE=1

echo "==> Stopping app"
osascript -e 'tell application "Claude Quota" to quit' 2>/dev/null || true
pkill -f "Claude Quota.app/Contents/MacOS/ClaudeQuota" 2>/dev/null || true

echo "==> Unloading launchd agent"
launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true

echo "==> Removing files"
rm -f "$PLIST_DEST" "$FETCH_DEST"
rm -rf "$APP_DEST"

if [[ "$PURGE" -eq 1 ]]; then
  echo "==> Purging config + cache"
  rm -rf "$CONFIG_DIR" "$CACHE_DIR"
else
  echo "    keeping config: $CONFIG_DIR/limits.env"
fi

echo "Done."
