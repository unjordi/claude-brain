#!/usr/bin/env bash
# aviso-contexto.sh — PostToolUse hook (tier GLOBAL). Surface datos crudos de contexto.
#
# PRINCIPIO RECTOR (unjordi): el hook es un REPORTERO TONTO de datos, NO un juez.
# Emite los hechos crudos que el LLM no puede ver a mitad de corrida y deja que /context + el LLM
# decidan cuándo compactar. SIN lógica "lista" (bandas de urgencia, veredictos, derivaciones frágiles).
#
# Métrica = TOKENS REALES de contexto. El transcript trae el conteo exacto en el ÚLTIMO `usage`:
#   ctx = input_tokens + cache_creation_input_tokens + cache_read_input_tokens   (NO output_tokens).
#   ANCLADO al último /compact: un `isCompactSummary:true` RESETEA el acumulado, así el usage PRE-compact
#   (que la llamada interna de resumen deja en disco con el tamaño VIEJO completo) NO se reporta como si
#   fuera el contexto vivo (FP de staleness post-compact, 2026-09-01).
#
# Datos que surface:
#   - ctx actual (tokens del último usage DESPUÉS del último boundary de compact).
#   - autoCompactWindow LEÍDO de settings.json (user < proyecto < local; jq '.autoCompactWindow');
#     si no está, reporta "no seteado".
#   - ventana detectada (marcador [1m] / modelos 1M-nativos / default 200K) CON auto-corrección
#     por invariante físico (si ctx > ventana → 1M). Repórtala.
#   - % de esa ventana + % libre (reservando 5% para el checkpoint).
#   NO reporta CLAUDE_AUTOCOMPACT_PCT_OVERRIDE — es un valor FANTASMA que miente (ver NOTA abajo).
#
# Debounce: solo avisa al SUBIR de contexto (no en cada tool-call). Marca .contexto-aviso guarda
# el último ctx visto; si el ctx baja (hubo compact / sesión nueva) se re-arma sola.
#
# Fail-open: sin jq, sin transcript, sin memoria del repo, sin `usage`, o cualquier error → exit 0
# sin ruido. Genérico y stack-agnóstico → se instala GLOBAL (install-brain.sh).
set -u

command -v jq >/dev/null 2>&1 || exit 0        # sin jq → fail-open silencioso

input=$(cat 2>/dev/null || true)
tp=$(printf '%s' "$input" | jq -r '.transcript_path // empty' 2>/dev/null)
{ [ -n "${tp:-}" ] && [ -f "$tp" ]; } || exit 0 # sin transcript → nada que medir

ROOT="${CLAUDE_PROJECT_DIR:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"
MEM="$ROOT/.claude/memory"
[ -d "$MEM" ] || exit 0                          # repo sin el sistema de memoria → no incumbe
AVISO_F="$MEM/.contexto-aviso"

# Tokens de contexto ACTUALES = último `usage`, ANCLADO al último /compact. Un `isCompactSummary:true`
# RESETEA el acumulado (reduce): descarta todo usage previo al boundary. Así, justo tras compactar, el
# usage grande PRE-compact (la llamada interna de resumen manda el contexto completo → su input_tokens es
# el tamaño VIEJO) NO se cuela como "contexto vivo". Si aún no hay ningún usage DESPUÉS del boundary, el
# reduce termina en null → ctx vacío → fail-open (silencio), en vez de gritar el tamaño viejo en falso.
ctx=$(tail -n 400 "$tp" 2>/dev/null | jq -rRn '
    reduce (inputs | fromjson?) as $o (null;
        if   ($o.isCompactSummary == true) then null      # boundary de /compact → descarta lo previo
        elif ($o.isSidechain == true)      then .         # subagente → no cuenta al hilo principal
        elif ($o.message.usage)            then ($o.message.usage
              | (.input_tokens // 0) + (.cache_creation_input_tokens // 0) + (.cache_read_input_tokens // 0))
        else . end)
    // empty
  ' 2>/dev/null | tr -cd '0-9')
[ -n "$ctx" ] || exit 0                          # sin usage fresco (post-compact) aún → fail-open

# Ventana: override explícito `AVISO_CONTEXTO_WINDOW_TOKENS`, o derivada del modelo.
# La ventana de 1M se detecta de DOS formas: (a) marcador "[1m]" en el id, (b) modelos 1M-NATIVOS
# (opus-4-7/4-8/5, sonnet-5, fable-5, mythos-5). Precedencia settings: user < proyecto < local.
WINDOW="${AVISO_CONTEXTO_WINDOW_TOKENS:-}"
case "$WINDOW" in
  ''|*[!0-9]*)
    model=""
    for s in "$HOME/.claude/settings.json" "$ROOT/.claude/settings.json" "$ROOT/.claude/settings.local.json"; do
      [ -f "$s" ] || continue
      m=$(jq -r '.model // empty' "$s" 2>/dev/null)
      [ -n "$m" ] && model="$m"
    done
    case "$model" in
      *'[1m]'*)                                                      WINDOW=1000000 ;;
      *opus-4-7*|*opus-4-8*|*opus-5*|*sonnet-5*|*fable-5*|*mythos-5*) WINDOW=1000000 ;;
      *)                                                             WINDOW=200000  ;;
    esac
    ;;
