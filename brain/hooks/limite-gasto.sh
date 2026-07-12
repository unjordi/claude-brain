#!/usr/bin/env bash
# limite-gasto.sh — PreToolUse/Task: FRENO DURO de gasto. A diferencia de delegacion-gate (que
# PREGUNTA y tú decides), este BLOQUEA reclutar un agente cuando el gasto real YA rebasó un techo
# duro configurable — para que un workflow desbocado no siga quemando overage sin que nadie mire.
# Lee el state.json del daemon de cuota (el mismo que alimenta el widget).
#
# Techos configurables por entorno (desactivados = imposible de rebasar):
#   LIMITE_GASTO_OVERAGE_PCT  (util. de créditos de SOBREUSO; def 90)
#   LIMITE_GASTO_5H_PCT       (ventana de 5h; def 101 = desactivado)
# Fail-open: sin jq, sin snapshot, o snapshot rancio (>30 min) NO bloquea (nunca frena a ciegas).
set -u
command -v jq >/dev/null 2>&1 || exit 0
input=$(cat 2>/dev/null || true)
[ "$(printf '%s' "$input" | jq -r '.tool_name // empty' 2>/dev/null)" = "Task" ] || exit 0

snap=""
for c in "${XDG_CACHE_HOME:-$HOME/.cache}/claude-brain/state.json" "$HOME/Library/Caches/claude-brain/state.json"; do
  [ -f "$c" ] && { snap="$c"; break; }
done
[ -z "$snap" ] && exit 0
[ -n "$(find "$snap" -mmin +30 2>/dev/null)" ] && exit 0   # rancio → no frena

over_pct=$(jq -r '.extra_usage.utilization // empty' "$snap" 2>/dev/null)
five_pct=$(jq -r '.five_hour.percent // empty' "$snap" 2>/dev/null)
lim_over="${LIMITE_GASTO_OVERAGE_PCT:-90}"
lim_5h="${LIMITE_GASTO_5H_PCT:-101}"

hit=""
if [ -n "$over_pct" ] && awk -v a="$over_pct" -v b="$lim_over" 'BEGIN{exit !(a+0>=b+0)}'; then
  hit="el sobreuso (overage) va al ${over_pct}% del tope (techo duro ${lim_over}%)"
elif [ -n "$five_pct" ] && awk -v a="$five_pct" -v b="$lim_5h" 'BEGIN{exit !(a+0>=b+0)}'; then
  hit="la ventana de 5h va al ${five_pct}% (techo duro ${lim_5h}%)"
fi
[ -z "$hit" ] && exit 0

jq -n --arg h "$hit" '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:"deny",permissionDecisionReason:("FRENO DURO DE GASTO (limite-gasto): "+$h+". Reclutar más agentes seguiría quemando gasto de bolsillo. NO reintentes en automático. Opciones: (a) haz la tarea TÚ, sin delegar; (b) espera a que la ventana se recupere; (c) si de verdad quieres seguir, sube el techo a propósito: LIMITE_GASTO_OVERAGE_PCT=<n> o LIMITE_GASTO_5H_PCT=<n>.")}}'
exit 0
