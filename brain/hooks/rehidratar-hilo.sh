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
# invoca a mano.
#
# Antídoto a "perder el HILO de la conversación al compactar": al compactar se pierden dos cosas
# y solo una tenía casa — el estado del proyecto vive en estado-proyecto.md/bitacora.md; el HILO
# (de qué íbamos AHORA, la decisión a medio cocinar, el siguiente paso) no vivía en ningún lado
# durable. Este hook lo trae de vuelta. Lo ESCRIBE el skill `checkpoint` (y `cerrar-slice §2`).
#
# ── EL ANDAMIO MECÁNICO (2026-09-11): este hook es la MITAD LECTORA de DOS productores ────────────
# Desde que existe `checkpoint-mecanico` (hook de PreCompact + `bin/checkpoint-mecanico.js`), el hilo
# ya no es el único artefacto que cruza la frontera del compact. El andamio
# (`hilo-mental-actual.andamio.md`) lo escribe una MÁQUINA, sin turno del modelo, justo cuando la
# ventana se va a perder — y describe el tramo VIVO (archivos tocados, commits, citas textuales del
# usuario, métricas). Hasta hoy NADIE lo leía: el productor estaba externalizado y el consumo seguía
# dependiendo de que el modelo se acordara de abrirlo — es decir, de la MISMA disciplina que el
# andamio existe para no necesitar. En el escenario que lo motiva (el auto-compact GANA la carrera y
# no hubo checkpoint), el hilo reinyectado es el VIEJO y el andamio —que describe justo el tramo
# perdido— se quedaba en disco sin lector. Este hook cierra ese lazo.
# REGLA DURA: el andamio NUNCA se presenta como el hilo. Son dos cosas de naturaleza distinta
# (juicio vs traza) y van con encabezados distintos, SIEMPRE. Mezclarlos sería peor que no inyectarlo:
# haría pasar una lista mecánica por el razonamiento del modelo.
#
# GATE DE FRESCURA (2026-07): antes reinyectaba el hilo SIEMPRE como "🧵 HILO MENTAL ACTUAL", sin
# validar si estaba viejo o era de OTRA rama → podía presentar contexto ENGAÑOSO como si fuera el
# vigente. Ahora, si el hilo fue volcado en una rama DISTINTA de la actual, degrada el encabezado a
# "⚠️ HILO POSIBLEMENTE OBSOLETO". La antigüedad (mtime > HILO_STALE_HORAS, default 12h) es solo un
# PROXY de respaldo: se aplica ÚNICAMENTE cuando NO se pudo confirmar que el hilo es de la rama actual.
# Si la rama del hilo COINCIDE con la actual, la vigencia la manda la rama, NO el reloj — una sesión
# larga (>12h) en la misma rama sigue trabajando el MISMO hilo, y marcarlo "obsoleto" por edad enterraba
# el propio hilo vigente (FMEA A8). Sin git / sin línea de rama en el hilo → cae al proxy de edad.
# AÑADIDO 2026-09-11: el encabezado reporta SIEMPRE la EDAD del volcado, coincida la rama o no. En una
# rama PERMANENTE (`develop`, `Develop<Usuario>`, `main`) la rama no discrimina —nunca cambia—, así que
# el gate da FRESCO por construcción y un hilo de días se presenta como vigente. La edad es un DATO, no
# un veredicto: no afloja el gate (sigue mandando la rama), le añade lo que al lector le falta para juzgar.
#
# NO bloquea. Fail-open. Genérico y stack-agnóstico → se instala GLOBAL (install-brain.sh) y corre
# en CUALQUIER folder (la mitad "leer"; la mitad "escribir" es el skill checkpoint).
set -u

ROOT="${CLAUDE_PROJECT_DIR:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"
HILO="$ROOT/.claude/memory/hilo-mental-actual.md"
ANDAMIO="$ROOT/.claude/memory/hilo-mental-actual.andamio.md"

# El CONTRATO del footer (`· rama <x>`) vive en UNA sola definición, compartida con el skill
# `checkpoint` (que la corre al volcar) y con test-brain. Si la lib no está —un install viejo, o el
# hook copiado suelto—, se usa la misma extracción inline: fail-open, nunca romper el arranque de sesión.
_selfdir="$(dirname "$0")"
if [ -f "$_selfdir/contrato-hilo.sh" ]; then
  # shellcheck source=contrato-hilo.sh
  . "$_selfdir/contrato-hilo.sh"
