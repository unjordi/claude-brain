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
# El hook DISTINGUE el acto de habla:
#   - Lenguaje de ESTATUS/ESPERA (pido tu OK / te aviso / en preview / cuando reporte / ¿…?) → NO dispara.
#   - Lenguaje de CIERRE (quedó/está listo/terminado/cerrado/terminamos/de trancazo/🏁🎉/funciona/a la
#     par) tras tocar CÓDIGO en ESTE turno → exige una MARCA CITADA de (1) o (2); si falta, BLOQUEA.
#   - (B2) Afirmar una OBSERVACIÓN VISUAL (se ve/quedó como el mockup/en Chrome/la pantalla…) SIN haber
#     corrido una tool de navegador/screenshot en el turno → BLOQUEA (lo declara a ciegas).
#   - (B4) Si el cierre es de MIGRACIÓN, la prueba acordada es una AUDITORÍA DE PARIDAD, no build+tests.
#
# "Este turno" = desde el último mensaje real del usuario (no un turno viejo de la ventana) → así los
# mensajes de puro estatus/propuesta no heredan el "código tocado" de turnos anteriores (mata falsos
# positivos). stop_hook_active evita loops. Fail-open ante parseo. Requiere jq.
set -u
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

# Último mensaje de texto del asistente (dentro del turno actual).
last=$(printf '%s\n' "$turn" | jq -rs '[.[] | select((.message.role // .type)=="assistant") | (.message.content[]? | select(.type=="text") | .text)] | last // ""' 2>/dev/null)
[ -z "$last" ] && exit 0

# ── CLAIM de cierre (G1): se computa AQUÍ, antes de los escapes por PREGUNTA, porque una pregunta
# co-ubicada NO debe anular un cierre afirmado en el MISMO mensaje ("Listo, quedó terminado.
# ¿Reviso algo más?"). Con claim presente, la pregunta ya no salva el turno → se evalúa el claim. ──
CLAIM_RE='listo para (la )?(producci|desplegar|deploy|salir|mergear)|en producci[oó]n|(ya |todo |esto |lo |la )?(qued[oó]|est[aá]|dej[eé]) *(listo|lista|terminad|completad|funcionando)|(m[oó]dulo|migraci[oó]n|feature|slice|endpoint|p[aá]gina|tarea)[^.]{0,40}(complet|termin|listo|a la par|de punta a punta)|100% (listo|completo|a la par)|de punta a punta|ya (funciona|jala|sirve)|todo (listo|verde|jalando)|\bcerrad[oa]s?\b|\bcerramos\b|\bterminamos\b|de trancazo|🏁|🎉|✅ *(listo|hecho|terminad|cerrad|complet)'
# El claim se evalúa sobre el texto SIN los tramos de pregunta (¿…?): así "¿ya quedó terminado el
# módulo?" (léxico de cierre DENTRO de una pregunta) NO cuenta como claim, pero "Listo, quedó
# terminado. ¿Reviso algo más?" (claim AFIRMADO + pregunta aparte) SÍ. G1 = una pregunta co-ubicada
# no salva un cierre afirmado; una pregunta que SOLO consulta el estado, sí escapa.
_decl=$(printf '%s' "$last" | sed 's/¿[^?]*?//g')
printf '%s' "$_decl" | grep -qiE "$CLAIM_RE" && claim=si || claim=no

# ── ESCAPE por DOWNGRADE explícito (léxico PRESCRITO de preview/auto-degradación, o meta-discusión de
# la palabra "listo"): SIEMPRE escapa, incluso con un claim de cierre co-ubicado. Usar este léxico ES
# declarar NO-listo — "el módulo quedó terminado pero lo dejo EN PREVIEW, A TU REVISIÓN" es honesto,
# no un falso LISTO. (Por eso NO se subordina al claim: sería un falso positivo castigar justo la
# frase que la norma pide.) ──
DOWNGRADE_RE='en preview|a tu (revisi|qa)|para tu (revisi|qa|visto)|pendiente de tu|sin mergear|armado sin merge|no (lo |la )?mergeo|no cierro|no declaro|definici[oó]n de .?listo|qu[eé] entiendes por|palabra .?listo'
printf '%s' "$last" | grep -qiE "$DOWNGRADE_RE" && exit 0

