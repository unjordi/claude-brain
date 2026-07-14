#!/usr/bin/env bash
# aviso-contexto.sh — PostToolUse hook (tier GLOBAL). Convierte el AUTO-COMPACT-SORPRESA en un caso RARO.
#
# Problema: el auto-compact (contexto lleno) dispara SOLO, SIN aviso, y a menudo sin que se haya corrido
# el skill `checkpoint` → se pierde el HILO reciente. `precompact` NO puede ayudar (PreCompact no tiene
# canal para inyectar contexto ni pedir acción; por eso se retiró). Este hook vigila cuánto CRECIÓ el
# contexto desde el último /compact y, al cruzar una banda POR DEBAJO del punto de auto-compact, INYECTA
# un aviso para que el modelo vuelque con `checkpoint` y proponga al usuario un /compact PROACTIVO (holgura).
#
# Por qué PostToolUse (y no Stop/UserPromptSubmit): es el ÚNICO evento que dispara DURANTE una corrida
# autónoma larga (muchos tool-calls sin turno del usuario) — justo cuando el auto-compact golpea. Stop
# solo dispara al FIN del turno (se lo pierde a mitad de una ráfaga); UserPromptSubmit no dispara nada
# mientras el modelo trabaja solo. El costo (fire por cada tool) se paga con el debounce por BANDA.
#
# Métrica (proxy): líneas del transcript. baseline = líneas en el último /compact, guardadas en
# .claude/memory/.contexto-baseline (gitignored) — la ESCRIBE/resetea `rehidratar-hilo` en source=compact;
# aquí solo se LEE (si falta, baseline=0). delta = líneas_actuales − baseline. Líneas != tokens exactos,
# pero el crecimiento monótono del transcript es un proxy fiel del llenado del contexto.
#
# Debounce: solo avisa al cruzar una BANDA nueva (delta/UMBRAL). La marca .contexto-aviso guarda
# "<baseline_visto> <última_banda>"; si el baseline cambió (hubo compact) la banda se olvida (auto-cura).
#
# Fail-open: sin jq, sin transcript, sin memoria del repo, o cualquier error → exit 0 sin ruido.
# Genérico y stack-agnóstico → se instala GLOBAL (install-brain.sh). Pareja de `checkpoint` (vuelca) y
# `rehidratar-hilo` (resetea el baseline y reinyecta el hilo tras compactar).
set -u

command -v jq >/dev/null 2>&1 || exit 0        # sin jq no podemos emitir JSON → fail-open silencioso

input=$(cat 2>/dev/null || true)
tp=$(printf '%s' "$input" | jq -r '.transcript_path // empty' 2>/dev/null)
{ [ -n "${tp:-}" ] && [ -f "$tp" ]; } || exit 0 # sin transcript → nada que medir

ROOT="${CLAUDE_PROJECT_DIR:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"
MEM="$ROOT/.claude/memory"
[ -d "$MEM" ] || exit 0                          # repo sin el sistema de memoria → no incumbe
BASELINE_F="$MEM/.contexto-baseline"
AVISO_F="$MEM/.contexto-aviso"

# Umbral (ancho de banda) tunable por env; guarda contra basura → default razonable.
UMBRAL="${AVISO_CONTEXTO_UMBRAL:-1500}"
case "$UMBRAL" in ''|*[!0-9]*) UMBRAL=1500;; esac
[ "$UMBRAL" -gt 0 ] 2>/dev/null || UMBRAL=1500

# Líneas actuales del transcript (proxy del crecimiento del contexto).
cur=$(wc -l < "$tp" 2>/dev/null | tr -cd '0-9')
[ -n "$cur" ] || exit 0

# baseline = líneas en el último /compact (la escribe rehidratar-hilo en source=compact). Falta → 0.
baseline=0
if [ -f "$BASELINE_F" ]; then
  b=$(tr -cd '0-9' < "$BASELINE_F" 2>/dev/null)
  [ -n "$b" ] && baseline="$b"
fi

# Marca de debounce: "<baseline_visto> <última_banda_avisada>".
seen_base=-1; last_band=0
if [ -f "$AVISO_F" ]; then
  read -r seen_base last_band _ < "$AVISO_F" 2>/dev/null || true
  case "${seen_base:-}" in ''|*[!0-9]*) seen_base=-1;; esac
  case "${last_band:-}" in ''|*[!0-9]*) last_band=0;; esac
fi
# Si el baseline cambió (un /compact lo reseteó), olvidamos la banda avisada → empezamos de cero.
[ "$seen_base" = "$baseline" ] || last_band=0

# delta y banda (clamp a 0 por si el transcript rotó/encogió).
delta=$(( cur - baseline )); [ "$delta" -gt 0 ] || delta=0
band=$(( delta / UMBRAL ))

# Persistimos SIEMPRE el baseline visto (auto-cura el reset); la banda solo sube.
new_band=$last_band
[ "$band" -gt "$new_band" ] && new_band=$band
printf '%s %s\n' "$baseline" "$new_band" > "$AVISO_F" 2>/dev/null || true

# ¿Cruzamos una banda NUEVA (>=1)? Si no, silencio (debounce).
{ [ "$band" -ge 1 ] && [ "$band" -gt "$last_band" ]; } || exit 0

msg="⚠️ Contexto creciendo (~${delta} líneas de transcript desde el último /compact). Vuelca el hilo con el skill checkpoint y PROPÓN al usuario un /compact PROACTIVO ahora, con holgura, antes de que el auto-compact (contexto lleno, SIN aviso) te gane y se pierda el hilo reciente."

jq -n --arg c "$msg" '{hookSpecificOutput:{hookEventName:"PostToolUse",additionalContext:$c}}'
exit 0
