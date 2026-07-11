#!/usr/bin/env bash
# Install the Claude Code quota widget for the current user.
#
#   ./install.sh              # full install (brain + fetch script + systemd + plasmoid)
#   ./install.sh --reinstall  # uninstall plasmoid first, then reinstall
#   ./install.sh --no-plasmoid # only the brain + fetch script + systemd timer (no GUI)
#   ./install.sh --no-gui      # alias of --no-plasmoid (skip the desktop widget)
#   ./install.sh --no-brain    # skip the Claude-Code brain (hooks/norms); only daemon + GUI
#   ./install.sh --no-claude-code # skip auto-installing the Claude Code CLI (the widget measures IT)
#   ./install.sh --no-reload-shell # don't restart plasmashell at the end (default: restart to load changes)
#
# This is the MASTER installer for claude-brain: it lays down the shared Claude-Code brain
# (global hooks, delegation-cost governance, skill, norms) AND the quota daemon + optional GUI.
# Idempotent.

set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
BIN_SRC="$ROOT/src/bin/claude-brain-fetch"
UNIT_SRC="$ROOT/src/systemd"
PLASMOID_SRC="$ROOT/src/plasmoid"
PLASMOID_ID="io.github.unjordi.claude-quota-widget"
BRAIN_INSTALLER="$ROOT/brain/install-brain.sh"

BIN_DEST="$HOME/.local/bin/claude-brain-fetch"
UNIT_DEST="$HOME/.config/systemd/user"
LIMITS_DEFAULT="$HOME/.config/claude-quota/limits.env"

REINSTALL=0
SKIP_PLASMOID=0
SKIP_CCUSAGE=0
SKIP_BRAIN=0
SKIP_CLAUDE_CODE=0
RELOAD_SHELL=1
for arg in "$@"; do
  case "$arg" in
    --reinstall)       REINSTALL=1 ;;
    --no-plasmoid)     SKIP_PLASMOID=1 ;;
    --no-gui)          SKIP_PLASMOID=1 ;;
    --no-brain)        SKIP_BRAIN=1 ;;
    --no-ccusage)      SKIP_CCUSAGE=1 ;;
    --no-claude-code)  SKIP_CLAUDE_CODE=1 ;;
    --no-reload-shell) RELOAD_SHELL=0 ;;
    *) echo "unknown arg: $arg" >&2; exit 2 ;;
  esac
done

# Asegura que ~/.local/bin (donde viven el fetch y, típicamente, el CLI `claude`) esté en el PATH,
# en zsh Y bash. Idempotente por marcador; crea el rc si falta. Se aplica también a ESTE proceso.
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

if [[ "$SKIP_CLAUDE_CODE" -eq 0 ]]; then
  echo "==> Ensuring the Claude Code CLI is installed (the widget measures ITS usage)"
  if command -v claude >/dev/null 2>&1; then
    echo "    already present ($(command -v claude))"
  elif [[ -x "$HOME/.local/bin/claude" ]]; then
    echo "    present in ~/.local/bin but not on PATH — exposing it (see below)"
  else
    echo "    installing via the native installer (auto-updates itself)"
    curl -fsSL https://claude.ai/install.sh | bash \
      || echo "    (could not auto-install; do it by hand: curl -fsSL https://claude.ai/install.sh | bash)"
  fi
fi
echo "==> Ensuring ~/.local/bin on PATH (zsh + bash)"
ensure_path_local_bin

# ── Migración desde el nombre viejo (claude-quota → claude-brain). Idempotente / fail-safe. ──
# CRÍTICO: un reinstall NO debe dejar 2 timers/daemons vivos ni perder la calibración del usuario.
echo "==> Migrating any previous 'claude-quota' install (idempotent)"
# 1) Baja y deshabilita las units VIEJAS antes de instalar las nuevas (evita timer/daemon duplicado).
systemctl --user disable --now claude-quota.timer claude-quota.service 2>/dev/null || true
rm -f "$HOME/.config/systemd/user/claude-quota.timer" "$HOME/.config/systemd/user/claude-quota.service"
rm -f "$HOME/.local/bin/claude-quota-fetch"   # el fetch viejo (renombrado a claude-brain-fetch)
systemctl --user daemon-reload 2>/dev/null || true
# 2) Preserva estado: mueve solo el CACHE viejo al nombre nuevo si aún no existe. El dir de CONFIG
#    (~/.config/claude-quota) NO se renombra — ahí viven limits.env/machine-id/account (calibración +
#    identidad de sync), que se preservan quietos, igual que en macOS y Windows (contrato invisible).
if [[ -d "$HOME/.cache/claude-quota" && ! -e "$HOME/.cache/claude-brain" ]]; then
  mv "$HOME/.cache/claude-quota" "$HOME/.cache/claude-brain"
