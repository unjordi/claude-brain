#!/usr/bin/env bash
# Remove the Claude Code quota widget AND the shared Claude-Code brain. Idempotent.
#
#   ./uninstall.sh            # remove everything (widget + brain)
#   ./uninstall.sh --keep-cfg # keep ~/.config/cortex/limits.env
#   ./uninstall.sh --no-brain # remove only the widget; leave the Claude-Code brain installed

set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
BRAIN_UNINSTALLER="$ROOT/brain/uninstall-brain.sh"

PLASMOID_ID="io.github.unjordi.cortex"
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
systemctl --user disable --now cortex.timer 2>/dev/null || true

# Broker de terminal (si estaba instalado con --con-term-broker). Idempotente/fail-safe: si nunca se
# instaló, todo esto es no-op. Se retira SIEMPRE, sin bandera aparte: desinstalar es desinstalar.
# NO se toca la unidad legacy `axon-term-broker.service`: no es de cortex (la instaló axon a mano) y
# apagarla mataría sesiones que no pusimos nosotros. Ver docs/term-broker.md.
echo "==> Stopping and disabling the terminal broker (if installed)"
systemctl --user disable --now cortex-term-broker.service 2>/dev/null || true
rm -f "$HOME/.config/systemd/user/cortex-term-broker.service"
rm -f "$HOME/.local/bin/cortex-term-broker"
rm -rf "$HOME/.local/lib/cortex/term-broker"
rmdir "$HOME/.local/lib/cortex" 2>/dev/null || true   # solo si quedó vacío

echo "==> Removing systemd user units"
rm -f "$HOME/.config/systemd/user/cortex.timer"
rm -f "$HOME/.config/systemd/user/cortex.service"
systemctl --user daemon-reload || true

echo "==> Removing fetch script"
rm -f "$HOME/.local/bin/cortex-fetch"

echo "==> Removing plasmoid"
if command -v kpackagetool6 >/dev/null 2>&1; then
  kpackagetool6 -t Plasma/Applet -r "$PLASMOID_ID" 2>/dev/null || true
fi

echo "==> Removing cache"
rm -rf "$HOME/.cache/cortex"

if [[ "$KEEP_CFG" -eq 0 ]]; then
  echo "==> Removing config"
  rm -rf "$HOME/.config/cortex"
fi

# Barre la era INTERMEDIA 'claude-brain' (rename claude-brain → cortex, #312) por si quedó atrás:
# units, fetch, plasmoid, cache/config. Idempotente/fail-safe. SOLO el fetch de la era vieja; los
# helpers compartidos de ~/.local/bin NO se tocan.
echo "==> Barriendo restos de la era 'claude-brain' (si los hay)"
systemctl --user disable --now claude-brain.timer claude-brain.service 2>/dev/null || true
rm -f "$HOME/.config/systemd/user/claude-brain.timer" "$HOME/.config/systemd/user/claude-brain.service" "$HOME/.local/bin/claude-brain-fetch" 2>/dev/null || true
systemctl --user daemon-reload 2>/dev/null || true
if command -v kpackagetool6 >/dev/null 2>&1; then
  kpackagetool6 -t Plasma/Applet -r "io.github.unjordi.claude-brain" 2>/dev/null || true
fi
rm -rf "$HOME/.cache/claude-brain" 2>/dev/null || true
if [[ "$KEEP_CFG" -eq 0 ]]; then
  rm -rf "$HOME/.config/claude-brain" 2>/dev/null || true
fi

echo "Done."