esac
# AUTO-CORRECCIÓN por invariante FÍSICO: si ctx > ventana detectada, promueve a 1M.
[ "$ctx" -gt "$WINDOW" ] 2>/dev/null && WINDOW=1000000

# autoCompactWindow: leído de settings.json (user < proyecto < local).
ACW="no seteado"
for s in "$HOME/.claude/settings.json" "$ROOT/.claude/settings.json" "$ROOT/.claude/settings.local.json"; do
  [ -f "$s" ] || continue
  acw=$(jq -r '.autoCompactWindow // empty' "$s" 2>/dev/null)
  [ -n "$acw" ] && ACW="$acw"
done

# NOTA: NO se reporta CLAUDE_AUTOCOMPACT_PCT_OVERRIDE. Es un valor FANTASMA: si el env dice 70% pero la
# ventana es 1M y el ctx pasa del 70% SIN que el CLI compacte, ese 70 NO gobierna (env stale / no propagada
# al proceso) → reportarlo MIENTE (unjordi 2026-09-01: "me suena MUY falso"). El dato que SÍ es fiable es el
# ctx crudo + la ventana; el punto de auto-compact real lo sabe /context, no este hook.

# Debounce GRUESO por PASOS de 50K tokens: emite solo al CRUZAR un nuevo escalón de contexto, NO en cada
# tool-call (con `ctx > last_ctx` a secas dispararía casi siempre — el ctx sube monótono → ruido). Al
# compactar (ctx baja) el escalón baja → last_step > step → se re-arma solo para la próxima subida.
STEP=50000
step=$(( ctx / STEP ))
last_step=0
if [ -f "$AVISO_F" ]; then
  read -r last_step < "$AVISO_F" 2>/dev/null || true
  case "${last_step:-}" in ''|*[!0-9]*) last_step=0;; esac
fi
printf '%s\n' "$step" > "$AVISO_F" 2>/dev/null || true
[ "$step" -gt "$last_step" ] || exit 0

# ── Mensaje neutro: datos crudos + recordatorio del orden checkpoint→compact ──────────────────
ctxk=$(( ctx / 1000 ))
wink=$(( WINDOW / 1000 ))
pctw=$(( ctx * 100 / WINDOW ))
# Libre ÚTIL = libre − 5% de RESERVA para el checkpoint mismo (el volcado del hilo consume contexto; no
# esperes a 0% o el checkpoint no cabe). unjordi 2026-09-01.
libre=$(( 100 - pctw - 5 )); [ "$libre" -lt 0 ] && libre=0

msg="📊 Contexto: ${ctxk}K tokens (~${pctw}% de tu ventana ${wink}K, ${libre}% libre — reservé 5% para el checkpoint). autoCompactWindow: ${ACW}."
# Cierre NEUTRO: dato + deferencia, sin veredicto. El hook REPORTA (dónde está el número autoritativo, qué
# hace el CLI); NO recomienda un curso ("mejor checkpoint+compact"). La decisión es del lector (unjordi:
# "cada quién decide cómo morirse"; /context manda).
msg="${msg}"$'\n'"/context tiene el número autoritativo; el auto-compact del CLI dispara al llenarse la ventana. TÚ decides qué hacer (seguir / checkpoint / compact)."

jq -n --arg c "$msg" '{hookSpecificOutput:{hookEventName:"PostToolUse",additionalContext:$c}}'
exit 0
