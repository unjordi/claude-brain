#!/usr/bin/env bash
# Remove the macOS Claude Code quota app, agent, fetch script, AND the shared Claude-Code brain.
#
#   ./uninstall.sh            # remove everything (app + brain; keeps limits.env)
#   ./uninstall.sh --purge    # also remove ~/.config/claude-brain and the cache
#   ./uninstall.sh --no-brain # remove only the app; leave the Claude-Code brain installed

set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
BRAIN_UNINSTALLER="$ROOT/../brain/uninstall-brain.sh"

LABEL="io.github.unjordi.claude-brain"
FETCH_DEST="$HOME/.local/bin/claude-brain-fetch"
PLIST_DEST="$HOME/Library/LaunchAgents/$LABEL.plist"
APP_DEST="$HOME/Applications/Claude Brain Widget.app"
CONFIG_DIR="$HOME/.config/claude-brain"
CACHE_DIR="$HOME/Library/Caches/claude-brain"

PURGE=0
SKIP_BRAIN=0
for arg in "$@"; do
  case "$arg" in
    --purge)    PURGE=1 ;;
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

echo "==> Stopping app"
osascript -e 'tell application "Claude Brain Widget" to quit' 2>/dev/null || true
pkill -f "Claude Brain Widget.app/Contents/MacOS/ClaudeBrain" 2>/dev/null || true

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
