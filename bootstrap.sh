#!/usr/bin/env bash
# bootstrap.sh — instalador AUTOCONTENIDO de cortex para Linux/macOS.
# Un solo comando (no necesitas nada preinstalado salvo el gestor de paquetes del sistema):
#
#   curl -fsSL https://raw.githubusercontent.com/unjordi/cortex/main/bootstrap.sh | bash
#
# Qué hace: (1) instala los prerrequisitos que falten con el gestor del OS (brew / apt / dnf / pacman
# / zypper), (2) clona o actualiza el repo, (3) corre ./install.sh (cerebro + daemon + widget).
# Idempotente: re-correrlo solo actualiza. Flags para install.sh se pasan tal cual:
#   curl -fsSL …/bootstrap.sh | bash -s -- --no-gui        # p.ej. solo cerebro + daemon
# Para QA de una RAMA (p. ej. develop) en vez de la rama default, antepón CLAUDE_BRAIN_REF:
#   curl -fsSL …/develop/bootstrap.sh | CLAUDE_BRAIN_REF=develop bash
set -euo pipefail

REPO_URL="https://github.com/unjordi/cortex"
DIR="${CLAUDE_BRAIN_DIR:-$HOME/.cortex}"
say() { printf '\033[1;38;5;208m🧠 cortex\033[0m » %s\n' "$1"; }

# Migración del clon de eras viejas → $DIR (~/.cortex; respeta CLAUDE_BRAIN_DIR). El clon se necesita
# para que "Actualizar widget" funcione (guarda su ruta en version.json): no se borra, se REUBICA. La
# era intermedia 'claude-brain' vivía en ~/.claude-brain (oculto) o ~/claude-brain (visible, pre-
# ocultamiento 2026-07-15). Si existe y $DIR aún no, muévelo y reapunta el remote a cortex; si $DIR ya
# existe, borra el huérfano. Idempotente/fail-safe. (El #312 renombró el OLD_DIR mecánicamente a
# ~/cortex —un dir visible que NUNCA existió—; ese puntero muerto se quitó, las rutas reales van abajo.)
for _brain_old in "$HOME/.claude-brain" "$HOME/claude-brain"; do
  [[ -d "$_brain_old/.git" ]] || continue
  # NUNCA operes sobre el destino ACTIVO: si $DIR (CLAUDE_BRAIN_DIR) ES esta ruta vieja, sáltala — si no,
  # el else borraría el clon VIVO. -ef compara device+inodo (atrapa symlink/trailing-slash cuando ambos
  # existen); el string-compare (trailing slash stripped) cubre el caso de $DIR aún inexistente.
  if [[ "$_brain_old" -ef "$DIR" ]] || [[ "${_brain_old%/}" == "${DIR%/}" ]]; then
    continue
  fi
  if [[ ! -e "$DIR" ]]; then
    say "migrando el clon de $_brain_old a $DIR (rename claude-brain → cortex)"
    mv "$_brain_old" "$DIR"
    git -C "$DIR" remote set-url origin "$REPO_URL" 2>/dev/null || true
  else
    say "quitando el clon huérfano $_brain_old (ya existe $DIR)"
    rm -rf "$_brain_old" 2>/dev/null || true
  fi
done

# ── (1) Prerrequisitos ──────────────────────────────────────────────────────
# git + jq (guardias) + node/npm (ccusage). En macOS además clang/swift vienen con Xcode CLT.
need=(git jq)
have() { command -v "$1" >/dev/null 2>&1; }

install_pkgs() {  # $@ = paquetes; usa el gestor disponible
  local pkgs=("$@")
  if have brew;    then brew install "${pkgs[@]}"
  elif have apt-get; then sudo apt-get update -y && sudo apt-get install -y "${pkgs[@]}"
  elif have dnf;   then sudo dnf install -y "${pkgs[@]}"
  elif have pacman;then sudo pacman -S --needed --noconfirm "${pkgs[@]}"
  elif have zypper;then sudo zypper install -y "${pkgs[@]}"
  else return 1; fi
}

if [[ "$OSTYPE" == darwin* ]]; then
  if ! have brew; then
    say "Homebrew no está — instálalo una vez (https://brew.sh) y re-corre. (No lo instalo yo para no sorprenderte.)"; exit 1
  fi
  # node para ccusage; swift viene con Xcode CLT (xcode-select --install si falta).
  missing=(); for p in git jq node; do have "$p" || missing+=("$p"); done
  [[ ${#missing[@]} -gt 0 ]] && { say "instalando (brew): ${missing[*]}"; brew install "${missing[@]}"; }
  have swift || { say "faltan las Command Line Tools de Xcode (swift) — corre: xcode-select --install, luego re-corre"; exit 1; }
else
  # Linux: node suele ser 'nodejs'. Instalamos lo que falte de una.
  missing=(); for p in git jq; do have "$p" || missing+=("$p"); done
  have node || have nodejs || missing+=("nodejs" "npm")
  if [[ ${#missing[@]} -gt 0 ]]; then
    say "instalando prereqs (${missing[*]}) con el gestor del sistema (puede pedir sudo)…"
    install_pkgs "${missing[@]}" || { say "no reconocí tu gestor de paquetes; instala a mano: ${missing[*]}"; exit 1; }
  fi
fi

# ── (2) Clonar o actualizar ─────────────────────────────────────────────────
# CLAUDE_BRAIN_REF (opcional): rama a instalar (p. ej. develop para QA). Si se define, tras
# clonar/actualizar se hace checkout de esa rama igualando el remoto; sin ella, la rama default.
REF="${CLAUDE_BRAIN_REF:-}"
if [[ -d "$DIR/.git" ]]; then
  say "actualizando el clon en $DIR"; git -C "$DIR" fetch -q --prune origin || say "sin red / fetch falló — sigo con el clon local ya presente (no bloqueo la instalación por estar offline)"
  # Guardar trabajo no commiteado antes del checkout -B (que lo DESCARTA): stash si hay cambios.
  if [ -n "$(git -C "$DIR" status --porcelain 2>/dev/null)" ]; then
    git -C "$DIR" stash push -u -m "pre-bootstrap-$(date +%s)" 2>/dev/null || true
    say "guardé tus cambios locales en un stash (checkout -B los habría descartado)"
  fi
  # Sin REF: alinear SIEMPRE a main (NO `pull` de la rama actual). Un clon que quedó en una rama
  # vieja/borrada —leftover de dev— rompía el `pull --ff-only` (su upstream ya no existe en el remoto).
  if [[ -n "$REF" ]]; then git -C "$DIR" checkout -B "$REF" "origin/$REF"; else git -C "$DIR" checkout -B main origin/main; fi
else
  say "clonando en $DIR"; git clone "$REPO_URL" "$DIR"
  [[ -n "$REF" ]] && { git -C "$DIR" fetch -q origin; git -C "$DIR" checkout -B "$REF" "origin/$REF"; }
fi
[[ -n "$REF" ]] && say "instalando la rama '$REF' (QA)"

# ── (3) Instalar (cerebro + daemon + widget) ────────────────────────────────
# Puerta por OS: macOS tiene su propio instalador (launchd + .app); el raíz es Linux/KDE
# (systemd + plasmoid, exige systemctl/kpackagetool6 → moriría en una Mac).
INSTALLER="./install.sh"
[[ "$OSTYPE" == darwin* ]] && INSTALLER="./macos/install.sh"
say "corriendo $INSTALLER $*"
cd "$DIR" && bash "$INSTALLER" "$@"
say "listo — tu máquina quedó con el cerebro puesto. 🎀"