fi

echo "==> Installing fetch script -> $BIN_DEST"
install -D -m 0755 "$BIN_SRC" "$BIN_DEST"

# chats-extract.js / sessions-extract.js / session-move.js junto al fetch (el fetch corre los
# extractores con node -> chats.json / sessions.json; session-move.js lo invoca la GUI al "Mover a…").
CHATS_SRC="$ROOT/bin/chats-extract.js"
[[ -f "$CHATS_SRC" ]] && install -D -m 0755 "$CHATS_SRC" "$(dirname "$BIN_DEST")/chats-extract.js"
SESSIONS_SRC="$ROOT/bin/sessions-extract.js"
[[ -f "$SESSIONS_SRC" ]] && install -D -m 0755 "$SESSIONS_SRC" "$(dirname "$BIN_DEST")/sessions-extract.js"
SESSIONMOVE_SRC="$ROOT/bin/session-move.js"
[[ -f "$SESSIONMOVE_SRC" ]] && install -D -m 0755 "$SESSIONMOVE_SRC" "$(dirname "$BIN_DEST")/session-move.js"

if [[ ! -f "$LIMITS_DEFAULT" ]]; then
  echo "==> Seeding default limits at $LIMITS_DEFAULT"
  install -d "$(dirname "$LIMITS_DEFAULT")"
  cat > "$LIMITS_DEFAULT" <<'EOF'
# FALLBACK calibration — only used when the OAuth usage endpoint is
# unreachable (offline, or no ~/.claude/.credentials.json). When Claude Code's
# OAuth token is available the widget reads the exact /usage percentages and
# these caps are ignored.
# After editing, run: systemctl --user restart claude-brain.service
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

# (e) Sync entre máquinas (opt-in): comparte un snapshot de uso vía una carpeta que tu nube ya
# replica, y el widget muestra un toggle "esta máquina / todas". "auto" autodetecta Google Drive
# (en Linux no hay cliente oficial: mejor pon la ruta explícita del mount de rclone/insync); o una
# ruta. Ausente/vacío = off (100% local, no sube nada).
# SYNC_DIR=auto
EOF
fi

echo "==> Installing systemd user units -> $UNIT_DEST"
install -D -m 0644 "$UNIT_SRC/claude-brain.service" "$UNIT_DEST/claude-brain.service"
install -D -m 0644 "$UNIT_SRC/claude-brain.timer"   "$UNIT_DEST/claude-brain.timer"

echo "==> Reloading systemd user manager"
systemctl --user daemon-reload

echo "==> Enabling timer"
systemctl --user enable --now claude-brain.timer

echo "==> Priming cache with one run"
systemctl --user start claude-brain.service || true
sleep 1
if [[ -f "$HOME/.cache/claude-brain/state.json" ]]; then
  echo "    state.json written:"
  jq -c '{status, five: .five_hour.percent, wk: .weekly.percent}' \
     "$HOME/.cache/claude-brain/state.json" | sed 's/^/    /'
else
  echo "    (no state.json yet — check: journalctl --user -u claude-brain.service)"
fi

