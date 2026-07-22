#!/usr/bin/env bash
# verificar-cerebro.sh — DOCTOR de instalación por-máquina del cerebro (claude-brain). Standalone
# (kind=script): NO se cablea; se corre A MANO. Confirma que ESTA máquina tiene el cerebro instalado
# y CABLEADO de verdad — antídoto al caso "las instancias de Carlitos/Chunito dejaron de avisar del
# compact/checkpoint": un hook global (aviso-contexto, barrer-ramas, rehidratar-hilo…) SOLO actúa si
# (1) su .sh está en ~/.claude/hooks, (2) está cableado en ~/.claude/settings.json y (3) jq está en el
# PATH (sin jq los hooks fallan ABIERTO: no bloquean ni avisan). Este doctor verifica las tres contra
# la FUENTE ÚNICA (el MANIFEST del clon canónico) y dice qué falta + cómo remediarlo.
#
#   uso: verificar-cerebro.sh [--quiet]
#        --quiet → solo imprime si hay FALLA (para un wrapper/hook). Exit 0 = sano; 1 = falta algo.
# Fuente de "qué debería estar": $CLAUDE_BRAIN_DIR/brain/hooks/MANIFEST (o ~/.claude-brain).
set -u

QUIET=0
[ "${1:-}" = "--quiet" ] && QUIET=1

fail=0
say()  { [ "$QUIET" = 1 ] || printf '%s\n' "$1"; }
okln() { [ "$QUIET" = 1 ] || printf '  \xe2\x9c\x93 %s\n' "$1"; }
badln(){ fail=1; printf '  \xe2\x9c\x97 %s\n' "$1"; }   # las FALLAS siempre se imprimen (aun en --quiet)

HOOKS_DIR="$HOME/.claude/hooks"
GSET="$HOME/.claude/settings.json"
BRAIN_DIR="${CLAUDE_BRAIN_DIR:-$HOME/.claude-brain}"
MANIFEST="$BRAIN_DIR/brain/hooks/MANIFEST"

say "🩺 Doctor del cerebro (claude-brain) — máquina: $(hostname 2>/dev/null || echo '?')"

# (1) jq — requisito duro de los hooks.
if command -v jq >/dev/null 2>&1; then
  okln "jq presente ($(command -v jq))"
else
  badln "jq NO está en el PATH → los hooks fallan ABIERTO (no bloquean ni avisan). Instala: brew install jq · apt install jq · winget install jqlang.jq"
fi

# (2) clon canónico + MANIFEST (la fuente de verdad de qué debe estar instalado).
if [ -f "$MANIFEST" ]; then
  okln "MANIFEST del clon canónico: $MANIFEST"
else
  badln "no encuentro el MANIFEST en $MANIFEST (¿corriste el bootstrap? ¿CLAUDE_BRAIN_DIR bien puesto?) — sin él no verifico contra la fuente única"
fi

# (3) settings.json global.
if [ -f "$GSET" ]; then
  okln "settings.json global presente: $GSET"
else
  badln "falta $GSET → NINGÚN hook global está cableado. Corre el bootstrap."
fi

# (4) por cada hook {global,both} del MANIFEST: .sh instalado + cableado en settings.json.
if [ -f "$MANIFEST" ]; then
  faltan_sh=0; faltan_wire=0; total=0
  while read -r name tier kind _; do
    case "$name" in ''|\#*) continue;; esac
    [ "$kind" = "hook" ] || continue
    case "$tier" in global|both) ;; *) continue;; esac
    total=$((total+1))
    [ -f "$HOOKS_DIR/$name.sh" ] || { badln "hook sin instalar: $name.sh (falta en $HOOKS_DIR)"; faltan_sh=$((faltan_sh+1)); }
    if [ -f "$GSET" ] && command -v jq >/dev/null 2>&1; then
      grep -qF "$name.sh" "$GSET" 2>/dev/null || { badln "hook NO cableado en settings.json: $name"; faltan_wire=$((faltan_wire+1)); }
    fi
  done < "$MANIFEST"
  [ "$faltan_sh" = 0 ]   && okln "los $total hooks {global,both} del MANIFEST están instalados en $HOOKS_DIR"
  { [ "$faltan_wire" = 0 ] && [ -f "$GSET" ]; } && okln "los $total hooks {global,both} están cableados en settings.json"
fi

# (5) contexto de repo (si se corre DENTRO de uno): .claude/memory para los hooks que lo necesitan.
ROOT="$(git rev-parse --show-toplevel 2>/dev/null || echo "")"
if [ -n "$ROOT" ]; then
  if [ -d "$ROOT/.claude/memory" ]; then
    okln "el repo actual tiene .claude/memory (aviso-contexto/barrer-ramas operan aquí)"
  else
    say "  · nota: el repo actual no tiene .claude/memory → aviso-contexto/rehidratar-hilo no miden contexto aquí (normal en repos sin cerebro)"
  fi
fi

if [ "$fail" = 0 ]; then
  say "✅ Cerebro sano en esta máquina."
  exit 0
else
  printf '⚠️  Faltan piezas del cerebro (ver ✗ arriba). Remedio general: re-corre el bootstrap del cerebro (bash .claude/bootstrap-claude.sh en un repo que lo tenga, o el install del clon canónico).\n'
  exit 1
fi
