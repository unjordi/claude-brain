#!/usr/bin/env bash
# broker-knobs.sh — el brazo de ESCRITURA de la pestaña Broker del widget.
#
# Vive aparte de `broker-scan.sh` a propósito: ese módulo garantiza por contrato que NUNCA muta nada
# (es su regla 2), y mezclarle escrituras convertiría esa garantía en una nota al pie. Aquí está todo
# lo que toca disco, y nada más.
#
# El archivo que edita —`~/.config/cortex/term-broker.env`— CONTIENE EL TOKEN del broker: quien lo
# tenga puede ejecutar cualquier comando como este usuario. De ahí las reglas duras de abajo.
#
#   broker-knobs.sh list                 -> JSON: el spec de knobs + el valor actual de cada uno
#   broker-knobs.sh set <ENV_VAR> <val>  -> escribe ese knob (validado contra el spec)
#   broker-knobs.sh unset <ENV_VAR>      -> lo devuelve a su default (comenta la línea)
#
# REGLAS DURAS:
#   1. Solo se escriben variables DECLARADAS en el spec (`src/widget-spec/broker-knobs.tsv`) y con
#      `gui=edita`. Cualquier otro nombre se RECHAZA — incluido el TOKEN, que no es un knob, y
#      BIND/PORT/SOCKET/HOME, que son solo-lectura en toda GUI (ver el spec para el porqué).
#   2. El TOKEN nunca se lee, ni se imprime, ni se pasa por argv. La reescritura del archivo
#      CONSERVA su línea intacta, byte a byte.
#   3. El archivo se reescribe de forma ATÓMICA (tmp + mv) con umask 077, para que no exista ni un
#      instante con el token adentro y permisos laxos.
#   4. El valor se valida contra el TIPO y el RANGO del spec ANTES de escribir. Un `0` en un knob
#      con `cero_apaga=1` es válido y significa APAGAR; en cualquier otro, no lo es.
#   5. Ningún cambio aplica hasta reiniciar el servicio. Se DICE en la salida; no se reinicia solo
#      (reiniciar mata las terminales abiertas del usuario y eso lo decide él, no este script).
set -u
# El PATH se APENDA (no se prepone): el entorno del plasmoid llega mínimo, pero preponer haría que
# ningún doble se pueda interponer y volvería este módulo imposible de verificar.
export PATH="${PATH:-}:/usr/bin:/bin:/usr/sbin:/sbin"

ENV_FILE="${BROKER_KNOBS_ENV:-$HOME/.config/cortex/term-broker.env}"

# El spec: al lado de este script en el paquete instalado, o en el repo si corremos del clon.
buscar_spec() {
    local aqui; aqui="$(cd "$(dirname "$0")" && pwd)"
    local c
    for c in "$aqui/broker-knobs.tsv" \
             "$aqui/../../widget-spec/broker-knobs.tsv" \
             "$HOME/.cortex/src/widget-spec/broker-knobs.tsv" \
             "$HOME/code/cortex/src/widget-spec/broker-knobs.tsv"; do
        [ -f "$c" ] && { printf '%s' "$c"; return 0; }
    done
    return 1
}
SPEC="${BROKER_KNOBS_SPEC:-$(buscar_spec || true)}"

morir() { printf '%s\n' "$1" >&2; exit "${2:-1}"; }

# --- JSON: se construye con printf, no con jq (el PATH del plasmoid no lo garantiza) ---
json_str() {
    local s="${1-}"
    if [ -z "$s" ]; then printf 'null'; return; fi
    s="${s//\\/\\\\}"; s="${s//\"/\\\"}"
    s="${s//$'\t'/\\t}"; s="${s//$'\n'/\\n}"; s="${s//$'\r'/}"
    printf '"%s"' "$s"
}
json_num_o_null() { case "${1-}" in ''|-) printf 'null' ;; *[!0-9]*) printf 'null' ;; *) printf '%s' "$1" ;; esac; }
json_bool() { [ "${1:-0}" = "1" ] && printf 'true' || printf 'false'; }

