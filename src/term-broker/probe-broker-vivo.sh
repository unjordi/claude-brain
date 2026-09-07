#!/usr/bin/env bash
# probe-broker-vivo.sh — prueba FUNCIONAL del broker vendorizado, levantándolo de verdad.
#
# Levanta `bin/cortex-term-broker` DESDE EL CLON (sin instalar nada) en un puerto de usar y tirar
# (18799 por default, NO el 8799 del servicio real), con un token efímero, y verifica:
#   1. sin token  -> 401 y NI SIQUIERA lee el body (auth antes que shell).
#   2. token malo -> 401.
#   3. token bueno -> corre el comando en ESTA máquina y devuelve el wire SSE esperado
#      ({type:"stdout",chunk} … {type:"exit",code:0} … [DONE]).
#   4. la sesión PERSISTE: un `cd` en un comando se ve en el siguiente (mismo `session`).
#   5. bindea SOLO a loopback (no aparece en 0.0.0.0).
#   6. sin AXON_TERM_BROKER_TOKEN el proceso NO arranca (fail loud, nunca "sin auth").
#   7. el canal PTY (`/pty`, WebSocket): 401 sin Bearer, y con Bearer un PTY real que ejecuta,
#      acepta resize y cierra limpio (delegado a probe-pty-ws.ts, que habla con el MISMO ws.ts).
# Al final mata el broker de prueba. NO toca ningún servicio de systemd.
#
# Uso:  bash src/term-broker/probe-broker-vivo.sh
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
PORT="${PROBE_PORT:-18799}"
pass=0; fail=0
check() { if [[ "$2" == "ok" ]]; then pass=$((pass+1)); echo "  ✅ $1"; else fail=$((fail+1)); echo "  ❌ $1"; fi; }
ck()    { if "${@:2}" >/dev/null 2>&1; then check "$1" ok; else check "$1" no; fi; }

command -v curl >/dev/null 2>&1 || { echo "necesita curl"; exit 1; }

TMP="$(mktemp -d)"
TOKEN="probe-$(od -An -tx1 -N8 /dev/urandom | tr -d ' \n')"
BROKER_PID=""
# El broker se lanza con `exec` (abajo) para que $BROKER_PID sea el PID de NODE y no el de un bash
# intermedio: matar el wrapper dejaba al node vivo ocupando el puerto, y la corrida siguiente hablaba
# con un broker viejo de token distinto (401 en todo) — pasó de verdad al escribir este probe.
# El barrido por cmdline es el cinturón: solo mata procesos cuyo argv apunte a ESTE clon.
cleanup() {
  [[ -n "$BROKER_PID" ]] && kill "$BROKER_PID" 2>/dev/null
  sleep 0.3
  pkill -9 -f "$ROOT/src/term-broker/term-host-broker.ts" 2>/dev/null
  /bin/rm -rf "$TMP"
}
trap cleanup EXIT

# Puerto libre antes de empezar: si algo quedó ahí, el probe mentiría (hablaría con otro broker).
if ss -ltnH "sport = :$PORT" 2>/dev/null | grep -q ":$PORT"; then
  echo "El puerto $PORT ya está ocupado — libéralo o usa PROBE_PORT=<otro>." >&2
  exit 1
fi

# ── 6) fail loud sin token (se prueba ANTES de levantar el bueno) ──
echo "— arranque —"
out="$(cd "$ROOT" && env -u AXON_TERM_BROKER_TOKEN CORTEX_TERM_BROKER_LIB="$ROOT/src/term-broker" \
      AXON_TERM_BROKER_PORT="$PORT" bash bin/cortex-term-broker 2>&1)"; rc=$?
ck "sin token NO arranca (exit != 0)"      test "$rc" -ne 0
ck "y dice por qué"                        grep -q "AXON_TERM_BROKER_TOKEN" <<<"$out"

# ── levanta el bueno ──
( cd "$ROOT" && exec env CORTEX_TERM_BROKER_LIB="$ROOT/src/term-broker" \
    AXON_TERM_BROKER_TOKEN="$TOKEN" AXON_TERM_BROKER_PORT="$PORT" AXON_TERM_BROKER_HOME="$TMP" \
    bash bin/cortex-term-broker > "$TMP/broker.log" 2>&1 ) &
BROKER_PID=$!
for _ in $(seq 1 40); do
  curl -s -o /dev/null --max-time 1 "http://127.0.0.1:$PORT/" && break
  sleep 0.25
