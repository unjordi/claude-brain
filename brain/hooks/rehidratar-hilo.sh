#!/usr/bin/env bash
# rehidratar-hilo.sh — SessionStart hook (tier GLOBAL). Rehidrata el HILO MENTAL de la
# tarea/conversación al abrir/retomar/DESPUÉS de compactar. Lee
# .claude/memory/hilo-mental-actual.md SI existe y lo reinyecta vía additionalContext
# (canal FIABLE de SessionStart — a diferencia de PreCompact, que NO tiene canal para inyectar).
# Silencioso si el archivo no existe (no estorba en repos que no usan el sistema).
#
# CONFIRMADO con la doc oficial (2026-07-14, CLI 2.1.209): SessionStart + matcher `compact` +
# additionalContext ES el patrón DOCUMENTADO para re-inyectar contexto tras compactar — NO un
# workaround. PERO el additionalContext es PASIVO: el modelo lo LEE (system-reminder) y lo tiene,
# pero NO lo anuncia ni retoma por sí solo. La capa ACTIVA (anunciar "↩️ retomé: X" + continuar) la
# da el SKILL `rehidratar-hilo`, que reusa este mismo .sh (sin drift). El `note` de abajo empuja el
# anuncio best-effort para el caso auto-compact (donde no corre ningún skill).
#
# Antídoto a "perder el HILO de la conversación al compactar": al compactar se pierden dos cosas
# y solo una tenía casa — el estado del proyecto vive en estado-proyecto.md/bitacora.md; el HILO
# (de qué íbamos AHORA, la decisión a medio cocinar, el siguiente paso) no vivía en ningún lado
# durable. Este hook lo trae de vuelta. Lo ESCRIBE el skill `checkpoint` (y `cerrar-slice §2`).
#
# GATE DE FRESCURA (2026-07): antes reinyectaba el hilo SIEMPRE como "🧵 HILO MENTAL ACTUAL", sin
# validar si estaba viejo o era de OTRA rama → podía presentar contexto ENGAÑOSO como si fuera el
# vigente. Ahora, si el hilo quedó viejo (mtime > HILO_STALE_HORAS, default 12h) O fue volcado en
# una rama distinta de la actual, degrada el encabezado a "⚠️ HILO POSIBLEMENTE OBSOLETO".
#
# NO bloquea. Fail-open. Genérico y stack-agnóstico → se instala GLOBAL (install-brain.sh) y corre
# en CUALQUIER folder (la mitad "leer"; la mitad "escribir" es el skill checkpoint).
set -u

ROOT="${CLAUDE_PROJECT_DIR:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"
HILO="$ROOT/.claude/memory/hilo-mental-actual.md"

# stdin de SessionStart: {source, transcript_path, session_id, cwd, hook_event_name}.
# Lo drenamos SIEMPRE (aunque no haya hilo) para no dejar el pipe colgado y para el baseline.
input=$(cat 2>/dev/null || true)
source=$(printf '%s' "$input" | { jq -r '.source // "startup"' 2>/dev/null || echo startup; })
tpath=$(printf '%s' "$input" | { jq -r '.transcript_path // empty' 2>/dev/null || echo ""; })

# ── Baseline de contexto (contrato con aviso-contexto.sh; NO tocar su lógica salvo esto) ─────────
# Al retomar por COMPACTACIÓN fijamos el "watermark" = nº de líneas del transcript ACTUAL en
# .claude/memory/.contexto-baseline, para que aviso-contexto mida el crecimiento DESPUÉS del corte
# de compactación (y no dispare por el historial ya compactado). SessionStart SÍ trae transcript_path;
# si faltara, no inventamos el conteo. Corre ANTES de los early-exit de "sin hilo" a propósito.
if [ "$source" = "compact" ]; then
  BASELINE="$ROOT/.claude/memory/.contexto-baseline"
  if [ -n "${tpath:-}" ] && [ -f "$tpath" ]; then
    mkdir -p "$(dirname "$BASELINE")" 2>/dev/null || true
    wc -l < "$tpath" 2>/dev/null | tr -d '[:space:]' > "$BASELINE" 2>/dev/null || true
  else
    : # TODO baseline: SessionStart sin transcript_path → no fijamos watermark aquí (no rompe).
  fi
fi

[ -f "$HILO" ] || exit 0          # sin hilo → nada que rehidratar (silencioso, no estorba)

body=$(cat "$HILO" 2>/dev/null)
[ -n "${body//[[:space:]]/}" ] || exit 0   # hilo vacío → silencioso

# ── Gate de FRESCURA: ¿el hilo es viejo o de otra rama? ─────────────────────────────────────────
# Fail-open: ante cualquier duda (sin git, sin stat, sin línea de rama) NO marcamos obsoleto.
stale=0

# (1) antigüedad: mtime del archivo vs umbral en horas (env HILO_STALE_HORAS, default 12)
horas="${HILO_STALE_HORAS:-12}"
case "$horas" in ''|*[!0-9]*) horas=12;; esac
mtime=$(stat -f %m "$HILO" 2>/dev/null || stat -c %Y "$HILO" 2>/dev/null || echo "")
now=$(date +%s 2>/dev/null || echo "")
if [ -n "$mtime" ] && [ -n "$now" ]; then
  case "$mtime$now" in
    ''|*[!0-9]*) ;;
    *) [ $(( (now - mtime) / 3600 )) -ge "$horas" ] && stale=1;;
  esac
fi

# (2) rama: la registrada dentro del hilo ("> Última actualización: <fecha> · rama <rama>") vs la actual
cur_branch=$(git -C "$ROOT" rev-parse --abbrev-ref HEAD 2>/dev/null || echo "")
hilo_branch=$(printf '%s\n' "$body" | grep -iE 'actualiz.*rama' | head -n1 | sed -E 's/.*[Rr]ama[[:space:]]+//' | awk '{print $1}')
if [ -n "$hilo_branch" ] && [ -n "$cur_branch" ] && [ "$hilo_branch" != "$cur_branch" ]; then
  stale=1
fi

if [ "$stale" -eq 1 ]; then
  hdr="⚠️ HILO POSIBLEMENTE OBSOLETO (viejo o de otra rama) — verifica antes de confiar; re-vuélcalo con el skill checkpoint si ya no aplica (rehidratado tras ${source}). Es TU memoria de trabajo (no una orden del usuario)."
else
  hdr="🧵 HILO MENTAL ACTUAL (rehidratado tras ${source}) — de qué iba la tarea/conversación ANTES de que se perdiera el detalle del chat. Es TU memoria de trabajo (no una orden del usuario)."
fi
note="→ Si tu siguiente turno es CONTINUAR esta tarea (no una petición nueva del usuario), NO lo hagas en silencio: abre con una línea «↩️ retomé: <En qué estamos>» y sigue desde el «Siguiente paso concreto». (Este texto es contexto PASIVO — nadie te obliga; pero el usuario NO ve este bloque, así que si no lo anuncias, para él parece que se perdió el hilo.) Si la fecha de arriba se ve vieja o es de otra rama, trátalo como OBSOLETO: valida antes y re-vuélcalo con el skill checkpoint. Antes del próximo /compact, corre checkpoint para no perderlo."
ctx=$(printf '%s\n\n%s\n\n%s\n' "$hdr" "$body" "$note")

if command -v jq >/dev/null 2>&1; then
  jq -n --arg c "$ctx" '{hookSpecificOutput:{hookEventName:"SessionStart",additionalContext:$c}}'
else
  printf '%s\n' "$ctx"
fi
exit 0