# Lee el valor CRUDO de una clave del .env: solo líneas NO comentadas. Nunca con `source` (ejecutaría
# lo que el archivo contenga). Quita comillas envolventes y el CR de un archivo con finales de
# línea de Windows (sin eso, un "8799\r" no pasa la validación numérica y el knob se ve inválido).
leer_valor() {
    local clave="$1" linea
    [ -f "$ENV_FILE" ] || return 1
    linea="$(grep -E "^[[:space:]]*${clave}=" "$ENV_FILE" 2>/dev/null | head -n1)"
    [ -n "$linea" ] || return 1
    linea="${linea#*=}"
    linea="${linea%$'\r'}"
    # Se corta un comentario al final SOLO si va precedido de espacio: una ruta puede llevar '#'.
    linea="${linea%%[[:space:]]#*}"
    linea="${linea#"${linea%%[![:space:]]*}"}"; linea="${linea%"${linea##*[![:space:]]}"}"
    if   [ "${linea:0:1}" = '"' ] && [ "${linea: -1}" = '"' ]; then linea="${linea:1:${#linea}-2}"
    elif [ "${linea:0:1}" = "'" ] && [ "${linea: -1}" = "'" ]; then linea="${linea:1:${#linea}-2}"; fi
    printf '%s' "$linea"
}

# Campo N del spec para una variable dada.
campo() { awk -F'\t' -v v="$1" -v n="$2" '!/^#/ && NF>1 && $1==v {print $n; exit}' "$SPEC"; }

declarado() { [ -n "$(campo "$1" 1)" ]; }

# --- list: el spec + el valor actual de cada knob ---
listar() {
    [ -n "$SPEC" ] && [ -f "$SPEC" ] || morir 'no encuentro broker-knobs.tsv (el spec de knobs)' 3
    printf '{"archivo":%s,"knobs":[' "$(json_str "$ENV_FILE")"
    local primero=1 env_var grupo etiqueta tipo def mn mx cero rein gui ayuda adv actual
    while IFS=$'\t' read -r env_var grupo etiqueta tipo def mn mx cero rein gui ayuda adv; do
        case "$env_var" in ''|'#'*|env|@grupo) continue ;; esac
        [ "$primero" -eq 1 ] && primero=0 || printf ','
        # `actual` es null cuando NADIE lo configuró: el widget pinta entonces el default, y la
        # diferencia importa — "está en 32 porque lo pusiste" no es "está en 32 porque es el default".
        if actual="$(leer_valor "$env_var")" && [ -n "$actual" ]; then :; else actual=""; fi
        printf '{"env":%s,"grupo":%s,"etiqueta":%s,"tipo":%s,"default":%s,"min":%s,"max":%s,"cero_apaga":%s,"reinicio":%s,"gui":%s,"ayuda":%s,"advertencia":%s,"actual":%s}' \
            "$(json_str "$env_var")" "$(json_str "$grupo")" "$(json_str "$etiqueta")" "$(json_str "$tipo")" \
            "$(json_str "$def")" "$(json_num_o_null "$mn")" "$(json_num_o_null "$mx")" \
            "$(json_bool "$cero")" "$(json_bool "$rein")" "$(json_str "$gui")" \
            "$(json_str "$ayuda")" "$([ "$adv" = "-" ] && printf 'null' || json_str "$adv")" \
            "$(json_str "$actual")"
    done < "$SPEC"
    # `grupos`: el ORDEN + los TÍTULOS de los grupos, la fuente única de lo que el QML y la cara web
    # tenían hardcodeado. Se leen de las filas `@grupo<TAB>clave<TAB>título` en su orden de declaración.
    printf '],"grupos":['
    local gp=1 marca clave titulo
    while IFS=$'\t' read -r marca clave titulo; do
        [ "$marca" = "@grupo" ] || continue
        [ "$gp" -eq 1 ] && gp=0 || printf ','
        printf '{"clave":%s,"titulo":%s}' "$(json_str "$clave")" "$(json_str "$titulo")"
    done < "$SPEC"
    printf ']}\n'
}

