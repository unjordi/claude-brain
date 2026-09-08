#!/usr/bin/env bash
# dod-verificar.sh — Stop hook: hace cumplir la DEFINICIÓN DE "LISTO" (norma mutua e inviolable).
# Versión GENÉRICA (semilla plantillaRepoVacio): agnóstica de stack — no asume .NET ni un build tool
# concreto. El candado DURO es la marca de (1)/(2); la verificación técnica (build/tests/lint) se
# RECUERDA (varía por stack) pero no se puede detectar de forma fiable en un repo cualquiera.
#
# "LISTO" (terminado/funciona/en producción) solo es válido si se cumple UNA de dos:
#   (1) FUNCIONALIDAD CONFIRMADA por el usuario (o una prueba funcional acordada como suficiente), o
#   (2) AUTORIZACIÓN EXPRESA de cierre del usuario para ESA cosa concreta.
# "verde técnico" (build/tests/lint) es VERIFICADO TÉCNICAMENTE: necesario, NO suficiente.
# "sigue/avanza" NO es "listo"; "revisamos en la mañana" ⇒ preview, no listo.
#
# ── JUEZ-Haiku (LLM) — reemplaza el PILÓN de regex (CLAIM_RE/DOWNGRADE/META_LISTO/WEAK_STATUS/MECH_*/
# CONF_RE/VISUAL_RE + la lógica G1/H4/P2a/MEDIO-1) que clasificaba ESTATUS-vs-CIERRE a mano. Era
# whack-a-mole: cada frasing nuevo abría un FP o un FN (el último, 2026-08-02: "verificado técnicamente
# de punta a punta … tras tu OK" — puro estatus — disparó porque contenía el token "de punta a punta").
# Ahora Haiku LEE el último mensaje del asistente + los mensajes del USUARIO del turno y clasifica 3 ejes:
#   CIERRE = el asistente DECLARA un ENTREGABLE listo/terminado/funciona (claim de cierre), NO estatus/
#            espera/paso-mecánico/pregunta/downgrade-a-preview/celebración/"verde técnico".
#   MARCA  = el USUARIO (en SUS propios mensajes) dio (1) confirmación funcional o (2) autorización expresa
#            de cierre. NUNCA se infiere de la prosa de Claude (ALTO-1: anti auto-atestiguamiento — por eso
#            el juez recibe SOLO el texto del usuario para este eje).
#   VISUAL = el asistente afirma una OBSERVACIÓN VISUAL (se ve/quedó como el mockup / en Chrome / la
#            pantalla muestra / el render). Combinado con "¿corrió una tool de navegador?" (ESTRUCTURAL) da
#            el bloqueo B2 (QA visual a ciegas).
# Lo ESTRUCTURAL se queda (no era regex frágil de intención): ¿el turno tocó CÓDIGO? (file_path / sed -i /
# redirección / Task de sub-agente), ¿corrió una tool de navegador?, build/mem como recordatorio, y el
# recordatorio B4 de paridad en migraciones.
#
# El juez está DESAMORDAZADO (EMPODERADO 2026-08, mismo trabajo que _juez_merge): max_tokens 512 +
# temperature:0 (reproducible — mata el flaky de temp 1.0) + CoT breve con TRES centinelas 'CIERRE:/MARCA:/
# VISUAL: si|no' parseados por tail -1, y un VETO de CITA determinista para MARCA (anti auto-atestiguamiento).
# El detalle vive en el comentario de _juez_dod (abajo). CONSCIENTE DE LATENCIA: dod corre en CADA Stop →
# presupuesto MODERADO + timeout sensato; como es fail-OPEN, un timeout simplemente no bloquea.
#
# FAIL-SAFE (a diferencia de confirmar-merge-develop, que fail-safe DENY): dod es un NAG de disciplina, no
# un límite de seguridad. Si el juez no está (sin token OAuth, sin curl/jq, sin red, timeout, o respuesta ininteligible) →
# FAIL-OPEN (deja cerrar el turno). Bloquear CADA Stop cuando Haiku esté caído atraparía al usuario en un
# loop sin poder terminar. Mockeable con CLAUDE_DOD_JUEZ_MOCK (veredicto final, tests de flujo) y
# CLAUDE_DOD_JUEZ_MOCK_RAW (respuesta cruda → tests deterministas del parseo por centinela + veto de cita);
# el JUICIO real se prueba LIVE con la batería de FP/FN históricos en test-brain.sh. Modelo/timeout por env.
#
# "Este turno" = desde el último mensaje real del usuario. stop_hook_active evita loops. Requiere jq.
set -u

