#!/usr/bin/env bash
# broker-scan.sh — helper del plasmoid de KDE "Cortex Widget".
# El plasmoid no puede leer archivos ni correr procesos; lo hace por el DataSource
# "executable" de Plasma, que captura stdout y el exit code. Este helper es el
# brazo de la pestaña "Broker".
#
# Subcomando: scan. Imprime en stdout UN objeto JSON y nada más.
# Sin subcomando o con uno desconocido: imprime el uso a stderr y sale 2.

set -u
# El PATH se APENDA (no se prepone): lo que este export arregla es un PATH MINIMO -- el
# entorno del plasmoid llega sin /usr/sbin y ahi `ss` no se halla. Apendar lo cubre igual, y
# ademas deja que un PATH deliberado del caller gane: preponer volvia este modulo
# imposible de verificar (ningun doble de `systemctl`/`ss` podia interponerse y el probe
# terminaba midiendo el systemd de la maquina real en vez del caso que queria probar).
export PATH="${PATH:-}:/usr/bin:/bin:/usr/sbin:/sbin"

# --- utilidades ---

# json_str: imprime un string JSON válido (con comillas y escapes) o null si el
# argumento es vacío.
json_str() {
    local s="${1:-}"
    if [ -z "$s" ]; then
        printf 'null'
    else
        # Escapar backslash y comilla doble.
        s="${s//\\/\\\\}"
        s="${s//\"/\\\"}"
        printf '"%s"' "$s"
    fi
}

# json_num: imprime un número JSON o null si el argumento no es un entero no negativo.
json_num() {
    local n="${1:-}"
    if [[ "$n" =~ ^[0-9]+$ ]]; then
        printf '%s' "$n"
    else
        printf 'null'
    fi
}

# json_bool: imprime true/false según el primer argumento (0 = true, otro = false).
json_bool() {
    if [ "$1" -eq 0 ]; then
        printf 'true'
    else
        printf 'false'
    fi
}

# leer_var_env: lee una variable de un archivo de env (líneas CLAVE=valor) sin
# ejecutarlo. Quita comillas envolventes si las trae. Imprime el valor o nada.
leer_var_env() {
    local archivo="$1" clave="$2"
    [ -f "$archivo" ] || return 1
    local linea
    linea=$(grep -E "^[[:space:]]*${clave}=" "$archivo" 2>/dev/null | head -n1)
    [ -n "$linea" ] || return 1
    # Quitar el prefijo CLAVE=
    linea="${linea#*=}"
    # Quitar el CR final de un archivo con finales de linea de Windows. Sin esto, un env editado
    # en Windows da un puerto "8799\r" que NO pasa el ^[0-9]+$ y cae al default en silencio, y un
    # token con un caracter de mas en el conteo.
    linea="${linea%$'\r'}"
    # Quitar comillas envolventes (simples o dobles)
    if [[ "$linea" == \"*\" ]]; then
        linea="${linea#\"}"
        linea="${linea%\"}"
    elif [[ "$linea" == \'*\' ]]; then
        linea="${linea#\'}"
        linea="${linea%\'}"
    fi
    printf '%s' "$linea"
}

# --- funciones por bloque del JSON ---

# unidad: emite el objeto JSON de una unidad systemd (cortex o legacy).
# $1 = nombre de la unidad
# $2 = si se incluyen campos de memoria/pid/reinicios (1 sí, 0 no)
unidad() {
    local nombre="$1" con_memoria="$2"
    local activa=1 habilitada=1 en_disco=1
    local estado="" desde="" pid="" mem="" mem_pico="" reinicios=""

    # activa
    if systemctl --user is-active --quiet "$nombre" 2>/dev/null; then
        activa=0
    fi
    # habilitada
    if systemctl --user is-enabled --quiet "$nombre" 2>/dev/null; then
        habilitada=0
    fi
    # en_disco
    if [ -f "${HOME:-}/.config/systemd/user/${nombre}" ]; then
        en_disco=0
    elif systemctl --user cat "$nombre" >/dev/null 2>&1; then
        en_disco=0
    fi

    if [ "$con_memoria" -eq 1 ]; then
        # UNA sola llamada a systemctl show
        local out
        out=$(systemctl --user show "$nombre" \
            -p ActiveState -p ActiveEnterTimestamp -p MainPID \
            -p MemoryCurrent -p MemoryPeak -p NRestarts 2>/dev/null)
        if [ -n "$out" ]; then
            local line
            while IFS= read -r line; do
                case "$line" in
                    ActiveState=*)
                        estado="${line#ActiveState=}"
                        ;;
                    ActiveEnterTimestamp=*)
                        desde="${line#ActiveEnterTimestamp=}"
                        ;;
                    MainPID=*)
                        pid="${line#MainPID=}"
                        ;;
                    MemoryCurrent=*)
                        mem="${line#MemoryCurrent=}"
                        ;;
                    MemoryPeak=*)
                        mem_pico="${line#MemoryPeak=}"
                        ;;
                    NRestarts=*)
                        reinicios="${line#NRestarts=}"
                        ;;
                esac
            done <<< "$out"
        fi
        # MainPID=0 significa que no corre → null
        if [ "$pid" = "0" ]; then
            pid=""
        fi
        # [not set] → null
        if [ "$mem" = "[not set]" ]; then
            mem=""
        fi
        if [ "$mem_pico" = "[not set]" ]; then
            mem_pico=""
        fi
    fi

    printf '{"nombre":%s,"activa":%s,"habilitada":%s,"en_disco":%s' \
        "$(json_str "$nombre")" \
        "$(json_bool "$activa")" \
        "$(json_bool "$habilitada")" \
        "$(json_bool "$en_disco")"

    if [ "$con_memoria" -eq 1 ]; then
        printf ',"estado":%s,"desde":%s,"pid":%s,"memoria_bytes":%s,"memoria_pico_bytes":%s,"reinicios":%s' \
            "$(json_str "$estado")" \
            "$(json_str "$desde")" \
            "$(json_num "$pid")" \
            "$(json_num "$mem")" \
            "$(json_num "$mem_pico")" \
            "$(json_num "$reinicios")"
    fi

    printf '}'
}

