#!/usr/bin/env bash
# delegacion-gate.sh — PreToolUse (Task): CONSENTIMIENTO DE COSTO al reclutar un agente.
#   gratis (local)   → pregunta 1× por COMPU, luego silencioso.
#   incluido (Claude dentro de la ventana 5h) → pregunta 1× por COMPU (sin costo marginal).
#   metered (Claude en overage · API de pago · desconocido) → pregunta 1× por WORKFLOW (session_id).
# Window-aware por el state.json del daemon de cuota (umbral configurable, def 95%).
# Idempotente, OS-agnóstico (bash), FAIL-SAFE: sin jq o sin snapshot fresco → metered → pregunta.
set -u
input=$(cat 2>/dev/null || true)
CONS="$HOME/.claude/delegacion-consentimiento.json"

ask() { jq -n --arg r "$1" '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:"ask",permissionDecisionReason:$r}}'; exit 0; }

# FAIL-SAFE: sin jq no clasificamos → si es delegación, pregunta.
command -v jq >/dev/null 2>&1 || { printf '%s' "$input" | grep -q '"Task"' && ask "No puedo clasificar el costo de la delegación (falta jq). Por seguridad de gasto, ¿autorizas ESTA delegación? (instala jq para el flujo normal)"; exit 0; }

# shellcheck source=delegacion-comun.sh
. "$(dirname "$0")/delegacion-comun.sh"
clasificar_delegacion "$input"
[ "$DG_ES_TASK" = 1 ] || exit 0   # no es una delegación → no nos incumbe

# Estado REAL de la ventana desde el snapshot del daemon de cuota (vacío si no hay snapshot).
CUOTA="$(linea_cuota)"

case "$DG_NIVEL" in
  gratis|incluido)
    ok=$(jq -r --arg k "$DG_KEY" '.maquina[$k] // false' "$CONS" 2>/dev/null)
    [ "$ok" = "true" ] && exit 0                       # ya consentido en esta compu
    if [ "$DG_NIVEL" = gratis ]; then
      ask "Delegación a un agente LOCAL/gratuito ($DG_TARGET) — sin costo por token. ¿Autorizar delegación automática a locales en ESTA compu? Se recuerda por compu.${CUOTA}"
    else
      ask "Delegación a Claude ($DG_TARGET) DENTRO de tu ventana de 5h (uso ${DG_PCT}%, umbral ${DG_UMBRAL}%) — sin costo marginal (ya cubierto por tu suscripción). ¿Autorizar delegación a Claude mientras haya ventana? Se recuerda por compu; si la ventana se agota, se vuelve a preguntar.${CUOTA}"
    fi
    ;;
  metered)
    ok=$(jq -r --arg s "$DG_SID" --arg k "$DG_KEY" '.sesion[$s][$k] // false' "$CONS" 2>/dev/null)
    [ "$ok" = "true" ] && exit 0                       # ya consentido en ESTE workflow
    if [ "$DG_CLASE" = claude ]; then motivo="tu ventana de 5h está agotada (overage → costo real)"; else motivo="agente de pago por token"; fi
    ask "Delegación CON COSTO ($DG_TARGET) — $motivo. ¿Autorizar delegaciones con costo en ESTE workflow? Se pregunta 1× por workflow (no cada agente).${CUOTA}"
    ;;
esac
exit 0