else
  hilo_rama() {
    [ -f "${1:-}" ] || return 0
    grep -E '·[[:space:]]+[Rr]ama[[:space:]]' "$1" 2>/dev/null | head -n1 \
      | sed -E 's/.*·[[:space:]]+[Rr]ama[[:space:]]+//' | awk '{print $1}' | tr -d '`*"'
  }
  hilo_edad_legible() {
    _s="${1:-0}"; case "$_s" in ''|*[!0-9]*) printf 'edad desconocida'; return 0 ;; esac
    _d=$(( _s / 86400 )); _h=$(( (_s % 86400) / 3600 )); _m=$(( (_s % 3600) / 60 ))
    if   [ "$_d" -gt 0 ]; then printf '%sd %sh' "$_d" "$_h"
    elif [ "$_h" -gt 0 ]; then printf '%sh %sm' "$_h" "$_m"
    else                       printf '%sm' "$_m"; fi
  }
fi

# stdin de SessionStart: {source, transcript_path, session_id, cwd, hook_event_name}.
# Lo drenamos SIEMPRE (aunque no haya hilo) para no dejar el pipe colgado.
input=$(cat 2>/dev/null || true)
source=$(printf '%s' "$input" | { jq -r '.source // "startup"' 2>/dev/null || echo startup; })
sid_actual=$(printf '%s' "$input" | { jq -r '.session_id // ""' 2>/dev/null || echo ""; })

# Nota: este hook YA NO fija un "baseline de contexto". aviso-contexto.sh mide el llenado con los
# TOKENS REALES del último `usage` del transcript, ANCLADOS al último /compact (un `isCompactSummary`
# resetea el acumulado, sin bandas ni veredictos — es un reportero tonto) → no necesita un watermark
# externo. Se retiró el `.contexto-baseline` (antes se escribía aquí).

_mtime() { stat -c %Y "$1" 2>/dev/null || stat -f %m "$1" 2>/dev/null || echo ""; }   # GNU primero; BSD de respaldo
_no_vacio() { [ -f "$1" ] && [ -n "$(tr -d '[:space:]' < "$1" 2>/dev/null)" ]; }
hay_hilo=0; hay_andamio=0
_no_vacio "$HILO"    && hay_hilo=1
_no_vacio "$ANDAMIO" && hay_andamio=1
# Sin NINGUNO de los dos → nada que rehidratar. Silencioso en general (no estorba en repos sin el
# sistema), pero NO tras un compact: ahí "sin artefactos" es el modo de falla que hace que el checkpoint
# se ignore — el detalle de la conversación se degradó en el resumen, no hay volcado NI traza mecánica
# que lo recupere, y la pérdida es INVISIBLE hasta que ya costó. El aviso es VISIBLE (systemMessage, no
# additionalContext pasivo) y apunta al transcript, que sí sobrevivió. Se emite solo cuando faltan LOS
# DOS: con andamio presente no hace falta avisar de una pérdida que la máquina ya cubrió con evidencia.
if [ "$hay_hilo" -eq 0 ] && [ "$hay_andamio" -eq 0 ]; then
  if [ "$source" = "compact" ] && [ -f "$ROOT/.claude/memory/estado-proyecto.md" ]; then
    tp=$(printf '%s' "$input" | { jq -r '.transcript_path // empty' 2>/dev/null || echo ""; })
    aviso="⚠️ Compactaste SIN hilo mental fresco y SIN andamio (no existe ni .claude/memory/hilo-mental-actual.md ni su andamio mecánico). El detalle de la conversación se degradó en el resumen y NO hay volcado que lo recupere. Reconstruye del transcript${tp:+ ($tp)} + estado-proyecto.md/bitacora ANTES de seguir, y corre el skill checkpoint antes del próximo /compact para no repetirlo."
    if command -v jq >/dev/null 2>&1; then
      jq -n --arg m "$aviso" '{systemMessage:$m}'
    else
      printf '%s\n' "$aviso"   # sin jq: cae a additionalContext pasivo (mejor que perderlo)
    fi
  fi
  exit 0
fi

now=$(date +%s 2>/dev/null || echo "")
mt_hilo=""; mt_and=""
[ "$hay_hilo" -eq 1 ]    && mt_hilo=$(_mtime "$HILO")
[ "$hay_andamio" -eq 1 ] && mt_and=$(_mtime "$ANDAMIO")