done
ck "el broker levantó"                     kill -0 "$BROKER_PID"
ck "loguea el puerto en el que escucha"    grep -q "escuchando en 127.0.0.1:$PORT" "$TMP/broker.log"

echo
echo "— auth —"
code="$(curl -s -o "$TMP/noauth.txt" -w '%{http_code}' -X POST "http://127.0.0.1:$PORT/run" \
        -H 'Content-Type: application/json' -d '{"cmd":"echo NO-DEBE-CORRER"}')"
ck "sin Authorization -> 401"              test "$code" = "401"
ck "y no ejecutó nada"                     bash -c '! grep -q NO-DEBE-CORRER "'"$TMP"'/noauth.txt"'
code="$(curl -s -o /dev/null -w '%{http_code}' -X POST "http://127.0.0.1:$PORT/run" \
        -H "Authorization: Bearer token-equivocado" -H 'Content-Type: application/json' -d '{"cmd":"echo x"}')"
ck "token equivocado -> 401"               test "$code" = "401"

echo
echo "— ejecución en ESTA máquina + wire SSE —"
curl -s -N --max-time 25 -X POST "http://127.0.0.1:$PORT/run" \
     -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' \
     -d '{"cmd":"echo MARCA-$(id -un)","session":"probe"}' > "$TMP/run1.txt"
ck "corrió como el usuario real"           grep -q "MARCA-$(id -un)" "$TMP/run1.txt"
ck "wire: chunk de stdout"                 grep -q '"type":"stdout"' "$TMP/run1.txt"
ck "wire: exit code 0"                     grep -q '"type":"exit","code":0' "$TMP/run1.txt"
ck "wire: cierra con [DONE]"               grep -q 'data: \[DONE\]' "$TMP/run1.txt"

echo
echo "— la sesión persiste (cwd entre comandos) —"
mkdir -p "$TMP/subdir"
curl -s -N --max-time 25 -X POST "http://127.0.0.1:$PORT/run" \
     -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' \
     -d "{\"cmd\":\"cd $TMP/subdir\",\"session\":\"probe\"}" > /dev/null
curl -s -N --max-time 25 -X POST "http://127.0.0.1:$PORT/run" \
     -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' \
     -d '{"cmd":"pwd","session":"probe"}' > "$TMP/run2.txt"
ck "el cd del comando anterior persiste"   grep -q "subdir" "$TMP/run2.txt"

echo
echo "— canal PTY (WebSocket /pty) —"
node --disable-warning=ExperimentalWarning --experimental-strip-types \
     "$ROOT/src/term-broker/probe-pty-ws.ts" "$PORT" "$TOKEN" > "$TMP/pty.txt" 2>&1
pty_rc=$?
# Las líneas de check del sub-probe empiezan con dos espacios + el ícono; su línea RESUMEN
# ("  N ✅   M ❌") trae los dos, por eso el conteo ancla en `^  ✅` / `^  ❌` y no en el ícono suelto.
grep -E '^  (✅|❌) ' "$TMP/pty.txt" || true
pass=$((pass + $(grep -c '^  ✅ ' "$TMP/pty.txt")))
fail=$((fail + $(grep -c '^  ❌ ' "$TMP/pty.txt")))
if [[ "$pty_rc" -ne 0 ]]; then
  # Salió !=0 sin ningún ❌ contado ⇒ reventó antes de checar (import roto, conexión, timeout):
  # cuenta UN fallo explícito para que el resumen no diga "todo bien".
  grep -q '^  ❌ ' "$TMP/pty.txt" || { fail=$((fail+1)); echo "  ❌ el probe de PTY abortó (rc=$pty_rc)"; }
  echo "  (salida completa del probe de PTY:)"; sed 's/^/    /' "$TMP/pty.txt"
fi

echo
echo "— bind —"
if command -v ss >/dev/null 2>&1; then
  ss -ltnH "sport = :$PORT" > "$TMP/ss.txt" 2>/dev/null
  ck "escucha en 127.0.0.1 y NO en 0.0.0.0" bash -c 'grep -q "127.0.0.1:'"$PORT"'" "'"$TMP"'/ss.txt" && ! grep -q "0.0.0.0:'"$PORT"'" "'"$TMP"'/ss.txt"'
else
  echo "  (sin 'ss' — se salta la verificación de bind)"
fi

echo
echo "  ${pass} ✅   ${fail} ❌"
[[ "$fail" -eq 0 ]] || exit 1