# --- validación del valor contra el spec ---
validar() {
    local env_var="$1" val="$2"
    local tipo mn mx cero
    tipo="$(campo "$env_var" 4)"; mn="$(campo "$env_var" 6)"; mx="$(campo "$env_var" 7)"; cero="$(campo "$env_var" 8)"
    case "$tipo" in
      entero|bytes|ms)
        case "$val" in ''|*[!0-9]*) morir "«$val» no es un entero: $env_var es de tipo $tipo" 2 ;; esac
        # El 0 solo vale donde APAGA el mecanismo; en los demás sería un tope de cero, que no existe.
        if [ "$val" -eq 0 ]; then
            [ "$cero" = "1" ] || morir "0 no es válido para $env_var (solo lo es donde APAGA el mecanismo)" 2
            return 0
        fi
        [ "$mn" != "-" ] && [ "$val" -lt "$mn" ] && morir "$val queda por debajo del mínimo de $env_var ($mn)" 2
        [ "$mx" != "-" ] && [ "$val" -gt "$mx" ] && morir "$val pasa el máximo de $env_var ($mx)" 2
        ;;
      ruta|texto)
        [ -n "$val" ] || morir "$env_var no acepta un valor vacío (usa `unset` para volver al default)" 2
        # Un salto de línea partiría el archivo en dos y podría inyectar OTRA variable.
        case "$val" in *$'\n'*|*$'\r'*) morir "el valor de $env_var no puede contener saltos de línea" 2 ;; esac
        ;;
      *) morir "tipo desconocido «$tipo» para $env_var (¿el spec está mal?)" 3 ;;
    esac
    return 0
}

# Reescribe el .env con la clave puesta (o comentada si `val` viene vacío), ATÓMICO y sin tocar el
# TOKEN. Se conservan TODAS las demás líneas tal cual: los comentarios de ese archivo documentan cada
# knob y son la razón de que alguien pueda editarlo a mano.
escribir() {
    local clave="$1" val="${2-}" tmp escrito=0 linea
    [ -f "$ENV_FILE" ] || morir "no existe $ENV_FILE — corre primero: ./install.sh --con-term-broker" 3
    tmp="$(umask 077; mktemp "${ENV_FILE}.XXXXXX")" || morir "no pude crear el temporal" 1
    while IFS= read -r linea || [ -n "$linea" ]; do
        # La línea ACTIVA de esta clave, o su versión comentada (que es como la siembra el instalador).
        if printf '%s' "$linea" | grep -qE "^[[:space:]]*#?[[:space:]]*${clave}="; then
            if [ "$escrito" -eq 0 ]; then
                if [ -n "$val" ]; then printf '%s=%s\n' "$clave" "$val" >> "$tmp"
                else printf '# %s=  # (default; lo puso a default el widget)\n' "$clave" >> "$tmp"; fi
                escrito=1
            fi
            continue
        fi
        printf '%s\n' "$linea" >> "$tmp"
    done < "$ENV_FILE"
    # No estaba ni comentada (un .env viejo): se agrega al final.
    if [ "$escrito" -eq 0 ] && [ -n "$val" ]; then printf '%s=%s\n' "$clave" "$val" >> "$tmp"; fi
    chmod 600 "$tmp" && mv -f "$tmp" "$ENV_FILE" || { rm -f "$tmp"; morir "no pude reemplazar $ENV_FILE" 1; }
}

case "${1-}" in
  list) listar ;;
  set)
    [ $# -ge 3 ] || morir 'uso: broker-knobs.sh set <ENV_VAR> <valor>' 2
    [ -n "$SPEC" ] && [ -f "$SPEC" ] || morir 'no encuentro el spec de knobs' 3
    declarado "$2" || morir "«$2» no es un knob declarado en el spec — no lo escribo" 2
    [ "$(campo "$2" 10)" = "edita" ] || morir "«$2» es solo-lectura en la GUI a propósito (ver el spec: expone RCE o rompe el contrato con el cliente). Edítalo a mano en $ENV_FILE." 2
    validar "$2" "$3"
    escribir "$2" "$3"
    printf '%s=%s escrito. NO aplica hasta reiniciar el servicio.\n' "$2" "$3"
    ;;
  unset)
    [ $# -ge 2 ] || morir 'uso: broker-knobs.sh unset <ENV_VAR>' 2
    [ -n "$SPEC" ] && [ -f "$SPEC" ] || morir 'no encuentro el spec de knobs' 3
    declarado "$2" || morir "«$2» no es un knob declarado en el spec" 2
    [ "$(campo "$2" 10)" = "edita" ] || morir "«$2» es solo-lectura en la GUI a propósito" 2
    escribir "$2" ""
    printf '%s vuelve a su default (%s). NO aplica hasta reiniciar el servicio.\n' "$2" "$(campo "$2" 5)"
    ;;
  *) printf 'uso: %s {list|set <ENV_VAR> <valor>|unset <ENV_VAR>}\n' "$(basename "$0")" >&2; exit 2 ;;
esac
