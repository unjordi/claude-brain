#!/usr/bin/env bash
# install-brain.sh — instalador del CEREBRO GLOBAL compartible de Claude Code (claude-brain).
# "Corre una vez y tu máquina queda con los guardrails, la gobernanza de costo de delegación,
# la skill de cierre, el dashboard y las normas globales." Re-correrlo es SEGURO (idempotente).
#
# Instala GLOBAL (en ~/.claude, aplica a TODOS los repos de esta máquina):
#   (a) HOOKS de tier global en ~/.claude/hooks/  → git-branch-guard, merge-squash-guard,
#       confirmar-merge-develop, recordar-dashboard, secret-scan, rama-vieja (PreToolUse/Bash),
#       delegacion-gate + limite-gasto (PreToolUse/Task), delegacion-registrar (PostToolUse/Task),
#       + delegacion-comun.sh (lib) + agentes-costo.json (config).
#   (b) CABLEADO en ~/.claude/settings.json con "shell":"bash" (idempotente).
#   (c) SKILL genérica cerrar-slice en ~/.claude/skills/.
#   (d) DASHBOARD del cerebro sembrado en la memoria GLOBAL (slug del HOME) si falta.
#   (e) NORMAS globales inyectadas en ~/.claude/CLAUDE.md (bloque con marcador, solo si faltan).
#
# confirmar-merge-develop AHORA es GLOBAL (candado de merges a develop/main con OK explícito): antes
# vivía solo por-repo y por eso faltaba donde el repo no lo traía (caso cps 2026-07-11) → promovido a
# global para que aplique en TODA sesión/clon. NO instala globales los hooks REPO-SCOPED restantes
# (sesion-inicio, precompact-volcar-estado, dod-verificar): esos viven en brain/hooks/ como FUENTE para
# que cada repo los copie a su .claude/ y los cablee (se cargan solo si la sesión INICIA en el repo).
#
# OS-agnóstico: los hooks corren bajo bash en Mac/Linux/Windows(Git Bash). FAIL-SAFE sin jq (avisa;
# los hooks fallan ABIERTO — no bloquean — hasta que instales jq).
set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SRC_HOOKS="$SCRIPT_DIR/hooks"
SRC_SKILLS="$SCRIPT_DIR/skills"
SRC_NORMS="$SCRIPT_DIR/norms"

CLAUDE_DIR="$HOME/.claude"
HOOKS_DIR="$CLAUDE_DIR/hooks"
SKILLS_DIR="$CLAUDE_DIR/skills"
GSET="$CLAUDE_DIR/settings.json"
GCLAUDE="$CLAUDE_DIR/CLAUDE.md"

echo "==> claude-brain: instalando cerebro global en $CLAUDE_DIR"
mkdir -p "$HOOKS_DIR" "$SKILLS_DIR"

# Dependencia de los hooks: jq. Sin jq, el git-branch-guard y el gate de delegación fallan ABIERTO.
if ! command -v jq >/dev/null 2>&1; then
  echo "ADVERTENCIA: 'jq' no está en el PATH. Los hooks del cerebro lo REQUIEREN (sin jq los guards"
  echo "  fallan abierto y no bloquean, y no puedo cablear el settings.json). Instálalo y re-corre:"
  echo "    macOS: brew install jq · Debian/Ubuntu: apt install jq · Windows: winget install jqlang.jq"
fi

# ── (a) Copiar hooks de tier global + la lib compartida ──
GLOBAL_HOOKS="git-branch-guard.sh merge-squash-guard.sh confirmar-merge-develop.sh recordar-dashboard.sh \
              secret-scan.sh rama-vieja.sh limite-gasto.sh \
              delegacion-gate.sh delegacion-registrar.sh delegacion-reporte.sh delegacion-comun.sh \
              limpiar-worktrees.sh"
for h in $GLOBAL_HOOKS; do
  if [ -f "$SRC_HOOKS/$h" ]; then
    cp -f "$SRC_HOOKS/$h" "$HOOKS_DIR/$h"
    chmod +x "$HOOKS_DIR/$h"
  else
    echo "warn: falta el hook fuente $h"
  fi
done
# Config de clasificación de costo (la lee delegacion-comun.sh en $HOME/.claude/agentes-costo.json)
if [ -f "$SRC_HOOKS/agentes-costo.json" ]; then
  cp -f "$SRC_HOOKS/agentes-costo.json" "$CLAUDE_DIR/agentes-costo.json"
fi
echo "ok: hooks globales + lib + config de costo copiados a $HOOKS_DIR"