if [[ "$SKIP_PLASMOID" -eq 0 ]]; then
  # Empaqueta brain/ DENTRO del plasmoid (contents/brain) para que la curita self-healing de la
  # pestaña Cerebro tenga una ruta GARANTIZADA al install-brain.sh (análogo al bundle .app de macOS).
  # Se copia justo antes de empaquetar y se limpia después, para no ensuciar el árbol fuente.
  BRAIN_IN_PKG="$PLASMOID_SRC/contents/brain"
  rm -rf "$BRAIN_IN_PKG"
  if [[ -d "$ROOT/brain" ]]; then
    cp -R "$ROOT/brain" "$BRAIN_IN_PKG"
  fi
  # Versión EMBEBIDA para el autoupdate LIGERO (winturbo-style, espeja macos/make-app.sh): el SHA + la
  # fecha del commit con que se empaqueta el plasmoid, la ruta del clon y la rama, para que la pestaña
  # Cerebro compare contra GitHub y sepa desde dónde re-jalar. Se escribe justo antes de empaquetar y se
  # limpia después (como brain/), para no ensuciar el árbol fuente. FAIL-OPEN: si no hay git → "unknown"/"".
  VERSION_IN_PKG="$PLASMOID_SRC/contents/version.json"
  _sha="$(git -C "$ROOT" rev-parse --short HEAD 2>/dev/null || echo unknown)"
  _date="$(git -C "$ROOT" show -s --format=%cI HEAD 2>/dev/null || echo "")"
  _repo="$ROOT"
  _branch="$(git -C "$ROOT" rev-parse --abbrev-ref HEAD 2>/dev/null || echo "")"
  printf '{"sha":"%s","date":"%s","repo":"%s","branch":"%s"}\n' \
    "$_sha" "$_date" "$_repo" "$_branch" > "$VERSION_IN_PKG"
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
  rm -rf "$BRAIN_IN_PKG"   # limpia el árbol fuente tras empaquetar
  rm -f "$VERSION_IN_PKG"  # idem: version.json es temporal, no se versiona

  # Recarga plasmashell para que tome el plasmoide nuevo: actualizar el PAQUETE no refresca la instancia
  # viva. Guardado: solo si hay sesión gráfica y plasmashell corriendo (nada sobre SSH/headless);
  # se salta con --no-reload-shell. Si no aplica, imprime el comando manual. El panel parpadea ~1s.
  if [[ "$RELOAD_SHELL" -eq 1 ]] && command -v kquitapp6 >/dev/null 2>&1 \
       && pgrep -x plasmashell >/dev/null 2>&1 && [[ -n "${WAYLAND_DISPLAY:-}${DISPLAY:-}" ]]; then
    echo "==> Recargando plasmashell para aplicar los cambios (el panel parpadeará un momento)..."
    kquitapp6 plasmashell >/dev/null 2>&1 || true
    sleep 1
    ( kstart plasmashell >/dev/null 2>&1 & ) 2>/dev/null || ( plasmashell >/dev/null 2>&1 & ) || true
  else
    echo "==> Para ver los cambios, recarga plasmashell:  kquitapp6 plasmashell; kstart plasmashell"
    echo "    (o:  just reload-plasmashell  ·  o cierra sesión y vuelve a entrar en Wayland)"
  fi
fi

cat <<EOF

Done.

The Claude-Code brain is installed globally (hooks + delegation-cost governance + norms in
  ~/.claude). See README.md; re-run any time (idempotent). Skip it with --no-brain.

Next steps:
  - Right-click your Plasma panel -> Add or Manage Widgets -> search "Claude Brain Widget"
  - Drag it onto the panel (or into the system tray slot).
  - Hover for the breakdown; tune caps in: $LIMITS_DEFAULT

Debug:
  systemctl --user status claude-brain.timer
  journalctl --user -u claude-brain.service -n 20
  cat ~/.cache/claude-brain/state.json | jq .
EOF

# Login reminder: sin sesión de Claude Code el widget no ve tu cuota real (solo el fallback calibrado).
# El login es interactivo/por-usuario: el instalador NO puede hacerlo por ti.
if command -v claude >/dev/null 2>&1; then
  if ! claude auth status >/dev/null 2>&1; then
    echo ""
    echo "IMPORTANT: log in to Claude Code so the widget reads your REAL quota:"
    echo "  claude        # then /login with your account"
  fi
else
  echo ""
  echo "NOTE: 'claude' isn't on PATH yet (maybe a fresh install) — open a new shell, then:"
  echo "  claude        # /login so the widget shows your real quota"
fi