# ── ESCAPE por ESTATUS DÉBIL (deferir/avisar/consultar) — SOLO si NO hay un CLAIM de cierre co-ubicado
# (H4), igual que la pregunta de abajo. Antes esto escapaba SIEMPRE, así "Listo, quedó terminado. Dime
# si reviso algo más." se salvaba con "dime si" pese al cierre AFIRMADO. Un deferral suave NO neutraliza
# un LISTO afirmado en el mismo mensaje (cierra H4); si NO hay claim, sí escapa (sigue siendo estatus). ──
WEAK_STATUS_RE='con tu (ok|visto|aprobaci)|dime si|dime c[oó]mo|dime qu[eé]|te aviso|te muestro|cuando .{0,40}(reporte|termine|cierre|entre|merge)|espero (tu|a que|el)|revisamos (en la ma|juntos|al rato|cuando)|si (ya |te )?(qued|late|parece)'
if [ "$claim" != si ]; then
  printf '%s' "$last" | grep -qiE "$WEAK_STATUS_RE" && exit 0
fi

# ── Escape por PREGUNTA — SOLO si NO hay un CLAIM de cierre co-ubicado (G1). El `¿…?` interno y la
# última línea que termina en `?` son señales de PREGUNTA (pedir input), no de cierre; pero un cierre
# afirmado en el mismo mensaje NO se salva colgándole una pregunta al final. (P1: mató un falso
# positivo real — preguntar por un UUID disparaba el guard sin declararse nada listo.) ──
if [ "$claim" != si ]; then
  printf '%s' "$last" | grep -qiE '¿[^?]{0,120}\?' && exit 0
  _lastline=$(printf '%s\n' "$last" | awk 'NF{l=$0} END{print l}')
  printf '%s' "$_lastline" | grep -qE '[?？][")»'"'"'”]*$' && exit 0
fi

# Marca de (1) confirmación de funcionalidad o (2) autorización expresa de cierre, CITADA en el mensaje.
# (Se computa AQUÍ ARRIBA porque B2 también la usa: si el usuario ya confirmó, citar SU QA visual es
# válido — no un claim a ciegas de Claude.)
CONF_RE='confirm[oó]|valid[oó]|validaste|luz verde (expresa|para cerrar)|autoriz[oó]|visto bueno|aprob[oó]|dio el ok|diste (el ok|luz)|me diste (luz|el ok|autoriz)|el (usuario|responsable) (confirm|valid|dio|acept|aprob)|QA (visual|funcional).{0,20}(ok|pas|verde|aprob)'
printf '%s' "$last" | grep -qiE "$CONF_RE" && conf=si || conf=no

# ── B2: ¿afirma una OBSERVACIÓN VISUAL sin haber mirado la pantalla en ESTE turno? (léxico ANCLADO a
# mockup/pantalla/chrome/render/QA-visual — no un "se ve bien" casual). Si además NO corrió ninguna
# tool de navegador/screenshot en el turno → lo declara A CIEGAS → BLOQUEA. (Lección real: se insinuó
# QA de Chrome sin ver la pantalla y reaparecieron bugs ya resueltos.) ──
VISUAL_RE='(qued[oó]|se ve[n]?) (igual|como|tal cual|clavad|idéntic)[^.]{0,25}(mockup|dise[nñ]|legado|pantalla)|lo verifiqu[eé] (en chrome|en el navegador|visualmente|en pantalla)|en chrome (se ve|qued[oó]|funciona|jala|lo prob[eé]|ya)|la pantalla (muestra|se ve|qued)|hice .{0,12}qa visual|qa visual.{0,15}(ok|pas|hecho|verde|aprob|correct)|screenshot (muestra|confirma)|el render (se ve|qued[oó]|correct)|se ve (id[eé]ntic|tal cual|como el (mockup|legado|dise))'
if [ "$conf" != si ] && printf '%s' "$last" | grep -qiE "$VISUAL_RE"; then
  # G2(b): detecta la tool de navegador por ESTRUCTURA del transcript (un tool_use cuyo "name" es una
  # tool de navegador), NO por la palabra "screenshot" suelta en prosa — si no, decir "no tomé
  # screenshot" suprimía el bloqueo. Solo un tool_use REAL (chrome MCP o el tool `computer`) cuenta.
  if ! printf '%s' "$turn" | grep -qE '"name"[[:space:]]*:[[:space:]]*"(mcp__claude-in-chrome__[a-z_]+|computer)"'; then
    vreason="DETENTE — afirmaste una OBSERVACIÓN VISUAL ('se ve/quedó como el mockup / en Chrome / la pantalla muestra…') pero en ESTE turno NO corriste NINGUNA tool de navegador/screenshot: lo estás declarando A CIEGAS. No uses léxico de QA visual sin haber mirado la pantalla. Estatus honesto: 'verificado técnicamente, SIN QA visual (a ciegas)' — el QA visual lo hace el usuario o una captura real. (Lección real (2026-07): se insinuó QA de Chrome sin verla y reaparecieron bugs ya resueltos.)"
    jq -n --arg r "$vreason" '{decision:"block", reason:$r}'
    exit 0
  fi
