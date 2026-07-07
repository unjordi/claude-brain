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
#   - Lenguaje de CIERRE (quedó/está listo/terminado/mergeo/funciona/a la par) tras tocar CÓDIGO en
#     ESTE turno → exige una MARCA CITADA de (1) o (2); si falta, BLOQUEA.
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

# ── ESCAPE: ¿el mensaje es ESTATUS/ESPERA/PROPUESTA (no un cierre)? → no dispares. ──
STATUS_RE='con tu (ok|visto|aprobaci)|dime si|dime c[oó]mo|dime qu[eé]|te aviso|te muestro|cuando .{0,40}(reporte|termine|cierre|entre|merge)|en preview|a tu (revisi|qa)|para tu (revisi|qa|visto)|pendiente de tu|sin mergear|armado sin merge|no (lo |la )?mergeo|no cierro|no declaro|espero (tu|a que|el)|revisamos (en la ma|juntos|al rato|cuando)|si (ya |te )?(qued|late|parece)|¿[^?]{0,120}\?|definici[oó]n de .?listo|qu[eé] entiendes por|palabra .?listo'
printf '%s' "$last" | grep -qiE "$STATUS_RE" && exit 0

# ── ¿Afirma CIERRE real (algo quedó terminado/funciona/en producción)? ──
CLAIM_RE='listo para (la )?(producci|desplegar|deploy|salir|mergear)|en producci[oó]n|(ya |todo |esto |lo |la )?(qued[oó]|est[aá]|dej[eé]) *(listo|lista|terminad|completad|funcionando)|(m[oó]dulo|migraci[oó]n|feature|slice|endpoint|p[aá]gina|tarea)[^.]{0,40}(complet|termin|listo|a la par|de punta a punta)|100% (listo|completo|a la par)|de punta a punta|ya (funciona|jala|sirve)|todo (listo|verde|jalando)'
printf '%s' "$last" | grep -qiE "$CLAIM_RE" || exit 0

# ¿El TURNO tocó CÓDIGO (algún archivo que NO sea documentación ni memoria)? Si no, un "listo" no exige
# verificación técnica (turno de docs/config puro).
codigo=$(printf '%s' "$turn" | grep -oE '"file_path":"[^"]+"' | grep -vE '\.(md|txt)"|/\.claude/memory/' | head -1)
[ -z "$codigo" ] && exit 0

# Evidencia en el turno (build/tests/lint es SOFT — se reporta; el candado duro es conf).
printf '%s' "$turn" | grep -qiE '(npm|pnpm|yarn|bun)[[:space:]]+(run[[:space:]]+)?(build|test|lint)|dotnet[[:space:]]+(build|test)|make([[:space:]]|$)|cargo[[:space:]]+(build|test|check)|pytest|go[[:space:]]+(build|test)|gradle|mvn|scripts/(build|test)|npm[[:space:]]+ci' && build=si || build=no
printf '%s' "$turn" | grep -qE '"file_path":"[^"]*\.claude/memory/' && mem=si || mem=no
# Marca de (1) confirmación de funcionalidad o (2) autorización expresa de cierre, CITADA en el mensaje.
CONF_RE='confirm[oó]|valid[oó]|luz verde (expresa|para cerrar)|autoriz[oó]|visto bueno|aprob[oó]|dio el ok|me diste (luz|el ok|autoriz)|el (usuario|responsable) (confirm|valid|dio|acept|aprob)|QA (visual|funcional).{0,20}(ok|pas|verde|aprob)'
printf '%s' "$last" | grep -qiE "$CONF_RE" && conf=si || conf=no

# Candado DURO: sin (1)/(2) CITADO no se puede declarar LISTO. (build/mem se reportan como recordatorio.)
[ "$conf" = si ] && exit 0

reason="DETENTE — declaraste algo LISTO/terminado/funciona tras tocar código, sin cumplir la definición mutua de LISTO.
Estado de la evidencia de ESTE turno:
  • marca de (1) funcionalidad CONFIRMADA por el usuario o (2) autorización EXPRESA de cierre: ${conf}  ← REQUERIDO
  • verificación técnica (build/tests/lint) citada en el turno: ${build}  (recordatorio)
  • memoria actualizada (.claude/memory/): ${mem}  (recordatorio)
Recuerda: verde técnico != LISTO. 'sigue/avanza' NO es 'listo'. Sin (1) o (2) NO puedes declarar LISTO.
Antes de cerrar:
  1) Corre la verificación que aplique a tu stack (build/tests/lint) y CITA la salida.
  2) Actualiza .claude/memory/ (hecho[commit+fecha] / pendiente / fuera-por-decisión).
  3) NO declares LISTO ni integres a develop sin (1) confirmación funcional del usuario o (2) su autorización expresa — y CÍTALA.
Si NO es un cierre (estás dando estatus o esperando su OK), dilo con lenguaje de estatus ('en preview', 'con tu OK', 'te aviso') y podrás cerrar el turno."

jq -n --arg r "$reason" '{decision:"block", reason:$r}'
exit 0