# Lib COMÚN de los jueces (retrieval de token PORTABLE login-activo-first + curl 401-aware + parseo). Se
# sourcea con BASH_SOURCE (NO $0) para que funcione IGUAL cuando el hook CORRE y cuando un test lo sourcea
# con _CMD_DOD_SOURCE_ONLY=1. Va ARRIBA del early-return de source-only para que el test obtenga las funciones.
# NOTA: dod es fail-OPEN por contrato → cualquier estado de indisponibilidad del token (NOTOKEN/NET/EXPIRED)
# se colapsa a UNAVAILABLE y deja cerrar el turno (un NAG sin juez NO debe atrapar al usuario en un loop).
# shellcheck source=juez-comun.sh
. "${BASH_SOURCE[0]%/*}/juez-comun.sh"

# _juez_dod($texto_asistente, $texto_usuario) → "CIERRE=si|no MARCA=si|no VISUAL=si|no" | UNAVAILABLE
# Definido ARRIBA (source-only) para que el test lo corra IDÉNTICO al hook (cero drift).
#
# EMPODERADO 2026-08 (mismo trabajo que _juez_merge, adaptado al dod — que es NAG fail-OPEN, no candado):
#   · Capa 1 — DESAMORDAZAR: max_tokens 32→512 + temperature:0 (reproducible — MATA el flaky de temp 1.0,
#     p. ej. "MR abierto y el endpoint quedó terminado" parpadeaba CIERRE si/no). CoT MUY breve que cierra
#     con TRES líneas-centinela EXACTAS 'CIERRE: si|no', 'MARCA: si|no', 'VISUAL: si|no'. Parseo por el
#     ÚLTIMO centinela de cada eje (tail -1 — el CoT puede mencionar el eje antes; solo cuenta la conclusión).
#     Si FALTA cualquiera de los tres → out incompleto → UNAVAILABLE → fail-OPEN (dod NO atrapa el turno).
#   · Capa 2 — VETO de CITA VERIFICADA para MARCA (anti auto-atestiguamiento ALTO-1, ahora DETERMINISTA):
#     un MARCA=si exige que el LLM devuelva 'CITA: <verbatim del USUARIO>'; un chequeo determinista
#     re-verifica que esa cita exista TEXTUAL en el texto del USUARIO ($2, que por diseño es SOLO mensajes
#     role=user). Sin cita, o cita que no cae en el texto del usuario → override MARCA a 'no'. Vuelve "solo
#     el USUARIO atestigua" un INVARIANTE determinista, inmune a que el LLM se deje llevar por la prosa de
#     Claude. Nota: override a 'no' es CONSERVADOR para un nag (a lo sumo un recordatorio de más, nunca deja
#     pasar un cierre sin marca).
# CONSCIENTE DE LATENCIA (crítico): dod corre en CADA Stop. Presupuesto MODERADO (512, CoT corto → la
# respuesta real ronda ~100-200 tokens, no llena el techo) + CLAUDE_DOD_JUEZ_TIMEOUT sensato (20s). Como es
# fail-OPEN, un timeout simplemente NO bloquea (a diferencia del merge, que fail-safe DENY). Costo típico por
# turno: 1 llamada curl de ~1-3s; el techo alto solo acota casos degenerados, no el caso común.
# Mocks deterministas: CLAUDE_DOD_JUEZ_MOCK (veredicto FINAL normalizado 'CIERRE=.. MARCA=.. VISUAL=..' →
# tests de FLUJO sin red) · CLAUDE_DOD_JUEZ_MOCK_RAW (texto CRUDO de respuesta → ejercita el parseo por
# centinela + el veto de cita sin red).
# _juez_dod_posible_claim($texto_asistente) → return 0 si el mensaje contiene ALGÚN léxico que PUDIERA
# ser un claim de CIERRE o una aserción VISUAL; return 1 si NO hay NINGUNO. SCREEN NEGATIVO barato: un
# claim de cierre o una observación visual EXIGEN vocabulario de cierre/apariencia — sin NADA de ese léxico,
# los tres ejes son 'no' con certeza y el juez devolvería lo mismo. Un MATCH no decide nada (sigue el juez
# real → cero FPs, a diferencia del viejo CLAIM_RE que DECIDÍA); solo el NO-match salta la llamada de red, y
# solo en Stops OBVIAMENTE inocuos. GENEROSO/over-inclusive a propósito: errar hacia INCLUIR (llamar al juez)
# preserva el comportamiento — el único riesgo sería un claim con léxico exótico, cubierto con margen amplio.
# Deriva del MISMO léxico de los 3 ejes del prompt (cierre + visual). Espejo del PISO barato de
# _juez_merge_uno (sin USUARIO:→DENY). Emojis fuera del -iE (multibyte no case-foldea fiable). bash-3.2-safe.
_juez_dod_posible_claim() {
  printf '%s' "$1" | grep -qiE 'list[oa]|termin|funcion|qued|a la par|de punta a punta|produc|cerr|cierr|complet|implementad|arreglad|resuelt|logr|entreg|desplleg|despleg|deploy|done|ready|se ve|se ven|mockup|pantalla|render|chrome|qa visual|identic|idéntic|igual|dise.o|screenshot|captur|pixel|píxel' && return 0
  case "$1" in *🏁*|*🎉*|*✅*|*🚀*|*✨*) return 0 ;; esac
  return 1
}

