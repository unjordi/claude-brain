#!/usr/bin/env bash
# migrar-term-broker.sh — cambia el broker de terminal de la unidad LEGACY de axon
# (`axon-term-broker.service`, instalada a mano apuntando a un clon) a la de cortex
# (`cortex-term-broker.service`), en el orden correcto, VERIFICANDO con el token de verdad, y
# sabiendo revertir solo si algo sale mal.
#
# Existe porque esto NO puede ser una lista de comandos para pegar: opera sobre el recurso que el
# usuario usa a diario (su terminal), las dos unidades comparten puerto Y socket —así que el orden
# importa y hay una ventana en la que ninguna sirve—, y el paso de "verificación" que se pegaba a
# mano (un POST sin auth esperando 401) daba 401 SIEMPRE: con el broker viejo, con el nuevo, con
# cualquier token, y hasta con el proceso muerto. O sea, no verificaba nada.
#
#   migrar-term-broker.sh                 # migra (adoptando el token legacy: el cliente no cambia)
#   migrar-term-broker.sh --dry-run       # solo diagnostica: qué hay, qué haría. No toca nada.
#   migrar-term-broker.sh --token-nuevo   # usa el token que generó el instalador (hay que actualizar
#                                         # el .env del cliente; se te dice cómo al final)
#   migrar-term-broker.sh --revertir      # vuelve a la unidad legacy (y restaura el token si lo tocó)
#   migrar-term-broker.sh --verificar     # solo corre la verificación contra lo que esté activo
#
# IDEMPOTENTE: si ya estás migrado y verifica bien, no hace nada y sale 0.
# Si la verificación FALLA, revierte SOLO (vuelve a la legacy) y sale != 0 diciendo por qué.
set -uo pipefail

UNIT_NUEVA="cortex-term-broker.service"
UNIT_LEGACY="axon-term-broker.service"
ENV_NUEVO="$HOME/.config/cortex/term-broker.env"
ENV_LEGACY="$HOME/.config/axon/maincar.env"
ENV_BACKUP="$HOME/.config/cortex/term-broker.env.pre-migracion"

MODO="migrar"
TOKEN_MODO="legacy"        # legacy = adoptar el del broker viejo (el cliente NO cambia)
DRY=0
for a in "$@"; do
  case "$a" in
    --dry-run)     DRY=1 ;;
    --revertir)    MODO="revertir" ;;
    --verificar)   MODO="verificar" ;;
    --token-nuevo) TOKEN_MODO="nuevo" ;;
    --token-legacy) TOKEN_MODO="legacy" ;;
    -h|--help)     sed -n '2,/^set -uo/p' "$0" | sed 's/^#\( \|$\)//; $d'; exit 0 ;;
    *) echo "arg desconocido: $a (prueba --help)" >&2; exit 2 ;;
  esac
done

say()  { echo "migrar-term-broker > $*"; }
warn() { echo "migrar-term-broker > ⚠️  $*" >&2; }
die()  { echo "migrar-term-broker > ❌ $*" >&2; exit 1; }

# ── Config efectiva: se LEE del env del servicio, no se adivina ────────────────────────────────
leer_env() {  # leer_env <archivo> <VAR>  -> imprime el valor, sin comillas
  [[ -f "$1" ]] || return 1
  local v; v="$(grep -m1 "^${2}=" "$1" 2>/dev/null | cut -d= -f2-)" || return 1
  [[ -n "$v" ]] || return 1
  printf '%s' "${v%\"}" | sed 's/^"//'
}

PORT="$(leer_env "$ENV_NUEVO" AXON_TERM_BROKER_PORT || true)"; PORT="${PORT:-8799}"
SOCK="$(leer_env "$ENV_NUEVO" AXON_TERM_BROKER_SOCKET || true)"
if [[ -z "${SOCK:-}" ]]; then
  # Mismo default que `defaultBrokerSocketPath()` en term-host-broker.ts.
  if [[ -n "${XDG_RUNTIME_DIR:-}" ]]; then SOCK="$XDG_RUNTIME_DIR/axon/term-broker.sock"
  else SOCK="$HOME/.axon/term-broker.sock"; fi
fi

