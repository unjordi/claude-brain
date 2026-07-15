#!/usr/bin/env bash
# delegacion-registrar.sh — PostToolUse (Task): registra el consentimiento DESPUÉS de que el agente
# corrió (o sea: el usuario aprobó el ask del gate). Materializa el "pregunta 1×":
#   gratis/incluido → registra por COMPU (permanente hasta que cambie la firma/nivel).
#   metered         → registra por WORKFLOW (session_id) → silencioso el resto del workflow.
# Si el usuario NIEGA el ask, el Task no corre → este hook no dispara → no se registra nada.
set -u
input=$(cat 2>/dev/null || true)
command -v jq >/dev/null 2>&1 || exit 0
CONS="$HOME/.claude/delegacion-consentimiento.json"

# shellcheck source=delegacion-comun.sh
. "$(dirname "$0")/delegacion-comun.sh"
clasificar_delegacion "$input"
[ "$DG_ES_TASK" = 1 ] || exit 0

[ -f "$CONS" ] || echo '{"maquina":{},"sesion":{}}' > "$CONS"
case "$DG_NIVEL" in
  gratis|incluido) filtro='.maquina[$k]=true' ;;
  metered)         filtro='.sesion[$s] = ((.sesion[$s]//{}) + {($k):true})' ;;
  *) exit 0 ;;
esac
tmp=$(mktemp) || exit 0
jq --arg k "$DG_KEY" --arg s "$DG_SID" "$filtro" "$CONS" > "$tmp" 2>/dev/null && mv "$tmp" "$CONS" || rm -f "$tmp"

# H6: al APROBARSE (este hook solo corre si el Task corrió), libera el lock de coalescencia del lote →
# la ruta feliz no deja un fantasma de ~10s. (El "no" no llega aquí; ese caso lo cubre la ventana corta
# del gate.) Ruta del lock vía el helper COMPARTIDO → sin drift del hash con el gate.
rmdir "$(deleg_lock_path "$DG_SID" "$DG_KEY")" 2>/dev/null || true
exit 0
