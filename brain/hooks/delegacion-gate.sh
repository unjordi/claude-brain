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

# G3 — coalescer asks en FAN-OUT PARALELO. N Task en un mismo mensaje disparan N gates ANTES de que el
# 1er PostToolUse registre el consentimiento → N asks (fricción del "47 tareas"). El PRIMER gate de un
# lote toma un lock ATÓMICO (mkdir) por (sesión,key) y pregunta; los HERMANOS del mismo lote (lock
# fresco) se dejan pasar en silencio. Solo se aplica a gratis/incluido (costo cero / cubierto por tu
# ventana): dejar pasar un hermano sin ask NO puede gastar de más. Metered NO se coalesce (un fan-out
# de PAGO sí amerita confirmar cada uno; un "no" no debe dejar correr agentes caros). El consentimiento
# DURABLE lo sigue escribiendo el PostToolUse tras la aprobación real → un "no" NO se persiste. El lock
# rancio (>1 min: lote viejo) se limpia solo. Devuelve 0 si YO debo preguntar; 1 si un hermano ya lo hace.
soy_el_primero_del_lote() {
  local sid="$1" key="$2" h lock
  h=$(printf '%s|%s' "$sid" "$key" | tr -cs 'A-Za-z0-9' '_')
  lock="$HOME/.claude/.delegacion-ask.$h.lock"
  [ -d "$lock" ] && [ -n "$(find "$lock" -maxdepth 0 -mmin +1 2>/dev/null)" ] && rmdir "$lock" 2>/dev/null
  mkdir "$lock" 2>/dev/null && return 0 || return 1
}

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
    soy_el_primero_del_lote "$DG_SID" "$DG_KEY" || exit 0   # G3: un hermano del lote ya pregunta → silencio
    if [ "$DG_NIVEL" = gratis ]; then
      ask "Delegación a un agente LOCAL/gratuito ($DG_TARGET) — sin costo por token. ¿Autorizar delegación automática a locales en ESTA compu? Se recuerda por compu.${CUOTA}"
    else
      ask "Delegación a Claude ($DG_TARGET) DENTRO de tu ventana de 5h (uso ${DG_PCT}%, umbral ${DG_UMBRAL}%) — sin costo marginal (ya cubierto por tu suscripción). ¿Autorizar delegación a Claude mientras haya ventana? Se recuerda por compu; si la ventana se agota, se vuelve a preguntar.${CUOTA}"
    fi
    ;;
  metered)
    ok=$(jq -r --arg s "$DG_SID" --arg k "$DG_KEY" '.sesion[$s][$k] // false' "$CONS" 2>/dev/null)
    [ "$ok" = "true" ] && exit 0                       # ya consentido en ESTE workflow
    if [ "$DG_CLASE" = claude ]; then motivo="vas al ${DG_PCT}% de tu ventana de 5h (umbral ${DG_UMBRAL}%) — seguir ya es OVERAGE (gasto extra a tu plan)"; else motivo="agente de pago por token"; fi
    ask "Delegación ($DG_TARGET) — $motivo. ¿Autorizar seguir delegando en ESTE workflow? Se pregunta 1× por workflow (no cada agente). Si además se agota el overage, limite-gasto frena.${CUOTA}"
    ;;
esac
exit 0