activo()    { systemctl --user is-active  --quiet "$1" 2>/dev/null; }
habilitado(){ systemctl --user is-enabled --quiet "$1" 2>/dev/null; }
existe_unit(){ [[ -f "$HOME/.config/systemd/user/$1" ]] || systemctl --user cat "$1" >/dev/null 2>&1; }

# ── VERIFICACIÓN REAL ───────────────────────────────────────────────────────────────────────────
# Con el TOKEN de verdad, y por los DOS transportes. Un 401 sin auth es un control NEGATIVO útil
# solo si va acompañado del positivo: por sí solo lo devuelve cualquier cosa, incluso otro broker.
#   1. GET /health con Bearer por el SOCKET UNIX  -> 200 (es el transporte del cliente contenerizado)
#   2. GET /health con Bearer por TCP             -> 200
#   3. GET /health SIN Bearer                     -> 401 (el token se está exigiendo de verdad)
#   4. POST /run con Bearer, comando con marca    -> la marca en el wire SSE + exit 0 + [DONE],
#                                                    o sea: ejecutó EN ESTA MÁQUINA, como este usuario
#   5. permisos del socket: 0600 y dueño = yo
# `/health` es del broker de hoy; uno viejo devuelve 404 y ahí lo decimos con nombre y apellido en
# vez de dar un "falla" opaco.
verificar() {
  local token="$1" fallos=0 marca code out
  local tmp; tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' RETURN
  command -v curl >/dev/null 2>&1 || { warn "sin curl no puedo verificar"; return 1; }

  ok()  { echo "    ✅ $1"; }
  no()  { echo "    ❌ $1"; fallos=$((fallos+1)); }

  # 1) /health por el socket unix
  if [[ -S "$SOCK" ]]; then
    code="$(curl -s -o "$tmp/h1" -w '%{http_code}' --max-time 5 --unix-socket "$SOCK" \
            -H "Authorization: Bearer $token" http://localhost/health 2>/dev/null)"
    if   [[ "$code" == "200" ]] && grep -q '"ok":true' "$tmp/h1"; then ok "socket unix: GET /health con token -> 200"
    elif [[ "$code" == "404" ]]; then no "socket unix: /health da 404 — el broker que corre es ANTERIOR al de hoy (sin /health)"
    elif [[ "$code" == "401" ]]; then no "socket unix: 401 — el token que estoy usando NO es el del broker que corre"
    else no "socket unix: GET /health -> ${code:-sin respuesta} (esperaba 200)"; fi
  else
    no "no existe el socket $SOCK — un cliente EN CONTENEDOR no tendría por dónde entrar"
  fi

  # 2) /health por TCP
  code="$(curl -s -o "$tmp/h2" -w '%{http_code}' --max-time 5 \
          -H "Authorization: Bearer $token" "http://127.0.0.1:$PORT/health" 2>/dev/null)"
  if   [[ "$code" == "200" ]] && grep -q '"ok":true' "$tmp/h2"; then ok "TCP 127.0.0.1:$PORT: GET /health con token -> 200"
  elif [[ "$code" == "404" ]]; then no "TCP: /health da 404 — broker ANTERIOR al de hoy"
  elif [[ "$code" == "401" ]]; then no "TCP: 401 — el token no calza con el del broker que corre"
  else no "TCP: GET /health -> ${code:-sin respuesta} (esperaba 200)"; fi

  # 3) control NEGATIVO (solo vale junto al positivo de arriba)
  code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 "http://127.0.0.1:$PORT/health" 2>/dev/null)"
  [[ "$code" == "401" ]] && ok "sin Authorization -> 401 (el token se exige)" || no "sin Authorization -> ${code:-sin respuesta} (esperaba 401)"

  # 4) EJECUCIÓN de verdad, con el wire SSE completo
  marca="MIGRACION-OK-$$-$(date +%s)"
  curl -s -N --max-time 25 -X POST "http://127.0.0.1:$PORT/run" \
       -H "Authorization: Bearer $token" -H 'Content-Type: application/json' \
       -d "{\"cmd\":\"echo $marca; id -un\",\"session\":\"migracion\"}" > "$tmp/run" 2>/dev/null
  grep -q "$marca"                    "$tmp/run" && ok "/run ejecutó de verdad (la marca volvió en el stream)" || no "/run no devolvió la marca"
  grep -q "$(id -un)"                 "$tmp/run" && ok "corrió como $(id -un) en ESTA máquina"                  || no "/run no corrió como $(id -un)"
  grep -q '"type":"exit","code":0'    "$tmp/run" && ok "wire SSE: exit code 0"                                  || no "wire SSE sin exit 0"
  grep -q 'data: \[DONE\]'            "$tmp/run" && ok "wire SSE: cierra con [DONE]"                            || no "wire SSE sin [DONE]"

  # 5) permisos del socket
  if [[ -S "$SOCK" ]]; then
    out="$(stat -c '%a %U' "$SOCK" 2>/dev/null)"
    [[ "$out" == "600 $(id -un)" ]] && ok "socket 0600 y dueño $(id -un)" || no "socket con permisos/dueño inesperados: $out"
  fi

  [[ "$fallos" -eq 0 ]]
}