ctx=""
if [ "$hay_hilo" -eq 1 ]; then
  body=$(cat "$HILO" 2>/dev/null)

  # ── Gate de FRESCURA: ¿el hilo es viejo o de otra rama? ─────────────────────────────────────────
  # Fail-open: ante cualquier duda (sin git, sin stat, sin línea de rama) NO marcamos obsoleto.
  stale=0

  # (1) RAMA — señal FUERTE de vigencia. La registrada dentro del hilo ("> Última actualización: <fecha>
  #     · rama <rama>") vs la rama actual. Otra rama → contexto de otra tarea → OBSOLETO. Misma rama →
  #     hilo vivo de ESTA línea de trabajo (aunque el archivo tenga horas). La extracción vive en
  #     `contrato-hilo.sh` (una sola definición, compartida con quien ESCRIBE el hilo) y está ANCLADA al
  #     separador `·`: cierra el `.*[Rr]ama` goloso (FMEA A8: `feat/diagrama-x` → `-x`) y la prosa con
  #     "de rama X" (la prosa no lleva `· rama`).
  cur_branch=$(git -C "$ROOT" rev-parse --abbrev-ref HEAD 2>/dev/null || echo "")
  hilo_branch=$(hilo_rama "$HILO")
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
    if [ -n "$mt_hilo" ] && [ -n "$now" ]; then
      case "$mt_hilo$now" in
        ''|*[!0-9]*) ;;
        *) [ $(( (now - mt_hilo) / 3600 )) -ge "$horas" ] && stale=1;;
      esac
    fi
  fi

  # La EDAD como DATO en el encabezado (no como veredicto): en una rama permanente el gate de rama no
  # discrimina y un hilo de días sale "FRESCO" sin que el lector pueda notarlo.
  edad_txt=""
  if [ -n "$mt_hilo" ] && [ -n "$now" ]; then
    case "$mt_hilo$now" in
      ''|*[!0-9]*) ;;
      *) edad_txt=" · volcado hace $(hilo_edad_legible $(( now - mt_hilo )))";;
    esac
  fi
  rama_txt=""; [ -n "$hilo_branch" ] && rama_txt=" · rama ${hilo_branch}"

  if [ "$stale" -eq 1 ]; then
    hdr="⚠️ HILO POSIBLEMENTE OBSOLETO (viejo o de otra rama${rama_txt}${edad_txt}) — verifica antes de confiar; re-vuélcalo con el skill checkpoint si ya no aplica (rehidratado tras ${source}). Es TU memoria de trabajo (no una orden del usuario)."
  else
    hdr="🧵 HILO MENTAL ACTUAL (rehidratado tras ${source}${rama_txt}${edad_txt}) — de qué iba la tarea/conversación ANTES de que se perdiera el detalle del chat. Es TU memoria de trabajo (no una orden del usuario). La EDAD es un dato: si te suena vieja para lo que sigue, valida antes de confiar."
  fi
  note="→ ESTE hilo es «the last task» que el harness te pide retomar tras compactar. Retómala: sigue desde el «Siguiente paso concreto» sin re-preguntar de qué iba. (Post-compact el harness te ordena retomar en SILENCIO —sin recap ni acknowledge—; obedécelo, retomar la tarea correcta importa más que anunciarla. El anuncio visible «↩️ retomé: X» solo aplica si el USUARIO invoca el skill rehidratar-hilo a mano.) Si la fecha de arriba se ve vieja o es de otra rama, trátalo como OBSOLETO: valida antes y re-vuélcalo con el skill checkpoint. Antes del próximo /compact, corre checkpoint para no perderlo."
  ctx=$(printf '%s\n\n%s\n\n%s\n' "$hdr" "$body" "$note")
fi

