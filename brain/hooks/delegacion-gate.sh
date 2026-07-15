#!/usr/bin/env bash
# delegacion-gate.sh — PreToolUse (Task): CONSENTIMIENTO DE COSTO al reclutar un agente.
#   gratis (local)   → pregunta 1× por COMPU, luego silencioso.
#   incluido (Claude dentro de la ventana 5h) → pregunta 1× por COMPU (sin costo marginal).
#   metered (Claude en overage · API de pago · desconocido) → pregunta 1× por WORKFLOW (session_id).
# Window-aware por el state.json del daemon de cuota (umbral configurable, def 90%).
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
# DURABLE lo sigue escribiendo el PostToolUse tras la aprobación real → un "no" NO se persiste (y ADEMÁS
# el registrar LIBERA el lock al aprobar → la ruta feliz no deja fantasma). El lock rancio se recicla por
# EDAD (ver abajo). Devuelve 0 si YO debo preguntar; 1 si un hermano del lote ya lo hace.
# H6: la ventana de coalescencia se acortó de 60s a ~10s (CLAUDE_DELEG_COALESCE_S). Solo debe cubrir a los
# hermanos SIMULTÁNEOS del MISMO mensaje (<1-2s); un lock más viejo es un ask PREVIO (p. ej. uno que
# NEGASTE) → se recicla para que el reintento vuelva a preguntar. Antes, con 60s, un "no" + reintento
# <60s colaba en silencio. (Aplica solo a gratis/incluido, costo cero → el residuo de la ventana es inocuo;
# PreToolUse no puede OBSERVAR el "no", así que la ventana corta es el mecanismo, no una señal de deny.)
soy_el_primero_del_lote() {
  local sid="$1" key="$2" lock age
  lock=$(deleg_lock_path "$sid" "$key")
  if [ -d "$lock" ]; then
    age=$(deleg_lock_age_s "$lock")
    { [ -z "$age" ] || [ "$age" -ge "${CLAUDE_DELEG_COALESCE_S:-10}" ] 2>/dev/null; } && rmdir "$lock" 2>/dev/null
  fi
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