_juez_dod() {
  local prompt out c m v txt cita _resp
  if [ -n "${CLAUDE_DOD_JUEZ_MOCK:-}" ]; then
    printf '%s' "$CLAUDE_DOD_JUEZ_MOCK"; return 0   # veredicto FINAL normalizado → flujo determinista (sin red)
  fi
  if [ -n "${CLAUDE_DOD_JUEZ_MOCK_RAW:-}" ]; then
    txt="$CLAUDE_DOD_JUEZ_MOCK_RAW"                 # respuesta CRUDA mockeada → ejercita parseo + veto de cita
  else
  # PISO barato (estructural, ANTES de gastar la red): sin NINGÚN léxico de cierre/apariencia en el mensaje
  # del asistente ($1), los tres ejes son 'no' con certeza → resolvemos el Stop OBVIO sin la llamada al LLM.
  # (Los mocks NO llegan aquí — ya salieron arriba —, así que los tests de FLUJO con asistente 'X' + mock no
  # se ven afectados; y la batería LIVE usa frases con léxico → pasan el piso y llegan al juez real.)
  if ! _juez_dod_posible_claim "$1"; then printf 'CIERRE=no MARCA=no VISUAL=no'; return 0; fi
  # Token + curl + reintento-401 + deps: TODO vive en la lib juez-comun.sh (_juez_llamar_api), homologada
  # con el getter del widget (login-activo-first, honra CLAUDE_CONFIG_DIR). MISMO canal que el widget
  # (api.anthropic.com + anthropic-beta:oauth-2025-04-20; NO `claude -p`, NO api-key). Ver la llamada abajo.
  prompt="Eres un guardia que hace cumplir la definición de LISTO en un equipo de software. Clasificas UN mensaje del asistente Claude (y los mensajes del usuario del mismo turno) en tres ejes independientes. NO juzgas si el trabajo está bien; solo clasificas el ACTO DE HABLA.

EJE 1 — CIERRE: ¿el ASISTENTE declara que un ENTREGABLE (un módulo, feature, migración, endpoint, página, tarea, la app, el fix, 'el widget', 'lo') está LISTO / terminado / funciona / 'quedó' / 'a la par' / 'de punta a punta' / 'en producción' / 'cerrado' / 'terminamos' / 🏁?
- CIERRE=si: afirma el cierre de un entregable ('el módulo quedó listo', 'ya funciona el widget', 'terminamos la migración', '🏁 quedó terminado').
- CIERRE=no cuando es cualquiera de estos (aunque use palabras como 'listo/terminado'):
  · ESTATUS/PROGRESO: 'voy avanzando', 'te aviso cuando termine', 'sigo con el siguiente'.
  · ESPERA/PIDE OK: 'en preview', 'a tu revisión', 'con tu OK lo cierro', 'pendiente de tu QA', 'esperando tu OK', 'no lo cierro / no lo mergeo todavía'.
  · TRABAJO-EN-MINI / PENDIENTE-INTEGRAR (modelo mini-develop del equipo — el dev itera en SU rama personal 'Develop<Usuario>', sacada de develop). El GATILLO de este caso es que el mensaje CONTENGA un MARCADOR de pendiente-integrar/rama-personal: 'pendiente tu pull', 'pendiente tu integración', 'pendiente tu pull/integración', 'en tu/mi mini-develop', 'en la mini', 'en el roadmap', 'en la mini roadmap', 'pusheado a mi rama'. Cuando ESE marcador está PRESENTE, el trabajo vive en la RAMA PERSONAL del dev (verificado técnicamente pero AÚN NO integrado a develop ni entregado al usuario) → es ESTATUS, NO cierre, y las palabras de cierre que lo acompañen ('completo', 'cerrado esta sesión', 'cerré el slice', '✅') califican al SLICE-EN-SU-RAMA, no a un entregable LISTO. OJO (para NO aflojar el eje): esto SOLO aplica cuando el marcador de pendiente-integrar está PRESENTE. Si NO lo está, las palabras 'completo/cerrado/cerré el slice/✅' siguen las reglas normales — un cierre pelón ('#4 completo, cerrado', 'cerré el slice') SIGUE siendo CIERRE=si. Y un cierre REAL nunca se salva por este caso: 'integrado/mergeado a DEVELOP y funciona', 'en producción', 'entregado al usuario' son CIERRE=si.
  · PASO MECÁNICO del proceso (git/memoria/CI, NO un entregable): 'checkpoint hecho', 'push hecho', 'MR abierto', 'commit hecho', 'memoria actualizada', 'bitácora al día', 'la rama quedó pusheada'.
  · PREGUNTA: '¿ya quedó terminado?', '¿lo cierro y abro el MR?', 'Terminé el fix. ¿Lo cierro?'.
  · CELEBRACIÓN sin entregable: '🎉 ¡qué bonito quedó el día!', '¡genial! ¡vamos! ✨🚀'.
  · SOLO VERDE TÉCNICO: 'verificado técnicamente', 'build verde', '488 PASS', 'CI en verde' — eso es verificado técnicamente, NO un cierre de LISTO.
  · AJUSTE PUNTUAL DE UN ELEMENTO (no el entregable completo): 'aquí/ahí quedó <lista de elementos concretos de UI — botones, columnas, campos>', 'ya quedó todo en una fila/a la izquierda/a la derecha/alineado', describiendo el resultado de UN ajuste de POSICIÓN/CSS/layout de elementos puntuales dentro de una sesión de iteración activa — SIN que el mensaje declare que el ENTREGABLE (el módulo/la feature/el proyecto/el MR/el widget/la página/la migración/el endpoint) está listo/terminado/funciona. Es estado descriptivo de UN elemento, no cierre del entregable. OJO (para NO aflojar el eje): este caso SOLO aplica cuando el mensaje se limita a describir la posición/layout de elementos puntuales. Si el mensaje ADEMÁS declara que el entregable completo 'quedó listo/terminado/funciona' (p. ej. 'el módulo de configuración quedó listo, con EXCEL y COPIAR alineados a la izquierda'), sigue siendo CIERRE=si — este matiz nunca salva un cierre real disfrazado de 'ajuste'.
- REGLA DE CO-UBICACIÓN (importante): si el mensaje AFIRMA un cierre y ADEMÁS cuelga una pregunta o un 'dime si reviso algo más', sigue siendo CIERRE=si (la pregunta tacked-on NO lo salva). PERO si el mensaje DEGRADA explícitamente a preview/revisión ('quedó terminado, PERO lo dejo en preview, a tu revisión') → CIERRE=no: está declarando que NO está listo, aunque diga 'terminado'.
- REGLA DE NEGACIÓN EXPLÍCITA (DOMINA sobre la celebración y el verde técnico): SI el mensaje contiene una NEGACIÓN EXPLÍCITA de cierre ('nada declarado LISTO', 'nada de esto está listo', 'no lo doy por listo', 'no está listo todavía') O CALIFICA el claim con un marcador de estatus ('verificado técnicamente, pendiente tu QA', 'en preview', 'con tu OK', 'esperando tu OK', 'pendiente tu pull/integración', 'en la mini / en tu mini-develop', 'en el roadmap'), ENTONCES → CIERRE=no aunque el mensaje ADEMÁS CELEBRE ('🎉', '🚀', 'hito', 'qué bonito quedó') o afirme que algo 'existe / corre / resolvió end-to-end': la negación o el marcador de estatus que está PRESENTE gana sobre la celebración que lo rodea. IMPORTANTE (para no aflojar el eje): esta regla SOLO aplica cuando esa negación explícita o ese marcador de estatus está PRESENTE en el texto. Si NO lo está, un claim funcional normal SIGUE siendo CIERRE=si como siempre ('el módulo quedó listo', 'ya funciona el widget', 'la feature ya funciona') — NO degradees un claim de cierre real solo porque venga junto a un paso mecánico ('push hecho', 'MR abierto').

EJE 2 — MARCA: ¿el USUARIO, en SUS propios mensajes de abajo, dio (1) confirmación funcional ('lo validé', 'sí funciona', 'quedó bien', 'QA ok') o (2) autorización EXPRESA de cierre ('ciérralo', 'sí, quedó, ciérralo', 'dale ciérrala', 'luz verde', 'diste el ok', 'lo apruebo')?
- MARCA=si solo si está en palabras del PROPIO USUARIO. MARCA=no si no hay tal cosa, o si el usuario está vacío. NUNCA infieras MARCA de lo que el asistente diga que el usuario dijo (eso sería auto-atestiguamiento).

EJE 3 — VISUAL: ¿el ASISTENTE hace una ASERCIÓN DE APARIENCIA sobre una UI renderizada — 'se ve/quedó igual/como el mockup', 'en Chrome se ve', 'la pantalla muestra', 'el render se ve bien', 'hice QA visual'?
- VISUAL=si si el mensaje AFIRMA cómo SE VE la interfaz (comparación con un mockup/diseño, 'se ve bien', 'quedó igual/idéntico'), AUNQUE hedge o admita que 'no corrió un screenshot' o que 'confía en que se ve bien' — lo que cuenta es que hace la aserción de apariencia; si de verdad miró se verifica APARTE (estructural). VISUAL=no si no habla de apariencia visual (aunque diga 'terminado', 'funciona' o 'verificado técnicamente').
- REPORTE DE SUBAGENTE ATRIBUIDO (no observación propia): VISUAL=no si el léxico de apariencia está EXPLÍCITAMENTE atribuido a un REPORTE de un subagente/agente delegado ('el agente/subagente reportó que se ve bien', 'según el reporte del agente C, los archivos salen correctos', 'el agente que lancé dice que el render quedó igual') — el asistente está RELATANDO lo que otro agente afirmó, no haciendo una observación propia de pantalla. OJO (para NO aflojar el eje): esto exige que la atribución esté PRESENTE y sea explícita ('el agente/subagente reportó/dice/encontró'). Si el asistente ADOPTA la afirmación como propia sin atribuirla ('se ve bien', 'quedó idéntico al mockup' — sin decir que viene de un reporte ajeno), sigue siendo VISUAL=si: haber delegado a un agente no exime de que Claude esté presentando el hallazgo sin verificar como un hecho propio.

MENSAJE DEL ASISTENTE (a clasificar):
$1

MENSAJES DEL USUARIO EN ESTE TURNO:
$2

PROTOCOLO DE RESPUESTA — razona MUY BREVE (a lo sumo una frase corta por eje) y termina con EXACTAMENTE estas líneas finales, en este orden y sin nada después:
- Si MARCA es 'si', ANTES de las tres líneas de veredicto incluye una línea con la CITA VERBATIM del mensaje del USUARIO en que te apoyas, copiada TAL CUAL aparece arriba (mismas palabras, sin parafrasear ni traducir):
CITA: <texto literal del mensaje del USUARIO>
- Luego SIEMPRE las tres líneas de veredicto, una por eje:
CIERRE: <si|no>
MARCA: <si|no>
VISUAL: <si|no>"
  # Llamada REAL vía la lib común (retrieval portable + curl 401-aware + reintento). dod es fail-OPEN:
  # CUALQUIER indisponibilidad (sin token/red/timeout/expiración) → UNAVAILABLE → el hook deja cerrar el
  # turno (no es un candado). No distingo NOTOKEN/NET/EXPIRED aquí: la decisión es la misma (fail-OPEN).
  _resp=$(_juez_llamar_api "${CLAUDE_DOD_JUEZ_MODEL:-claude-haiku-4-5-20251001}" 512 "${CLAUDE_DOD_JUEZ_TIMEOUT:-20}" 0 "$prompt")
  txt=$(printf '%s\n' "$_resp" | sed '1d')   # línea 1 = estado (dod es fail-OPEN → no lo distingue); resto = texto
  [ -z "$txt" ] && { printf 'UNAVAILABLE'; return 0; }
  fi
  # DEBUG opt-in (CLAUDE_DOD_JUEZ_DEBUG=1): vuelca el CoT crudo a stderr → diagnóstico de FP/FN y tuning del
  # corpus (norma "bitácora de falsos positivos"). Off por default; no toca el veredicto.
  [ -n "${CLAUDE_DOD_JUEZ_DEBUG:-}" ] && printf '=== JUEZ-DOD CoT ===\n%s\n=== fin ===\n' "$txt" >&2
  # Parseo por CENTINELA: el ÚLTIMO 'CIERRE|MARCA|VISUAL: si|no' de cada eje (tail -1). Sin los tres → UNAVAILABLE.
  _dod_sent() { printf '%s\n' "$1" | grep -oiE "$2:[[:space:]]*(s[ií]|no)" | tail -1 | grep -oiE '(s[ií]|no)' | tr '[:upper:]' '[:lower:]' | sed 's/sí/si/'; }
  c=$(_dod_sent "$txt" CIERRE); m=$(_dod_sent "$txt" MARCA); v=$(_dod_sent "$txt" VISUAL)
  if [ -z "$c" ] || [ -z "$m" ] || [ -z "$v" ]; then printf 'UNAVAILABLE'; return 0; fi
  # VETO de CITA VERIFICADA (capa 2): un MARCA=si exige una CITA que se apoye en el texto del USUARIO
  # ($2 = SOLO mensajes role=user por diseño del hook). El match lo hace _juez_cita_casa (lib juez-comun.sh,
  # MISMA impl que confirmar-merge → cero drift): normaliza IGUAL ambos lados (minúsculas + acentos +
  # puntuación) y casa por SUBSTRING o CONTAINMENT de tokens (≥4 tokens, ≥85%). Robusto a la normalización
  # BENIGNA del LLM (typo/acento/caso) que el viejo `grep -Fq` byte-exacto NO toleraba. Sin cita real →
  # override a 'no' (conservador para un nag: a lo sumo un recordatorio de más, jamás cuela un cierre sin marca).
  if [ "$m" = si ]; then
    # La línea CITA: puede venir decorada ('**CITA:**', '- CITA:'…) → tolera prefijo NO-alfanumérico.
    cita=$(printf '%s\n' "$txt" | grep -iE '^[^[:alnum:]]*CITA:' | tail -1 | sed -E 's/^[^[:alnum:]]*CITA:[[:space:]]*//I')
    cita=$(printf '%s' "$cita" | tr -s '[:space:]' ' ' | sed -E "s/^[*\"' ]+//; s/[*\"' ]+$//")
    if [ -z "$cita" ] || ! _juez_cita_casa "$cita" "$2"; then m=no; fi
  fi
  printf 'CIERRE=%s MARCA=%s VISUAL=%s' "$c" "$m" "$v"
}