token_actual() { leer_env "$ENV_NUEVO" AXON_TERM_BROKER_TOKEN; }

# ── REVERTIR ────────────────────────────────────────────────────────────────────────────────────
revertir() {
  say "revirtiendo a $UNIT_LEGACY…"
  systemctl --user disable --now "$UNIT_NUEVA" >/dev/null 2>&1
  esperar_endpoint_libre 15 || warn "el endpoint sigue ocupado; la legacy podría no arrancar"
  if [[ -f "$ENV_BACKUP" ]]; then
    say "restaurando el token previo a la migración -> $ENV_NUEVO"
    cp -f "$ENV_BACKUP" "$ENV_NUEVO" && chmod 600 "$ENV_NUEVO"
  fi
  if existe_unit "$UNIT_LEGACY"; then
    systemctl --user enable --now "$UNIT_LEGACY" >/dev/null 2>&1 \
      && say "$UNIT_LEGACY de vuelta arriba." \
      || warn "no pude levantar $UNIT_LEGACY — revísala a mano: systemctl --user status $UNIT_LEGACY"
  else
    warn "la unidad legacy ya no está en disco: no hay a qué volver."
  fi
  say "OJO: el contenedor del cliente puede necesitar reconectar (el socket se recreó)."
}

esperar_endpoint_libre() {  # esperar_endpoint_libre <intentos>
  local n="${1:-20}" i
  for ((i=0; i<n; i++)); do
    local ocupado=0
    if command -v ss >/dev/null 2>&1; then
      ss -ltnH "sport = :$PORT" 2>/dev/null | grep -q . && ocupado=1
      ss -lxH 2>/dev/null | grep -qF -- "$SOCK" && ocupado=1
    fi
    [[ "$ocupado" -eq 0 ]] && return 0
    sleep 0.5
  done
  return 1
}

esperar_activo() {  # esperar_activo <unit> <intentos>
  local u="$1" n="${2:-30}" i
  for ((i=0; i<n; i++)); do
    activo "$u" && return 0
    # `failed` no se cura esperando: gracias al StartLimit de la unidad, aquí SÍ se llega.
    [[ "$(systemctl --user is-active "$u" 2>/dev/null)" == "failed" ]] && return 1
    sleep 0.5
  done
  return 1
}

# ── DIAGNÓSTICO (siempre se imprime; es lo único que corre en --dry-run) ────────────────────────
# `systemctl is-active/is-enabled` IMPRIME el estado y además sale != 0 cuando no es active/enabled:
# un `$(… || echo ausente)` imprime AMBAS cosas, en dos líneas. Se toma solo la primera palabra.
estado() { local v; v="$(systemctl --user "$2" "$1" 2>/dev/null | head -1)"; echo "${v:-ausente}"; }
say "estado actual:"
echo "    $UNIT_LEGACY : $(estado "$UNIT_LEGACY" is-active) / $(estado "$UNIT_LEGACY" is-enabled)"
echo "    $UNIT_NUEVA  : $(estado "$UNIT_NUEVA" is-active) / $(estado "$UNIT_NUEVA" is-enabled)"
echo "    endpoint     : TCP 127.0.0.1:$PORT · socket $SOCK"
if command -v ss >/dev/null 2>&1; then
  echo "    ocupa el TCP : $(ss -ltnpH "sport = :$PORT" 2>/dev/null | tr -s ' ' | head -1 || true)"
  echo "    socket vivo  : $(ss -lxH 2>/dev/null | grep -cF -- "$SOCK" || true) listener(s)"