fi

# ── ¿Afirma CIERRE real? (ya computado arriba como $claim para G1). ──
[ "$claim" = si ] || exit 0

# ¿El TURNO tocó CÓDIGO (algún archivo que NO sea documentación ni memoria)? Si no, un "listo" no exige
# verificación técnica (turno de docs/config puro).
codigo=$(printf '%s' "$turn" | grep -oE '"file_path":"[^"]+"' | grep -vE '\.(md|txt)"|/\.claude/memory/' | head -1)
# G2(a): editar por Bash (sed -i / patch / redirección `>`/`tee` a un archivo) NO genera "file_path" →
# antes parecía que el turno no tocó código (evasión). Inspecciona los comandos Bash del turno.
if [ -z "$codigo" ]; then
  _bash=$(printf '%s' "$turn" | jq -rs '[.[] | (.message.content[]? // empty) | select(.type=="tool_use" and .name=="Bash") | (.input.command // "")] | join("\n")' 2>/dev/null)
  if printf '%s' "$_bash" | grep -qE 'sed[[:space:]]+-i|(^|[[:space:]])patch([[:space:]]|$)'; then
    codigo="(bash-inplace)"   # edición in-place / parche → mutación fuerte (rara vez solo-doc)
  else
    # Redirección o tee hacia un archivo con extensión NO-doc (excluye docs, logs y /dev/*).
    codigo=$(printf '%s\n' "$_bash" \
      | grep -oE '(>>?|(^|[[:space:]])tee([[:space:]]+-a)?)[[:space:]]*[^[:space:]|;&<>]+\.[A-Za-z0-9]+' \
      | grep -oE '[^[:space:]|;&<>]+\.[A-Za-z0-9]+$' \
      | grep -vE '\.(md|txt|log)$|^/dev/' | head -1)
  fi
fi
[ -z "$codigo" ] && exit 0

# Evidencia en el turno (build/tests/lint es SOFT — se reporta; el candado duro es conf).
printf '%s' "$turn" | grep -qiE '(npm|pnpm|yarn|bun)[[:space:]]+(run[[:space:]]+)?(build|test|lint)|dotnet[[:space:]]+(build|test)|make([[:space:]]|$)|cargo[[:space:]]+(build|test|check)|pytest|go[[:space:]]+(build|test)|gradle|mvn|scripts/(build|test)|npm[[:space:]]+ci' && build=si || build=no
printf '%s' "$turn" | grep -qE '"file_path":"[^"]*\.claude/memory/' && mem=si || mem=no

# Candado DURO: sin (1)/(2) CITADO no se puede declarar LISTO. (build/mem se reportan como recordatorio.)
[ "$conf" = si ] && exit 0

# B4: si el cierre es de MIGRACIÓN, la prueba acordada NO es build+tests — es una auditoría de PARIDAD.
mig=""
printf '%s' "$last" | grep -qiE 'migrac|migrad|paridad|legad' && mig="
  • OJO MIGRACIÓN: la prueba ACORDADA para declarar avance NO es build+tests, es una AUDITORÍA DE PARIDAD legado→nuevo (inventario de paridad + el módulo real del legado). Un build verde ≠ paridad; córrela y cítala."

reason="DETENTE — declaraste algo LISTO/terminado/funciona tras tocar código, sin cumplir la definición mutua de LISTO.
Estado de la evidencia de ESTE turno:
  • marca de (1) funcionalidad CONFIRMADA por el usuario o (2) autorización EXPRESA de cierre: ${conf}  ← REQUERIDO
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
