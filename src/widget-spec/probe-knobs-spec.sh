#!/usr/bin/env bash
# probe-knobs-spec.sh — el candado del spec de knobs (src/widget-spec/broker-knobs.tsv).
#
# La norma nace con su mecanismo: el spec solo sirve de fuente única si NO se puede agregar una
# variable de entorno al broker sin darle su entrada de GUI. Esto lo hace cumplir: barre las
# AXON_TERM_BROKER_* que el código REALMENTE lee y falla si alguna no está en el spec.
#
# El caso que lo motiva ya ocurrió: AXON_TERM_BROKER_WS_BACKPRESSURE_DEADLINE_MS entró con el
# endurecimiento del 2026-09-09 y ninguna GUI se enteró — porque no había nada que lo notara.
set -u
cd "$(dirname "$0")/../.." || exit 1

SPEC="src/widget-spec/broker-knobs.tsv"
fallos=0
ok()  { echo "  ✅ $1"; }
no()  { echo "  ❌ $1"; fallos=$((fallos+1)); }

echo "probe-knobs-spec (candado del spec de knobs del broker)"

[ -f "$SPEC" ] || { no "no existe $SPEC"; exit 1; }

# (1) Las que el CÓDIGO lee de verdad. Se excluyen las que NO son knobs de configuración del
#     servicio: TOKEN (secreto: jamás se edita por GUI) y URL (es del CLIENTE, no del broker).
leidas="$(grep -rhoE 'process\.env\.AXON_TERM_BROKER_[A-Z_]+' src/term-broker/*.ts 2>/dev/null \
          | sed 's/^process\.env\.//' | sort -u \
          | grep -vE '^AXON_TERM_BROKER_(TOKEN|URL)$')"

# (2) Las que declara el spec (primera columna, saltando comentarios y el encabezado).
declaradas="$(awk -F'\t' '!/^#/ && NF>1 && $1!="env" && $1!="@grupo" {print $1}' "$SPEC" | sort -u)"

faltan="$(comm -23 <(echo "$leidas") <(echo "$declaradas"))"
sobran="$(comm -13 <(echo "$leidas") <(echo "$declaradas"))"

if [ -z "$faltan" ]; then
  ok "toda variable que el código lee está en el spec ($(echo "$leidas" | grep -c .) knobs)"
else
  while read -r v; do [ -n "$v" ] && no "el código lee $v y el spec NO la declara — agrégala o la GUI no la verá nunca"; done <<< "$faltan"
fi

if [ -z "$sobran" ]; then
  ok "el spec no declara knobs fantasma"
else
  while read -r v; do [ -n "$v" ] && no "el spec declara $v y ningún .ts la lee — knob fantasma (¿se renombró o se borró?)"; done <<< "$sobran"
fi

# (3) El TOKEN no puede aparecer como knob: se muestra su presencia, nunca se edita por GUI.
if echo "$declaradas" | grep -q '^AXON_TERM_BROKER_TOKEN$'; then
  no "el spec declara el TOKEN como knob — el secreto NO se edita por GUI"
else
  ok "el TOKEN no es un knob de la GUI"
fi

# (4) Forma del spec: 12 columnas exactas en cada fila de datos, y nada de tabs faltantes por
#     haber usado espacios (el modo de falla clásico de un TSV editado a mano).
malas="$(awk -F'\t' '!/^#/ && NF>1 && NF!=12 && $1!="@grupo" {print NR": "NF" columnas"}' "$SPEC")"
if [ -z "$malas" ]; then ok "todas las filas tienen 12 columnas separadas por TAB"
else while read -r m; do no "fila con forma inválida — $m (¿usaste espacios en vez de TAB?)"; done <<< "$malas"; fi

# (5) Los defaults del spec tienen que ser los del CÓDIGO. Un spec que miente sobre el default es
#     peor que no tenerlo: la GUI mostraría "estás en el default" sobre un número inventado.
verificar_default() {
  local env_var="$1" esperado="$2" enc
  enc="$(awk -F'\t' -v v="$env_var" '!/^#/ && $1==v {print $5}' "$SPEC")"
  [ "$enc" = "$esperado" ] && ok "default de $env_var = $esperado (calza con el código)" \
                           || no "default de $env_var: el spec dice '$enc' y el código dice '$esperado'"
}
verificar_default AXON_TERM_BROKER_PORT 8799
verificar_default AXON_TERM_BROKER_MAX_SESSIONS 32
verificar_default AXON_TERM_BROKER_MAX_PTYS 32
verificar_default AXON_TERM_BROKER_WS_HIGH_WATER 1048576
verificar_default AXON_TERM_BROKER_WS_MAX_BUFFER 8388608
verificar_default AXON_TERM_BROKER_WS_KEEPALIVE_MS 30000
verificar_default AXON_TERM_BROKER_WS_BACKPRESSURE_DEADLINE_MS 60000
verificar_default AXON_TERM_BROKER_HEADERS_TIMEOUT_MS 15000
verificar_default AXON_TERM_BROKER_REQUEST_TIMEOUT_MS 30000