# ── El ANDAMIO: se inyecta cuando es MÁS FRESCO que el hilo (o cuando no hay hilo). Ese es justo el
#    caso que lo motiva: el auto-compact ganó la carrera, el hilo quedó viejo y la máquina alcanzó a
#    dejar la traza del tramo perdido. Si el hilo es más fresco, el modelo ya lo fusionó al volcar
#    (el skill lo exige) → se MENCIONA en una línea y no se re-inyecta: no gastar ventana dos veces.
if [ "$hay_andamio" -eq 1 ]; then
  and_mas_fresco=0
  if [ "$hay_hilo" -eq 0 ]; then
    and_mas_fresco=1
  elif [ -n "$mt_and" ] && [ -n "$mt_hilo" ]; then
    case "$mt_and$mt_hilo" in
      ''|*[!0-9]*) ;;
      *) [ "$mt_and" -gt "$mt_hilo" ] && and_mas_fresco=1;;
    esac
  fi

  if [ "$and_mas_fresco" -eq 1 ]; then
    # Cota de inyección: el andamio lleva hasta 12 mensajes del usuario verbatim y varias listas; sin
    # tope, rehidratar podría costar más ventana de la que ahorra — irónico en una pieza de continuidad.
    maxl="${ANDAMIO_MAX_LINEAS:-140}"
    case "$maxl" in ''|*[!0-9]*) maxl=140 ;; esac
    total=$(wc -l < "$ANDAMIO" 2>/dev/null | tr -d ' ')
    case "$total" in ''|*[!0-9]*) total=0 ;; esac
    abody=$(head -n "$maxl" "$ANDAMIO" 2>/dev/null)
    corte=""
    [ "$total" -gt "$maxl" ] && corte=$(printf '\n…[cortado en %s de %s líneas — el resto en %s]' "$maxl" "$total" "$ANDAMIO")
    aedad=""
    if [ -n "$mt_and" ] && [ -n "$now" ]; then
      case "$mt_and$now" in
        ''|*[!0-9]*) ;;
        *) aedad=" · generado hace $(hilo_edad_legible $(( now - mt_and )))";;
      esac
    fi
    # ¿es MÍO este andamio? El andamio es per-REPO (un archivo por repo) pero lo escribe UNA sesión, y
    # su cabecera declara cuál. Dos casos reales en que el del disco es AJENO: otra sesión trabajó en
    # este repo, o el master acaba de MUDARSE aquí (su hilo llegó co-ubicado y el `hilo-mental-actual.md`
    # y el andamio de este repo son del stream que ya vivía acá). Inyectarlo sin decirlo repetiría, con
    # la evidencia, el modo de falla que el gate del hilo existe para evitar: presentar contexto AJENO
    # como propio. No se oculta ni se suprime — se ETIQUETA, que es lo que el lector necesita.
    asid=$(grep -m1 '^- Sesión (sid): ' "$ANDAMIO" 2>/dev/null | sed 's/^- Sesión (sid): //' | tr -d ' ')
    aajeno=""
    if [ -n "$asid" ] && [ -n "$sid_actual" ] && [ "$asid" != "$sid_actual" ] \
       && [ "$asid" != "(no disponible)" ]; then
      aajeno=" ⚠️ DE OTRA SESIÓN ($asid, no la tuya): trátalo como contexto AJENO — puede ser de otro stream de trabajo en este mismo repo, o del repo al que te acabas de mudar. Verifica antes de apoyarte en él, y regenera el tuyo con \`checkpoint-mecanico.js --self --ensure\`."
    fi
    ahdr="🤖 ANDAMIO MECÁNICO — NO es el hilo y NO es juicio${aedad}.${aajeno} Lo extrajo una máquina del transcript (bin/checkpoint-mecanico.js), sin turno del modelo, del TRAMO VIVO desde el último /compact. Está aquí porque es MÁS FRESCO que el hilo de arriba: describe el tramo que el hilo NO alcanzó a cubrir. Trátalo como EVIDENCIA (rutas, commits, citas textuales), no como razonamiento: el «en qué estamos / decisión abierta / siguiente paso» sigue siendo tuyo."
    anote="→ Al hacer tu próximo checkpoint, FUSIONA lo que aplique de este andamio al hilo y regenéralo (\`checkpoint-mecanico.js --self --ensure\`). Las citas del usuario que trae son textuales: úsalas para la PROCEDENCIA \`[user: \"…\"]\` en vez de reconstruirlas de memoria."
    if [ -n "$ctx" ]; then
      ctx=$(printf '%s\n\n---\n\n%s\n\n%s%s\n\n%s\n' "$ctx" "$ahdr" "$abody" "$corte" "$anote")
    else
      ctx=$(printf '%s\n\n%s%s\n\n%s\n' "$ahdr" "$abody" "$corte" "$anote")
    fi
  elif [ -n "$ctx" ]; then
    ctx=$(printf '%s\n\n(Hay un andamio mecánico en %s, MÁS VIEJO que este hilo ⇒ ya deberías haberlo fusionado al volcar; no lo re-inyecto para no gastar ventana. Si dudas, ábrelo.)\n' "$ctx" "$ANDAMIO")
  fi
fi

[ -n "${ctx//[[:space:]]/}" ] || exit 0

if command -v jq >/dev/null 2>&1; then
  jq -n --arg c "$ctx" '{hookSpecificOutput:{hookEventName:"SessionStart",additionalContext:$c}}'
else
  printf '%s\n' "$ctx"
fi
exit 0
