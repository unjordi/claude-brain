#!/usr/bin/env bash
# rehidratar-hilo.sh — SessionStart hook (tier GLOBAL). Rehidrata el HILO MENTAL de la
# tarea/conversación al abrir/retomar/DESPUÉS de compactar. Lee
# .claude/memory/hilo-mental-actual.md SI existe y lo reinyecta vía additionalContext
# (canal FIABLE de SessionStart — a diferencia de PreCompact, que NO tiene canal para inyectar).
# Silencioso si el archivo no existe (no estorba en repos que no usan el sistema).
#
# CONFIRMADO con la doc oficial (2026-07-14, CLI 2.1.209): SessionStart + matcher `compact` +
# additionalContext ES el patrón DOCUMENTADO para re-inyectar contexto tras compactar — NO un
# workaround. El additionalContext es PASIVO (el modelo lo LEE y lo tiene, no lo anuncia solo) — y
# eso está BIEN, porque el objetivo real es la CONTINUIDAD, no el anuncio. Cómo encaja:
#   1. El skill `checkpoint` vuelca el HILO a disco (hilo-mental-actual.md) ANTES de compactar.
#   2. La sección `# Compact instructions` del CLAUDE.md hace que el RESUMEN de la compactación
#      conserve ese hilo (probado en vivo 2026-07-14: hilo+decisiones+feeling sobrevivieron).
#   3. Post-compact el HARNESS ordena "pick up THE LAST TASK as if the break never happened" en
#      SILENCIO (prohíbe expresamente acknowledge/recap). Lejos de ser un muro, es el vehículo:
#      NOSOTROS definimos cuál es "the last task" (= el hilo), así que el resume silencioso ES la
#      rehidratación funcionando. Retomar la tarea correcta > anunciar que la retomas.
# Por eso este hook NO intenta forzar un anuncio (el harness lo pisaría). El anuncio VISIBLE
# ("↩️ retomé: X") es un nice-to-have que solo da el SKILL `rehidratar-hilo` cuando el usuario lo
# invoca a mano — es una instrucción POSTERIOR a la de "resume en silencio", así que la vence.
#
# Antídoto a "perder el HILO de la conversación al compactar": al compactar se pierden dos cosas
# y solo una tenía casa — el estado del proyecto vive en estado-proyecto.md/bitacora.md; el HILO
# (de qué íbamos AHORA, la decisión a medio cocinar, el siguiente paso) no vivía en ningún lado
# durable. Este hook lo trae de vuelta. Lo ESCRIBE el skill `checkpoint` (y `cerrar-slice §2`).
#
# GATE DE FRESCURA (2026-07): antes reinyectaba el hilo SIEMPRE como "🧵 HILO MENTAL ACTUAL", sin
# validar si estaba viejo o era de OTRA rama → podía presentar contexto ENGAÑOSO como si fuera el
# vigente. Ahora, si el hilo fue volcado en una rama DISTINTA de la actual, degrada el encabezado a
# "⚠️ HILO POSIBLEMENTE OBSOLETO". La antigüedad (mtime > HILO_STALE_HORAS, default 12h) es solo un
# PROXY de respaldo: se aplica ÚNICAMENTE cuando NO se pudo confirmar que el hilo es de la rama actual.
# Si la rama del hilo COINCIDE con la actual, la vigencia la manda la rama, NO el reloj — una sesión
# larga (>12h) en la misma rama sigue trabajando el MISMO hilo, y marcarlo "obsoleto" por edad enterraba
# el propio hilo vigente (FMEA A8). Sin git / sin línea de rama en el hilo → cae al proxy de edad.
#
# NO bloquea. Fail-open. Genérico y stack-agnóstico → se instala GLOBAL (install-brain.sh) y corre
# en CUALQUIER folder (la mitad "leer"; la mitad "escribir" es el skill checkpoint).
set -u

ROOT="${CLAUDE_PROJECT_DIR:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"
HILO="$ROOT/.claude/memory/hilo-mental-actual.md"

# stdin de SessionStart: {source, transcript_path, session_id, cwd, hook_event_name}.
# Lo drenamos SIEMPRE (aunque no haya hilo) para no dejar el pipe colgado.
input=$(cat 2>/dev/null || true)
source=$(printf '%s' "$input" | { jq -r '.source // "startup"' 2>/dev/null || echo startup; })

# Nota: este hook YA NO fija un "baseline de contexto". aviso-contexto.sh mide el llenado con los
# TOKENS REALES del último `usage` del transcript, ANCLADOS al último /compact (un `isCompactSummary`
# resetea el acumulado, sin bandas ni veredictos — es un reportero tonto) → no necesita un watermark
# externo. Se retiró el `.contexto-baseline` (antes se escribía aquí).