# (6) La válvula dura por debajo del umbral de contrapresión no tiene sentido (la advertencia del
#     spec lo dice); que los DEFAULTS al menos respeten esa relación.
hw="$(awk -F'\t' '$1=="AXON_TERM_BROKER_WS_HIGH_WATER" {print $5}' "$SPEC")"
mb="$(awk -F'\t' '$1=="AXON_TERM_BROKER_WS_MAX_BUFFER" {print $5}' "$SPEC")"
[ "$mb" -gt "$hw" ] && ok "la válvula dura ($mb) queda por encima del umbral ($hw)" \
                    || no "válvula dura ($mb) <= umbral ($hw): la pausa nunca alcanzaría a actuar"

# (7) La COPIA del spec dentro del paquete del plasmoid tiene que ser IDÉNTICA a la canónica.
#     El paquete se instala con `kpackagetool6 -u src/plasmoid`, que lleva ese directorio TAL CUAL:
#     el helper no puede alcanzar `src/widget-spec/` desde `~/.local/share/plasma/plasmoids/…`, así
#     que necesita su copia al lado. Mismo patrón —y mismo riesgo— que los módulos vendorizados del
#     term-broker: una copia deja de ser copia sin que nada se queje, salvo que algo lo compruebe.
COPIA="src/plasmoid/contents/broker-knobs.tsv"
if [ -f "$COPIA" ]; then
  if cmp -s "$SPEC" "$COPIA"; then ok "la copia del spec en el paquete es idéntica a la canónica"
  else no "$COPIA DIFIERE de $SPEC — cópiala de nuevo: cp -f $SPEC $COPIA"; fi
else
  no "falta $COPIA — el plasmoid instalado no encontraría el spec y la pestaña se quedaría sin knobs"
fi

# --- Candado de GRUPOS: cada grupo usado por un knob debe estar DECLARADO en una fila @grupo, y
#     cada @grupo debe usarlo al menos un knob (sin grupos fantasma). Los títulos y el orden viven
#     SOLO aquí desde #148; este candado evita que un knob caiga en un grupo sin título, o que sobre
#     una declaración que ninguna GUI mostrará. ---
grupos_usados="$(awk -F'\t' '$1 !~ /^(#|@grupo|env)/ && $1 != "" { print $2 }' "$SPEC" | sort -u)"
grupos_declarados="$(awk -F'\t' '$1 == "@grupo" { print $2 }' "$SPEC" | sort -u)"
for g in $grupos_usados; do
  printf '%s\n' "$grupos_declarados" | grep -qxF "$g" \
    && ok "el grupo «$g» que usan los knobs está declarado con su título" \
    || no "el grupo «$g» lo usan knobs pero NO tiene fila @grupo (quedaría sin título en la GUI)"
done
for g in $grupos_declarados; do
  printf '%s\n' "$grupos_usados" | grep -qxF "$g" \
    && : \
    || no "@grupo «$g» está declarado pero ningún knob lo usa (grupo fantasma)"
done

# Unicidad de las claves @grupo: dos filas con la misma clave harían que la GUI pinte ese grupo dos
# veces y que el mapa de títulos sobrescriba en silencio (hallazgo de la 7ª tupla auditora, 2026-09-09).
dups="$(awk -F'\t' '$1 == "@grupo" { print $2 }' "$SPEC" | sort | uniq -d)"
if [ -z "$dups" ]; then ok "las claves @grupo son únicas (ningún grupo declarado dos veces)"
else for d in $dups; do no "la clave @grupo «$d» está declarada MÁS de una vez (la GUI la pintaría duplicada)"; done; fi

echo ""
[ "$fallos" -eq 0 ] && { echo "✅ spec de knobs coherente con el código"; exit 0; } \
                    || { echo "❌ $fallos problema(s) en el spec de knobs"; exit 1; }