fi
TOK_NUEVO="$(token_actual || true)"
TOK_LEGACY="$(leer_env "$ENV_LEGACY" AXON_TERM_BROKER_TOKEN || true)"
echo "    token cortex : $([[ -n "${TOK_NUEVO:-}" ]] && echo "presente (${#TOK_NUEVO} chars)" || echo AUSENTE) en $ENV_NUEVO"
echo "    token legacy : $([[ -n "${TOK_LEGACY:-}" ]] && echo "presente (${#TOK_LEGACY} chars)" || echo "ausente ($ENV_LEGACY)")"
if [[ -n "${TOK_NUEVO:-}" && -n "${TOK_LEGACY:-}" ]]; then
  [[ "$TOK_NUEVO" == "$TOK_LEGACY" ]] && echo "    ⇒ los tokens YA son el mismo: el cliente no nota el cambio." \
                                      || echo "    ⇒ los tokens DIFIEREN (por eso el default es adoptar el legacy)."
fi
echo ""

case "$MODO" in
  verificar)
    [[ -n "${TOK_NUEVO:-}" ]] || die "no hay token en $ENV_NUEVO — no puedo verificar."
    say "verificando contra lo que esté escuchando ahora…"
    verificar "$TOK_NUEVO" && { say "✅ verificación OK."; exit 0; } || die "verificación FALLIDA (ver ❌ arriba)."
    ;;
  revertir)
    [[ "$DRY" -eq 1 ]] && { say "(--dry-run) revertiría: stop+disable $UNIT_NUEVA, restaurar token, enable --now $UNIT_LEGACY"; exit 0; }
    revertir; exit 0
    ;;
esac

# ── MIGRAR ──────────────────────────────────────────────────────────────────────────────────────
# En --dry-run los faltantes se AVISAN pero no matan: el modo existe para diagnosticar una máquina
# donde todavía no corriste el instalador, que es justo cuando más quieres ver el plan.
falta() { if [[ "$DRY" -eq 1 ]]; then warn "$1"; else die "$1"; fi; }
existe_unit "$UNIT_NUEVA" || falta "no encuentro $UNIT_NUEVA — corre primero:  ./install.sh --con-term-broker"
[[ -x "$HOME/.local/bin/cortex-term-broker" ]] || falta "falta ~/.local/bin/cortex-term-broker — reinstala con --con-term-broker"
[[ -n "${TOK_NUEVO:-}" ]] || falta "no hay AXON_TERM_BROKER_TOKEN en $ENV_NUEVO"

# Idempotencia: ya migrado (legacy apagada y la nueva sirviendo bien) ⇒ no se toca nada.
if ! activo "$UNIT_LEGACY" && activo "$UNIT_NUEVA"; then
  say "ya parece migrado; solo verifico."
  if verificar "$TOK_NUEVO"; then say "✅ ya estabas migrado y funciona. Nada que hacer."; exit 0; fi
  warn "está la unidad nueva activa pero NO verifica. Sigo con los pasos para dejarla bien."
fi

TOKEN_A_USAR="$TOK_NUEVO"
ADOPTAR=0
if [[ "$TOKEN_MODO" == "legacy" ]]; then
  if [[ -z "${TOK_LEGACY:-}" ]]; then
    warn "no hay token legacy que adoptar ($ENV_LEGACY); sigo con el token de cortex."
  elif [[ "$TOK_LEGACY" == "$TOK_NUEVO" ]]; then
    say "el token de cortex YA es el legacy: nada que adoptar."
  else
    ADOPTAR=1; TOKEN_A_USAR="$TOK_LEGACY"
  fi
fi

if [[ "$DRY" -eq 1 ]]; then
  say "(--dry-run) haría, en este orden:"
  [[ "$ADOPTAR" -eq 1 ]] && echo "    0. respaldar $ENV_NUEVO y adoptar el token legacy (el cliente NO cambia)"
  echo "    1. systemctl --user disable --now $UNIT_LEGACY   (mata las terminales abiertas ahí)"
  echo "    2. esperar a que se liberen el TCP :$PORT y el socket $SOCK"
  echo "    3. systemctl --user enable --now $UNIT_NUEVA"
  echo "    4. verificar con el token REAL: /health por socket y por TCP, 401 sin token, /run con marca"
  echo "    5. si (4) falla -> revertir solo a $UNIT_LEGACY y salir != 0"
  exit 0
fi

warn "esto CIERRA las terminales que tengas abiertas en el widget (son hijas del broker)."

if [[ "$ADOPTAR" -eq 1 ]]; then
  say "adoptando el token legacy (así el .env del cliente NO cambia)"
  cp -f "$ENV_NUEVO" "$ENV_BACKUP" && chmod 600 "$ENV_BACKUP"
  # Se reescribe SOLO la línea del token; el resto del archivo (comentarios, overrides) se conserva.
  tmpf="$(mktemp)"; chmod 600 "$tmpf"
  sed "s|^AXON_TERM_BROKER_TOKEN=.*|AXON_TERM_BROKER_TOKEN=$TOK_LEGACY|" "$ENV_NUEVO" > "$tmpf"
  grep -q '^AXON_TERM_BROKER_TOKEN=' "$tmpf" || echo "AXON_TERM_BROKER_TOKEN=$TOK_LEGACY" >> "$tmpf"
  cp -f "$tmpf" "$ENV_NUEVO"; rm -f "$tmpf"; chmod 600 "$ENV_NUEVO"
  say "respaldo del anterior en $ENV_BACKUP (lo restaura --revertir)"
fi

say "1/4 apagando $UNIT_LEGACY…"
systemctl --user disable --now "$UNIT_LEGACY" >/dev/null 2>&1 || warn "disable --now de la legacy devolvió != 0 (¿ya estaba apagada?)"

say "2/4 esperando a que se liberen TCP :$PORT y $SOCK…"
if ! esperar_endpoint_libre 30; then
  warn "el endpoint SIGUE ocupado tras 15 s. No arranco la nueva encima."
  warn "mira quién es:  ss -ltnp 'sport = :$PORT'   ·   ss -lxp | grep $SOCK"
  revertir
  die "endpoint ocupado por un tercero — aborté y volví a la legacy."
fi

say "3/4 levantando $UNIT_NUEVA…"
systemctl --user enable --now "$UNIT_NUEVA" >/dev/null 2>&1
if ! esperar_activo "$UNIT_NUEVA" 40; then
  warn "$UNIT_NUEVA no llegó a 'active'. Últimas líneas del journal:"
  systemctl --user status "$UNIT_NUEVA" --no-pager -n 20 2>&1 | sed 's/^/    /'
  revertir
  die "la unidad nueva no arrancó — aborté y volví a la legacy."
fi
sleep 1   # margen para que ambos listeners terminen de bindear (el log de 'escuchando' es el gate real)

say "4/4 verificando con el token REAL (no un 401 que da cualquiera)…"
if ! verificar "$TOKEN_A_USAR"; then
  warn "la verificación falló. Revierto para dejarte la terminal funcionando."
  revertir
  die "migración revertida. Nada quedó a medias."
fi

say "✅ migrado y verificado."
echo ""
say "lo que sigue, en tu orden:"
if [[ "$ADOPTAR" -eq 1 ]]; then
  echo "    • El cliente NO cambia: adopté el token que ya tenía."
else
  echo "    • El token es OTRO: actualiza el .env del cliente y redespliega su servicio."
  echo "        grep '^AXON_TERM_BROKER_TOKEN=' $ENV_NUEVO >> /ruta/al/.env/del/cliente"
fi
echo "    • El socket se RECREÓ: si el cliente ya estaba conectado, reinícialo para que reconecte."
echo "    • La unidad legacy quedó apagada y deshabilitada, pero SIGUE en disco (por si revertir)."
echo "      Cuando lleves un rato bien, retírala:"
echo "        rm ~/.config/systemd/user/$UNIT_LEGACY && systemctl --user daemon-reload"
echo "    • Volver atrás en cualquier momento:  $0 --revertir"