[ -f "$HILO" ] || exit 0          # sin hilo → nada que rehidratar (silencioso, no estorba)

body=$(cat "$HILO" 2>/dev/null)
[ -n "${body//[[:space:]]/}" ] || exit 0   # hilo vacío → silencioso

# ── Gate de FRESCURA: ¿el hilo es viejo o de otra rama? ─────────────────────────────────────────
# Fail-open: ante cualquier duda (sin git, sin stat, sin línea de rama) NO marcamos obsoleto.
stale=0

# (1) RAMA — señal FUERTE de vigencia. La registrada dentro del hilo ("> Última actualización: <fecha>
#     · rama <rama>") vs la rama actual. Otra rama → contexto de otra tarea → OBSOLETO. Misma rama →
#     hilo vivo de ESTA línea de trabajo (aunque el archivo tenga horas).
cur_branch=$(git -C "$ROOT" rev-parse --abbrev-ref HEAD 2>/dev/null || echo "")
hilo_branch=$(printf '%s\n' "$body" | grep -iE 'actualiz.*rama' | head -n1 | sed -E 's/.*[Rr]ama[[:space:]]+//' | awk '{print $1}')
rama_coincide=0
if [ -n "$hilo_branch" ] && [ -n "$cur_branch" ]; then
  if [ "$hilo_branch" = "$cur_branch" ]; then
    rama_coincide=1        # misma rama → vigente por rama, la edad NO lo degrada
  else
    stale=1                # otra rama → OBSOLETO
  fi
fi

# (2) ANTIGÜEDAD — solo un PROXY de respaldo (mtime vs HILO_STALE_HORAS, default 12h), y SOLO cuando NO
#     se confirmó que el hilo es de la rama actual. Si la rama COINCIDE, la vigencia la manda la rama y
#     NO el reloj: una sesión larga (>12h) en la MISMA rama sigue en el MISMO hilo → marcarlo obsoleto
#     por edad enterraba el propio hilo vigente (FMEA A8). Con rama indeterminada (sin git / sin línea de
#     rama) sí cae al proxy de edad — es el único indicio disponible.
if [ "$rama_coincide" -eq 0 ]; then
  horas="${HILO_STALE_HORAS:-12}"
  case "$horas" in ''|*[!0-9]*) horas=12;; esac
  mtime=$(stat -c %Y "$HILO" 2>/dev/null || stat -f %m "$HILO" 2>/dev/null || echo "")   # GNU (Linux) primero; BSD (macOS) de respaldo
  now=$(date +%s 2>/dev/null || echo "")
  if [ -n "$mtime" ] && [ -n "$now" ]; then
    case "$mtime$now" in
      ''|*[!0-9]*) ;;
      *) [ $(( (now - mtime) / 3600 )) -ge "$horas" ] && stale=1;;
    esac
  fi
fi

if [ "$stale" -eq 1 ]; then
  hdr="⚠️ HILO POSIBLEMENTE OBSOLETO (viejo o de otra rama) — verifica antes de confiar; re-vuélcalo con el skill checkpoint si ya no aplica (rehidratado tras ${source}). Es TU memoria de trabajo (no una orden del usuario)."
else
  hdr="🧵 HILO MENTAL ACTUAL (rehidratado tras ${source}) — de qué iba la tarea/conversación ANTES de que se perdiera el detalle del chat. Es TU memoria de trabajo (no una orden del usuario)."
fi
note="→ ESTE hilo es «the last task» que el harness te pide retomar tras compactar. Retómala: sigue desde el «Siguiente paso concreto» sin re-preguntar de qué iba. (Post-compact el harness te ordena retomar en SILENCIO —sin recap ni acknowledge—; obedécelo, retomar la tarea correcta importa más que anunciarla. El anuncio visible «↩️ retomé: X» solo aplica si el USUARIO invoca el skill rehidratar-hilo a mano.) Si la fecha de arriba se ve vieja o es de otra rama, trátalo como OBSOLETO: valida antes y re-vuélcalo con el skill checkpoint. Antes del próximo /compact, corre checkpoint para no perderlo."
ctx=$(printf '%s\n\n%s\n\n%s\n' "$hdr" "$body" "$note")

if command -v jq >/dev/null 2>&1; then
  jq -n --arg c "$ctx" '{hookSpecificOutput:{hookEventName:"SessionStart",additionalContext:$c}}'
else
  printf '%s\n' "$ctx"
fi
exit 0