# endpoint: emite el objeto JSON del endpoint.
endpoint() {
    local env_file="${HOME:-}/.config/cortex/term-broker.env"
    local puerto="8799" socket="" socket_existe=1 socket_permisos="" socket_dueno="" escuchando=""

    # puerto
    local p
    p=$(leer_var_env "$env_file" "AXON_TERM_BROKER_PORT" 2>/dev/null)
    if [ -n "$p" ] && [[ "$p" =~ ^[0-9]+$ ]]; then
        puerto="$p"
    fi

    # socket
    local s
    s=$(leer_var_env "$env_file" "AXON_TERM_BROKER_SOCKET" 2>/dev/null)
    if [ -n "$s" ]; then
        socket="$s"
    elif [ -n "${XDG_RUNTIME_DIR:-}" ]; then
        socket="${XDG_RUNTIME_DIR}/axon/term-broker.sock"
    else
        socket="${HOME:-}/.axon/term-broker.sock"
    fi

    # socket_existe
    if [ -S "$socket" ]; then
        socket_existe=0
        socket_permisos=$(stat -c '%a' "$socket" 2>/dev/null)
        socket_dueno=$(stat -c '%U' "$socket" 2>/dev/null)
    fi

    # escuchando_tcp
    local ss_out
    if command -v ss >/dev/null 2>&1; then
        ss_out=$(ss -ltn 2>/dev/null)
        if [ -n "$ss_out" ] && grep -q "127.0.0.1:${puerto}" <<< "$ss_out"; then
            escuchando="true"
        else
            escuchando="false"
        fi
    else
        escuchando="null"
    fi

    printf '{"puerto":%s,"socket":%s,"socket_existe":%s,"socket_permisos":%s,"socket_dueno":%s,"escuchando_tcp":%s}' \
        "$(json_num "$puerto")" \
        "$(json_str "$socket")" \
        "$(json_bool "$socket_existe")" \
        "$(json_str "$socket_permisos")" \
        "$(json_str "$socket_dueno")" \
        "$escuchando"
}

# token: emite el objeto JSON del token.
token() {
    local env_file="${HOME:-}/.config/cortex/term-broker.env"
    local presente=1 chars=""

    if [ -f "$env_file" ]; then
        local t
        t=$(leer_var_env "$env_file" "AXON_TERM_BROKER_TOKEN" 2>/dev/null)
        if [ -n "$t" ]; then
            presente=0
            chars="${#t}"
        fi
    fi

    printf '{"presente":%s,"chars":%s,"archivo":%s}' \
        "$(json_bool "$presente")" \
        "$(json_num "$chars")" \
        "$(json_str "$env_file")"
}

# migrador: emite el objeto JSON del migrador.
migrador() {
    local ruta="" ejecutable=1
    # La copia INSTALADA va primero, y es la que la pestaña debe invocar: `install.sh` la pone ahi
    # con `install -D -m 0755` y `docs/term-broker.md` documenta esa ruta como la del migrador. La
    # del clon queda de respaldo para una maquina de desarrollo sin instalar, pero OJO: en el repo
    # el archivo esta commiteado 644 a proposito (es el instalador quien le pone el bit), asi que
    # invocar la del clon directamente falla con "permission denied" -- ejecutar la instalada es
    # tambien la regla de "usa la herramienta oficial, no el script crudo del repo".
    local candidatos=(
        "${HOME:-}/.local/bin/migrar-term-broker.sh"
        "${HOME:-}/.cortex/bin/migrar-term-broker.sh"
        "${HOME:-}/code/cortex/bin/migrar-term-broker.sh"
    )
    for c in "${candidatos[@]}"; do
        if [ -f "$c" ]; then
            ruta="$c"
            if [ -x "$c" ]; then
                ejecutable=0
            fi
            break
        fi
    done

    printf '{"ruta":%s,"ejecutable":%s}' \
        "$(json_str "$ruta")" \
        "$(json_bool "$ejecutable")"
}

# --- main ---

uso() {
    printf 'Uso: %s scan\n' "$0" >&2
    exit 2
}

main() {
    local sub="${1:-}"
    case "$sub" in
        scan)
            local generado
            generado=$(date -Iseconds 2>/dev/null)
            [ -n "$generado" ] || generado=""

            printf '{"generado_en":%s,"unidad":' "$(json_str "$generado")"
            unidad "cortex-term-broker.service" 1
            printf ',"legacy":'
            unidad "axon-term-broker.service" 0
            printf ',"endpoint":'
            endpoint
            printf ',"token":'
            token
            printf ',"migrador":'
            migrador
            printf '}\n'
            exit 0
            ;;
        *)
            uso
            ;;
    esac
}

main "$@"