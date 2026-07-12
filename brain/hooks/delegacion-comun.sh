# delegacion-comun.sh — librería compartida por delegacion-gate.sh (Pre) y delegacion-registrar.sh (Post).
# NO es un hook por sí sola; se hace `source`. Expone clasificar_delegacion(): a partir del JSON del
# payload del hook (en $1), deja en variables globales el NIVEL DE COSTO y los datos para el
# consentimiento. Fuente única de clasificación → gate y registrador NUNCA divergen.
#
# NIVELES:  gratis (local) · incluido (Claude dentro de la ventana 5h) · metered (Claude en overage,
#           API externa de pago, o desconocido). Ver agentes-costo.json.
# Requiere jq (el que la use debe verificarlo antes).
# shellcheck shell=bash

REG_FILE="$HOME/.claude/agentes-costo.json"

# clasificar_delegacion "<payload-json>" → setea: DG_ES_TASK DG_SID DG_TARGET DG_CLASE DG_FIRMA
#                                                  DG_UMBRAL DG_PCT DG_NIVEL DG_KEY
clasificar_delegacion() {
  local input="$1"
  DG_ES_TASK=0; DG_SID="sin-sesion"; DG_TARGET=""; DG_CLASE="token"; DG_FIRMA="desconocido"
  DG_UMBRAL=95; DG_PCT="?"; DG_NIVEL="metered"; DG_KEY=""

  [ "$(printf '%s' "$input" | jq -r '.tool_name // empty' 2>/dev/null)" = "Task" ] || return 0
  DG_ES_TASK=1
  DG_SID=$(printf '%s' "$input" | jq -r '.session_id // "sin-sesion"' 2>/dev/null)
  DG_TARGET=$(printf '%s' "$input" | jq -r '[.tool_input.subagent_type // "", .tool_input.model // ""] | join(" ") | ascii_downcase' 2>/dev/null)

  # clase + firma desde el registro (1ª regla que casa; si no, default). umbral configurable (def 95).
  if [ -f "$REG_FILE" ]; then
    DG_UMBRAL=$(jq -r '.umbral_ventana_pct // 95' "$REG_FILE" 2>/dev/null)
    local cf
    cf=$(jq -r --arg t "$DG_TARGET" '
      ([ (.reglas // [])[] | select(.match as $m | ($t | test($m; "i"))) ][0]) as $h
      | if $h then "\($h.clase) \($h.firma)" else "\(.default // "token") desconocido" end
    ' "$REG_FILE" 2>/dev/null)
    [ -n "$cf" ] && { DG_CLASE="${cf%% *}"; DG_FIRMA="${cf#* }"; }
  fi

  # resuelve NIVEL
  case "$DG_CLASE" in
    local) DG_NIVEL="gratis" ;;
    claude)
      # snapshot de cuota FRESCO (< 30 min); dentro de ventana (pct < umbral) → incluido; si no → metered
      local snap="" c
      for c in "${XDG_CACHE_HOME:-$HOME/.cache}/claude-quota/state.json" "$HOME/Library/Caches/claude-brain/state.json"; do
        [ -f "$c" ] && { snap="$c"; break; }
      done
      if [ -n "$snap" ] && [ -z "$(find "$snap" -mmin +30 2>/dev/null)" ]; then
        DG_PCT=$(jq -r '.five_hour.percent // 100' "$snap" 2>/dev/null)
        if [ "${DG_PCT%.*}" -lt "${DG_UMBRAL%.*}" ] 2>/dev/null; then DG_NIVEL="incluido"; else DG_NIVEL="metered"; fi
      else
        DG_NIVEL="metered"   # sin snapshot o rancio → conservador
      fi
      ;;
    externo) DG_NIVEL="metered" ;;
    *)       DG_NIVEL="metered" ;;   # desconocido / default
  esac
  DG_KEY="$DG_NIVEL:$DG_FIRMA"
}

# fmt_tokens <entero> → "3.7M" / "864.8M" / "12.3K" (humaniza el conteo de tokens)
fmt_tokens() {
  awk -v t="$1" 'BEGIN{
    if (t=="" || t+0!=t) { exit }
    if (t>=1e9) printf "%.1fB", t/1e9;
    else if (t>=1e6) printf "%.1fM", t/1e6;
    else if (t>=1e3) printf "%.1fK", t/1e3;
    else printf "%d", t
  }'
}

# linea_cuota → imprime el ESTADO REAL de las ventanas desde el snapshot del daemon de cuota
# (state.json): la ventana de 5h y —si el snapshot la trae— la SEMANAL, p. ej.:
#   " Ventana 5h: 19% ($2.48 de $45; 3.7M tokens) · Semanal: 57% ($401/$4800)." — contexto honesto
# para decidir si autorizar una delegación. NO inventa un costo por-agente (no se puede saber
# pre-ejecución): muestra el ritmo/uso ACTUAL de las ventanas. Si no hay snapshot o falta jq →
# imprime nada (no truena); si el snapshot no trae la semanal, se omite ese tramo (no truena).
linea_cuota() {
  command -v jq >/dev/null 2>&1 || return 0
  local snap="" c
  for c in "${XDG_CACHE_HOME:-$HOME/.cache}/claude-quota/state.json" "$HOME/Library/Caches/claude-brain/state.json"; do
    [ -f "$c" ] && { snap="$c"; break; }
  done
  [ -n "$snap" ] || return 0
  local pct cost cap tok
  pct=$(jq -r '.five_hour.percent // empty'      "$snap" 2>/dev/null)
  cost=$(jq -r '.five_hour.cost_usd // empty'    "$snap" 2>/dev/null)
  cap=$(jq -r '.five_hour.cost_cap // empty'     "$snap" 2>/dev/null)
  tok=$(jq -r '.five_hour.tokens_used // empty'  "$snap" 2>/dev/null)
  [ -n "$pct" ] || return 0
  local msg=" Ventana 5h: ${pct}%"
  if [ -n "$cost" ] && [ -n "$cap" ]; then
    msg="$msg (\$${cost} de \$${cap}"
    [ -n "$tok" ] && msg="$msg; $(fmt_tokens "$tok") tokens"
    msg="$msg)"
  elif [ -n "$tok" ]; then
    msg="$msg ($(fmt_tokens "$tok") tokens)"
  fi
  # Ventana SEMANAL (opcional): solo si el snapshot la trae. Formato compacto "($cost/$cap)".
  local wpct wcost wcap
  wpct=$(jq -r '.weekly.percent // empty'   "$snap" 2>/dev/null)
  wcost=$(jq -r '.weekly.cost_usd // empty' "$snap" 2>/dev/null)
  wcap=$(jq -r '.weekly.cost_cap // empty'  "$snap" 2>/dev/null)
  if [ -n "$wpct" ]; then
    msg="$msg · Semanal: ${wpct}%"
    [ -n "$wcost" ] && [ -n "$wcap" ] && msg="$msg (\$${wcost}/\$${wcap})"
  fi
  printf '%s.' "$msg"
}
