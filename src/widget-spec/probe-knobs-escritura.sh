#!/usr/bin/env bash
# probe-knobs-escritura.sh — el escritor de knobs (broker-knobs.sh) contra entradas FEAS.
#
# Lo que hay que poder afirmar aquí, porque el archivo que este escritor muta CONTIENE EL TOKEN del
# broker: que el token sobrevive byte a byte a cada escritura, que los comentarios que documentan
# cada knob no se pierden, que los permisos siguen en 0600, y que un knob solo-lectura o un valor
# fuera de rango se RECHAZAN antes de tocar el disco.
set -u
cd "$(dirname "$0")/../.." || exit 1
KNOBS="src/plasmoid/contents/broker-knobs.sh"
export BROKER_KNOBS_SPEC="$PWD/src/widget-spec/broker-knobs.tsv"

fallos=0; casos=0
ok() { casos=$((casos+1)); [ "$1" = "0" ] || { fallos=$((fallos+1)); echo "  ❌ $2"; }; }

TOKEN='a1b2c3d4e5f60718293a4b5c6d7e8f90a1b2c3d4e5f60718293a4b5c6d7e8f90'
sembrar() {
    D="$(mktemp -d)"; export BROKER_KNOBS_ENV="$D/term-broker.env"
    cat > "$BROKER_KNOBS_ENV" <<EOF
# cortex — broker de terminal. Generado por ./install.sh
# ⚠️ SECRETO: quien tenga este token puede ejecutar CUALQUIER comando como tu usuario.
AXON_TERM_BROKER_TOKEN=$TOKEN
# AXON_TERM_BROKER_SOCKET=/run/user/1000/axon/term-broker.sock
#   Transporte del cliente CONTENERIZADO.
# AXON_TERM_BROKER_PORT=8799   # listener TCP
# AXON_TERM_BROKER_MAX_PTYS=32              # PTYs concurrentes
EOF
    chmod 600 "$BROKER_KNOBS_ENV"
}
limpiar() { rm -rf "$D"; }

echo "probe-knobs-escritura"

# (1) list devuelve JSON válido con los 12 knobs, y el TOKEN NO aparece.
sembrar
out="$(bash "$KNOBS" list 2>&1)"; rc=$?
ok "$rc" "list sale 0 (fue $rc)"
python3 -c "import json,sys; d=json.load(sys.stdin); assert len(d['knobs'])==12, len(d['knobs'])" <<< "$out" 2>/dev/null
ok $? "list es JSON válido con 12 knobs"
case "$out" in *"$TOKEN"*) ok 1 "el TOKEN NO aparece en la salida de list" ;; *) ok 0 "" ;; esac
# El valor de un knob que nadie configuró viene NULL, no su default: "está en 32 porque lo pusiste"
# no es lo mismo que "está en 32 porque es el default".
python3 -c "
import json,sys
d=json.load(sys.stdin)
k={x['env']:x for x in d['knobs']}
assert k['AXON_TERM_BROKER_MAX_PTYS']['actual'] is None, k['AXON_TERM_BROKER_MAX_PTYS']['actual']
assert k['AXON_TERM_BROKER_MAX_PTYS']['default']=='32'
assert k['AXON_TERM_BROKER_BIND']['gui']=='lee'
assert k['AXON_TERM_BROKER_WS_KEEPALIVE_MS']['cero_apaga'] is True
assert k['AXON_TERM_BROKER_BIND']['advertencia'] is not None
" <<< "$out" 2>/dev/null
ok $? "un knob comentado sale actual=null (no su default), y el spec viaja íntegro"
limpiar

# (2) set escribe, y EL TOKEN SOBREVIVE BYTE A BYTE. Es la razón de ser de este probe.
sembrar
antes="$(grep '^AXON_TERM_BROKER_TOKEN=' "$BROKER_KNOBS_ENV")"
bash "$KNOBS" set AXON_TERM_BROKER_MAX_PTYS 64 >/dev/null 2>&1; ok $? "set de un knob editable sale 0"
despues="$(grep '^AXON_TERM_BROKER_TOKEN=' "$BROKER_KNOBS_ENV")"
[ "$antes" = "$despues" ]; ok $? "el TOKEN sobrevive IDÉNTICO a la escritura"
grep -q '^AXON_TERM_BROKER_MAX_PTYS=64$' "$BROKER_KNOBS_ENV"; ok $? "el knob quedó escrito y descomentado"
[ "$(stat -c '%a' "$BROKER_KNOBS_ENV")" = "600" ]; ok $? "el archivo sigue en 0600 tras la escritura"
grep -q 'Transporte del cliente CONTENERIZADO' "$BROKER_KNOBS_ENV"; ok $? "los comentarios que documentan los knobs se conservan"
# Solo UNA línea de esa clave: reescribir dos veces no debe duplicarla.
bash "$KNOBS" set AXON_TERM_BROKER_MAX_PTYS 48 >/dev/null 2>&1
[ "$(grep -cE '^[[:space:]]*#?[[:space:]]*AXON_TERM_BROKER_MAX_PTYS=' "$BROKER_KNOBS_ENV")" = "1" ]
ok $? "dos escrituras seguidas NO duplican la línea"
limpiar