# ── (b) Cablear en settings.json (idempotente) ──
# register_hook <event> <matcher> <comando> <patrón-dedupe>
register_hook() {
  local ev="$1" m="$2" cmd="$3" pat="$4" tmp
  command -v jq >/dev/null 2>&1 || { echo "warn: jq no está; agrega el hook '$pat' a $GSET a mano"; return; }
  [ -f "$GSET" ] || echo '{}' > "$GSET"
  tmp="$(mktemp)" || return
  if jq --arg ev "$ev" --arg m "$m" --arg cmd "$cmd" --arg pat "$pat" '
      .hooks = (.hooks // {}) |
      .hooks[$ev] = (.hooks[$ev] // []) |
      if any(.hooks[$ev][]?; ([.hooks[]?.command] | join(" ")) | test($pat))
      then . else .hooks[$ev] += [{"matcher":$m,"hooks":[{"type":"command","command":$cmd,"shell":"bash"}]}] end
    ' "$GSET" > "$tmp" 2>/dev/null && [ -s "$tmp" ]; then mv "$tmp" "$GSET"; else rm -f "$tmp"; echo "warn: no pude fusionar hook ($pat)"; fi
}

register_hook PreToolUse  Bash 'bash "$HOME/.claude/hooks/git-branch-guard.sh"'    'git-branch-guard'
register_hook PreToolUse  Bash 'bash "$HOME/.claude/hooks/merge-squash-guard.sh"'  'merge-squash-guard'
register_hook PreToolUse  Bash 'bash "$HOME/.claude/hooks/confirmar-merge-develop.sh"' 'confirmar-merge-develop'
register_hook PreToolUse  Bash 'bash "$HOME/.claude/hooks/recordar-dashboard.sh"'  'recordar-dashboard'
register_hook PreToolUse  Bash 'bash "$HOME/.claude/hooks/secret-scan.sh"'         'secret-scan'
register_hook PreToolUse  Bash 'bash "$HOME/.claude/hooks/rama-vieja.sh"'          'rama-vieja'
register_hook PreToolUse  Task 'bash "$HOME/.claude/hooks/limite-gasto.sh"'        'limite-gasto'
register_hook PreToolUse  Task 'bash "$HOME/.claude/hooks/delegacion-gate.sh"'     'delegacion-gate'
register_hook PostToolUse Task 'bash "$HOME/.claude/hooks/delegacion-registrar.sh"' 'delegacion-registrar'
register_hook PostToolUse Task 'bash "$HOME/.claude/hooks/delegacion-reporte.sh"'   'delegacion-reporte'
echo "ok: hooks cableados en $GSET (git-branch-guard, merge-squash-guard, confirmar-merge-develop, recordar-dashboard, secret-scan, rama-vieja, limite-gasto, delegacion-gate/registrar)"

# ── (c) Skills genéricas del cerebro (cerrar-slice, orquestar-fanout, …) ──
if [ -d "$SRC_SKILLS" ]; then
  for sk in "$SRC_SKILLS"/*/; do
    [ -f "$sk/SKILL.md" ] || continue
    name="$(basename "$sk")"
    mkdir -p "$SKILLS_DIR/$name"
    cp -f "$sk/SKILL.md" "$SKILLS_DIR/$name/SKILL.md"
    echo "ok: skill $name instalada en $SKILLS_DIR/$name"
  done
fi

# ── (d) Dashboard del cerebro en la memoria GLOBAL (slug del HOME) si falta ──
HOME_SLUG="$(printf '%s' "$HOME" | sed 's/[^a-zA-Z0-9]/-/g')"
DASH="$CLAUDE_DIR/projects/$HOME_SLUG/memory/dashboard_cerebro.md"
if [ ! -f "$DASH" ]; then
  mkdir -p "$(dirname "$DASH")"
  if [ -f "$SRC_HOOKS/dashboard_cerebro.template.md" ]; then
    cp "$SRC_HOOKS/dashboard_cerebro.template.md" "$DASH"
  else
    printf '# Dashboard del cerebro (memoria GLOBAL de esta compu)\n\n## Mapa\n## Infra clave\n## Cabos sueltos\n## Bitacora (mas reciente arriba)\n' > "$DASH"
  fi
  echo "ok: dashboard sembrado en $DASH"
else
  echo "ok: dashboard ya existe ($DASH)"
fi

# ── (e) Normas globales en ~/.claude/CLAUDE.md (bloque con marcador; REFRESCA, no solo siembra) ──
# Idempotente Y actualizable: si el bloque BEGIN/END ya existe, se REEMPLAZA EN SU LUGAR con la versión
# actual (así las normas nuevas SÍ llegan a instalaciones existentes al re-correr); si no existe, se
# agrega al final. Conserva intacto todo lo que el usuario tenga fuera del bloque.
if [ ! -f "$SRC_NORMS/global-claude-md.md" ]; then
  echo "warn: no encuentro $SRC_NORMS/global-claude-md.md; no inyecté normas"
elif [ -f "$GCLAUDE" ] && grep -q 'BEGIN claude-brain' "$GCLAUDE"; then
  tmp="$(mktemp)" || tmp=""
  if [ -n "$tmp" ] && awk -v src="$SRC_NORMS/global-claude-md.md" '
      /<!-- BEGIN claude-brain/ { skip=1; while ((getline l < src) > 0) print l; close(src) }
      skip==0 { print }
      /<!-- END claude-brain -->/ { skip=0 }
    ' "$GCLAUDE" > "$tmp" && [ -s "$tmp" ]; then
    mv "$tmp" "$GCLAUDE"
    echo "ok: normas globales del cerebro REFRESCADAS en $GCLAUDE (bloque reemplazado en su lugar)"
  else
    rm -f "$tmp"; echo "warn: no pude refrescar el bloque de normas en $GCLAUDE"
  fi
else
  { [ -f "$GCLAUDE" ] && printf '\n'; cat "$SRC_NORMS/global-claude-md.md"; } >> "$GCLAUDE"
  echo "ok: normas globales del cerebro agregadas a $GCLAUDE"
fi

echo "listo: cerebro global instalado (hooks + cableado + skill + dashboard + normas)."
echo "       Los hooks repo-scoped (sesion-inicio, precompact-volcar-estado, dod-verificar) viven en"
echo "       brain/hooks/ como fuente: cópialos al .claude/ de cada repo (se cargan al INICIAR ahí)."