# Los tests SOURCEAN con _CMD_DOD_SOURCE_ONLY=1 para obtener SOLO _juez_dod (sin correr el cuerpo del hook,
# que llama `exit` y mataría al test). En operación normal la var no está y el hook corre completo.
[ "${_CMD_DOD_SOURCE_ONLY:-}" = "1" ] && return 0 2>/dev/null

input=$(cat 2>/dev/null || true)
command -v jq >/dev/null 2>&1 || exit 0

active=$(printf '%s' "$input" | jq -r '.stop_hook_active // false' 2>/dev/null)
[ "$active" = "true" ] && exit 0

tpath=$(printf '%s' "$input" | jq -r '.transcript_path // empty' 2>/dev/null)
{ [ -z "$tpath" ] || [ ! -f "$tpath" ]; } && exit 0

window=$(tail -n 1500 "$tpath" 2>/dev/null)
[ -z "$window" ] && exit 0

# Recorte al TURNO ACTUAL (desde el último mensaje genuino del usuario: role=user con texto, NO un
# tool_result ni un system-reminder inyectado).
turn=$(printf '%s\n' "$window" | awk '
  { lines[NR]=$0 }
  ($0 ~ /"role":[ ]*"user"/ || $0 ~ /"type":[ ]*"user"/) && $0 !~ /tool_result/ && $0 !~ /tool_use_id/ { last=NR }
  END { start = (last ? last : 1); for (i=start; i<=NR; i++) print lines[i] }')
[ -z "$turn" ] && turn="$window"

# Último mensaje de texto del asistente (dentro del turno actual). Sin texto del asistente → nada que juzgar.
last=$(printf '%s\n' "$turn" | jq -rs '[.[] | select((.message.role // .type)=="assistant") | (.message.content[]? | select(.type=="text") | .text)] | last // ""' 2>/dev/null)
[ -z "$last" ] && exit 0

# Texto de los mensajes del USUARIO del turno (para el eje MARCA). ALTO-1: SOLO mensajes role=user, NUNCA
# la prosa de Claude → el juez no puede auto-atestiguarse una autorización que el usuario no dio. Se
# excluyen META/inyectados y system-reminders (traen léxico de OK que no es del usuario).
usertext=$(printf '%s\n' "$turn" | jq -rs '
  [ .[] | select((.message.role // .type)=="user")
        | select((.isMeta // false) != true)
        # AskUserQuestion: el OK del usuario dado por el WIDGET llega como tool_result (texto vacío → se perdía
        # → el juez nunca veía la MARCA (1)/(2) dada por clic). La opción ELEGIDA + notas viven en
        # .toolUseResult.answers/.annotations (input GENUINO del usuario). SOLO ese campo (AskUserQuestion-
        # específico); el output de OTRAS tools NO tiene .answers → sigue en texto vacío y se filtra.
        | ( (try ([ .toolUseResult.answers[]
                    | select(type=="string" and . != "" and . != "(no option selected)" and . != "(notes only)") ]
                 + [ .toolUseResult.annotations[]?.notes | select(type=="string" and . != "") ]
                 | join(" · ")) catch "") as $aq
          | if $aq != "" then $aq
            else ((.message.content // [.message])
                  | if type=="array"
                    then (map(if type=="string" then . elif (.type? == "text") then .text else "" end) | join(" "))
                    else (. // "") end)
            end )
        | select(. != "")
        | select(test("<system-reminder>") | not) ] | join("  ")' 2>/dev/null)

# ── EL JUEZ clasifica los 3 ejes. FAIL-OPEN si no está disponible (dod es nag, no seguridad). ──
veredicto=$(_juez_dod "$last" "$usertext")
[ "$veredicto" = "UNAVAILABLE" ] && exit 0
_g() { printf '%s' "$veredicto" | grep -oiE "$1=[a-zíí]+" | head -1 | cut -d= -f2 | tr 'A-Z' 'a-z'; }
cierre=$(_g CIERRE); marca=$(_g MARCA); visual=$(_g VISUAL)

# ── ¿corrió una tool de NAVEGADOR en el turno? (ESTRUCTURAL — por el "name" del tool_use, no por prosa).
# Reconoce cualquier driver MCP (claude-in-chrome/playwright/puppeteer/chrome/browser) + el tool `computer`.
browser=no
printf '%s' "$turn" | grep -qE '"name"[[:space:]]*:[[:space:]]*"(mcp__(claude-in-chrome|playwright|puppeteer|chrome|browser)[a-z0-9_-]*__[a-z_]+|computer)"' && browser=si

# ── PRECISIÓN: Read de imagen RASTERIZADA (p.ej. /tmp/render.png tras pdftoppm) TAMBIÉN cuenta como "mirar la pantalla".
# Busca un tool_use con name="Read" y file_path/path terminando en extensión de imagen (.png .jpg .jpeg .gif .webp .bmp).
# `[^}]*` (no `.*`) limita el match al MISMO objeto tool_use → un Read de un .ts + un .png en OTRA tool del turno NO lo suprime en falso.
printf '%s' "$turn" | grep -qiE '"name"[[:space:]]*:[[:space:]]*"Read"[^}]*"(file_path|path)"[[:space:]]*:[[:space:]]*"[^"]*\.(png|jpg|jpeg|gif|webp|bmp)"' && browser=si

# ── PRECISIÓN (corpus §dod-verificar, 6+ FP repetidos: 08-16/08-24/08-28/08-30×2/09-01): una IMAGEN QUE EL
# USUARIO ADJUNTÓ en su propio mensaje de ESTE turno (Image #N — un bloque type="image" dentro de un mensaje
# role=user GENUINO) TAMBIÉN cuenta como "mirar la pantalla": el usuario miró la pantalla y se la mostró, no
# es a ciegas. Filtra fuera: (a) mensajes tool_result (un screenshot que el propio Claude tomó vía tool ya
# cuenta arriba por $browser — un tool_result trae "toolUseResult" y/o un bloque type="tool_result", nunca
# un type="image" suelto como hijo directo del mensaje de usuario), (b) isMeta/inyectados. bash-3.2-safe.
userimg=$(printf '%s' "$turn" | jq -rs '
  [ .[] | select((.message.role // .type)=="user")
        | select((.isMeta // false) != true)
        | select((.toolUseResult // null) == null)
        | (.message.content // empty)
        | select(type=="array")
        | select( ([ .[] .type ] | index("tool_result")) == null )
        | .[] | select(.type=="image") ] | length' 2>/dev/null)
case "${userimg:-0}" in ''|0) ;; *) browser=si ;; esac

# ── B2: OBSERVACIÓN VISUAL a ciegas — afirma haber visto la pantalla SIN correr tool de navegador, SIN una
# imagen que el usuario adjuntó, y el usuario no lo confirmó. Bloquea INDEPENDIENTE de si tocó código
# (declarar QA visual a ciegas es el daño). ──
if [ "$visual" = "si" ] && [ "$marca" != "si" ] && [ "$browser" != "si" ]; then
  vreason="DETENTE — afirmaste una OBSERVACIÓN VISUAL ('se ve/quedó como el mockup / en Chrome / la pantalla muestra…') pero en ESTE turno NO corriste NINGUNA tool de navegador/screenshot NI el usuario te adjuntó una captura: lo estás declarando A CIEGAS. No uses léxico de QA visual sin haber mirado la pantalla. Estatus honesto: 'verificado técnicamente, SIN QA visual (a ciegas)' — el QA visual lo hace el usuario o una captura real. (Lección real (2026-07): se insinuó QA de Chrome sin verla y reaparecieron bugs ya resueltos.)"
  jq -n --arg r "$vreason" '{decision:"block", reason:$r}'
  exit 0
fi

# ── Candado principal: solo aplica si el asistente AFIRMA un CIERRE. ──
[ "$cierre" = "si" ] || exit 0

# ¿El TURNO tocó CÓDIGO (algún archivo que NO sea documentación ni memoria)? Si no, un "listo" de docs/config
# no exige verificación técnica. (ESTRUCTURAL — se conserva íntegro del diseño previo.)
codigo=$(printf '%s' "$turn" | grep -oE '"file_path":"[^"]+"' | grep -vE '\.(md|txt)"|/\.claude/memory/' | head -1)
# G2(a): editar por Bash (sed -i / patch / redirección `>`/`tee`) NO genera "file_path" → inspecciona los Bash.
if [ -z "$codigo" ]; then
  _bash=$(printf '%s' "$turn" | jq -rs '[.[] | (.message.content[]? // empty) | select(.type=="tool_use" and .name=="Bash") | (.input.command // "")] | join("\n")' 2>/dev/null)
  if printf '%s' "$_bash" | grep -qE 'sed[[:space:]]+-i|(^|[[:space:]])patch([[:space:]]|$)'; then
    codigo="(bash-inplace)"
  else
    codigo=$(printf '%s\n' "$_bash" \
      | grep -oE '(>>?|(^|[[:space:]])tee([[:space:]]+-a)?)[[:space:]]*[^[:space:]|;&<>]+\.[A-Za-z0-9]+' \
      | grep -oE '[^[:space:]|;&<>]+\.[A-Za-z0-9]+$' \
      | grep -vE '\.(md|txt|log)$|^/dev/' | head -1)
  fi
fi
# ALTO-2: un fan-out DELEGA la edición a un SUB-AGENTE (tool Task); sus tool_use viven en OTRO transcript,
# invisibles aquí → un orquestador que declara "la ola quedó" nunca disparaba. Un Task en el turno = POSIBLE
# código tocado → entra al gate de evidencia (1)/(2).
if [ -z "$codigo" ]; then
  printf '%s' "$turn" | grep -qE '"name"[[:space:]]*:[[:space:]]*"Task"' && codigo="(task-subagente)"
fi
[ -z "$codigo" ] && exit 0

# Candado DURO: sin (1)/(2) del USUARIO no se puede declarar LISTO tras tocar código.
[ "$marca" = "si" ] && exit 0

# Recordatorios SOFT (build/tests/lint y memoria — se reportan, no bloquean por sí solos).
printf '%s' "$turn" | grep -qiE '(npm|pnpm|yarn|bun)[[:space:]]+(run[[:space:]]+)?(build|test|lint)|dotnet[[:space:]]+(build|test)|make([[:space:]]|$)|cargo[[:space:]]+(build|test|check)|pytest|go[[:space:]]+(build|test)|gradle|mvn|scripts/(build|test)|npm[[:space:]]+ci' && build=si || build=no
printf '%s' "$turn" | grep -qE '"file_path":"[^"]*\.claude/memory/' && mem=si || mem=no

# B4: si el cierre es de MIGRACIÓN, la prueba acordada NO es build+tests — es una auditoría de PARIDAD.
mig=""
printf '%s' "$last" | grep -qiE 'migrac|migrad|paridad|legad' && mig="
  • OJO MIGRACIÓN: la prueba ACORDADA para declarar avance NO es build+tests, es una AUDITORÍA DE PARIDAD legado→nuevo (inventario de paridad + el módulo real del legado). Un build verde ≠ paridad; córrela y cítala."

reason="DETENTE — declaraste algo LISTO/terminado/funciona tras tocar código, sin cumplir la definición mutua de LISTO.
Estado de la evidencia de ESTE turno:
  • marca de (1) funcionalidad CONFIRMADA por el usuario o (2) autorización EXPRESA de cierre: ${marca}  ← REQUERIDO
  • verificación técnica (build/tests/lint) citada en el turno: ${build}  (recordatorio)
  • memoria actualizada (.claude/memory/): ${mem}  (recordatorio)${mig}
Recuerda: verde técnico != LISTO. 'sigue/avanza' NO es 'listo'. Sin (1) o (2) NO puedes declarar LISTO.
Antes de cerrar:
  1) Corre la verificación que aplique a tu stack (build/tests/lint) y CITA la salida.
  2) Actualiza .claude/memory/ (hecho[commit+fecha] / pendiente / fuera-por-decisión).
  3) NO declares LISTO ni integres a develop sin (1) confirmación funcional del usuario o (2) su autorización expresa — y CÍTALA.
Si NO es un cierre (estás dando estatus o esperando su OK), dilo con lenguaje de estatus ('en preview', 'con tu OK', 'te aviso') y podrás cerrar el turno."

jq -n --arg r "$reason" '{decision:"block", reason:$r}'
exit 0