# (3) unset la devuelve a default (comentada) sin perder el token.
sembrar
bash "$KNOBS" set AXON_TERM_BROKER_MAX_PTYS 64 >/dev/null 2>&1
bash "$KNOBS" unset AXON_TERM_BROKER_MAX_PTYS >/dev/null 2>&1; ok $? "unset sale 0"
grep -qE '^#[[:space:]]*AXON_TERM_BROKER_MAX_PTYS=' "$BROKER_KNOBS_ENV"; ok $? "unset deja la línea COMENTADA (vuelve al default del código)"
grep -q "^AXON_TERM_BROKER_TOKEN=$TOKEN$" "$BROKER_KNOBS_ENV"; ok $? "el TOKEN sigue intacto tras el unset"
limpiar

# (4) Lo que se RECHAZA antes de tocar disco.
sembrar
sha_antes="$(sha256sum "$BROKER_KNOBS_ENV" | cut -d' ' -f1)"
bash "$KNOBS" set AXON_TERM_BROKER_TOKEN loquesea >/dev/null 2>&1; [ $? -ne 0 ]; ok $? "RECHAZA escribir el TOKEN"
bash "$KNOBS" set AXON_TERM_BROKER_BIND 0.0.0.0 >/dev/null 2>&1; [ $? -ne 0 ]; ok $? "RECHAZA BIND (solo-lectura: expondría RCE a la red)"
bash "$KNOBS" set AXON_TERM_BROKER_PORT 9999 >/dev/null 2>&1; [ $? -ne 0 ]; ok $? "RECHAZA PORT (solo-lectura: es el contrato con el cliente)"
bash "$KNOBS" set AXON_TERM_BROKER_INVENTADA 1 >/dev/null 2>&1; [ $? -ne 0 ]; ok $? "RECHAZA una variable que el spec no declara"
bash "$KNOBS" set AXON_TERM_BROKER_MAX_PTYS 0 >/dev/null 2>&1; [ $? -ne 0 ]; ok $? "RECHAZA 0 donde NO apaga nada (sería un tope de cero)"
bash "$KNOBS" set AXON_TERM_BROKER_MAX_PTYS 99999 >/dev/null 2>&1; [ $? -ne 0 ]; ok $? "RECHAZA un valor por encima del máximo del spec"
bash "$KNOBS" set AXON_TERM_BROKER_MAX_PTYS abc >/dev/null 2>&1; [ $? -ne 0 ]; ok $? "RECHAZA un valor no numérico en un knob entero"
bash "$KNOBS" set AXON_TERM_BROKER_WS_HIGH_WATER 100 >/dev/null 2>&1; [ $? -ne 0 ]; ok $? "RECHAZA un valor por debajo del mínimo"
[ "$(sha256sum "$BROKER_KNOBS_ENV" | cut -d' ' -f1)" = "$sha_antes" ]
ok $? "tras OCHO rechazos el archivo está BYTE A BYTE como antes (nada se escribió a medias)"
limpiar

# (5) El 0 SÍ vale donde APAGA el mecanismo — y ahí significa apagar, no "cero".
sembrar
bash "$KNOBS" set AXON_TERM_BROKER_WS_KEEPALIVE_MS 0 >/dev/null 2>&1; ok $? "ACEPTA 0 en el keepalive (ahí 0 = APAGADO)"
grep -q '^AXON_TERM_BROKER_WS_KEEPALIVE_MS=0$' "$BROKER_KNOBS_ENV"; ok $? "…y lo escribe como 0"
limpiar

# (6) Un .env con CRLF (editado en Windows): el valor se lee sin el \r.
sembrar
printf 'AXON_TERM_BROKER_MAX_SESSIONS=48\r\n' >> "$BROKER_KNOBS_ENV"
python3 -c "
import json,sys
d=json.load(sys.stdin); k={x['env']:x for x in d['knobs']}
assert k['AXON_TERM_BROKER_MAX_SESSIONS']['actual']=='48', repr(k['AXON_TERM_BROKER_MAX_SESSIONS']['actual'])
" <<< "$(bash "$KNOBS" list 2>/dev/null)" 2>/dev/null
ok $? "un .env con CRLF da el valor sin el \\r"
limpiar

# (7) Sin archivo de env: se dice, no se inventa uno con el token perdido.
export BROKER_KNOBS_ENV="/tmp/no-existe-$$/term-broker.env"
bash "$KNOBS" set AXON_TERM_BROKER_MAX_PTYS 64 >/dev/null 2>&1; [ $? -ne 0 ]; ok $? "sin .env, set FALLA en vez de crear uno sin token"

echo ""
[ "$fallos" -eq 0 ] && { echo "✅ $casos casos verdes"; exit 0; } || { echo "❌ $fallos de $casos casos ROJOS"; exit 1; }
