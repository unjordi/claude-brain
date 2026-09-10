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
#   8. el SOCKET UNIX (el transporte del cliente contenerizado): sirve /health y /run con el token,
#      401 sin token, y queda en 0600 — no basta con que exista el archivo.
#   9. `GET /health` responde 200 con token y 401 sin él (es lo que el badge de la terminal SONDEA;
#      un broker sin /health devuelve 404 y el badge miente en la otra dirección).
#  10. EL TOKEN NO APARECE EN EL `env` DE UNA SESIÓN REAL. Es el único check que ATA las dos mitades
#      de la defensa del prefijo `AXON_`: el NOMBRE de la variable (definido en el instalador, en la
#      unidad y en el lanzador) y el literal `"AXON_"` enterrado en `buildSessionEnv()` de un módulo
#      vendorizado. Hasta hoy eso era una coincidencia de strings sin una sola prueba que la sostenga:
#      renombrar la variable a `CORTEX_*` dejaría de barrerla y el token del broker saldría en el
#      `env` de cada terminal del widget, sin que nada fallara.
# Al final mata el broker de prueba. NO toca ningún servicio de systemd.
#
# AISLAMIENTO: puerto propio (18799) Y SOCKET propio (en el tmpdir). Sin lo segundo, este probe
# abriría `$XDG_RUNTIME_DIR/axon/term-broker.sock` — el socket del broker que el usuario ESTÁ USANDO.
# El broker de hoy sondea antes y se niega a pisarlo (falla ruidoso), pero depender de eso sería
# apostar la terminal de alguien a que ese sondeo nunca tenga una carrera.
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
SOCK="$TMP/probe-broker.sock"     # NUNCA el socket real del servicio — ver AISLAMIENTO arriba
# Centinela del CONTROL POSITIVO del barrido de env (abajo). Valor DISTINTO del token a propósito:
# si reusara el mismo, el check "el valor del token no aparece" fallaría por el control mismo — y de
# hecho falló al escribir esto, que es justo la demostración de que ese check no es decorativo.
CONTROL_FUGA="control-fuga-$$-no-es-un-secreto"
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
      AXON_TERM_BROKER_PORT="$PORT" AXON_TERM_BROKER_SOCKET="$SOCK" bash bin/cortex-term-broker 2>&1)"; rc=$?
ck "sin token NO arranca (exit != 0)"      test "$rc" -ne 0
ck "y dice por qué"                        grep -q "AXON_TERM_BROKER_TOKEN" <<<"$out"

# ── levanta el bueno ──
( cd "$ROOT" && exec env CORTEX_TERM_BROKER_LIB="$ROOT/src/term-broker" \
    AXON_TERM_BROKER_TOKEN="$TOKEN" AXON_TERM_BROKER_PORT="$PORT" AXON_TERM_BROKER_HOME="$TMP" \
    AXON_TERM_BROKER_SOCKET="$SOCK" \
    CORTEX_TERM_BROKER_TOKEN="$CONTROL_FUGA" \
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
echo "— GET /health (lo que SONDEA el badge de la terminal) —"
code="$(curl -s -o "$TMP/health.json" -w '%{http_code}' --max-time 5 \
        -H "Authorization: Bearer $TOKEN" "http://127.0.0.1:$PORT/health")"
ck "con token -> 200"                      test "$code" = "200"
ck "responde {\"ok\":true}"                 grep -q '"ok":true' "$TMP/health.json"
code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 "http://127.0.0.1:$PORT/health")"
ck "sin token -> 401"                      test "$code" = "401"

echo
echo "— SOCKET UNIX (el transporte del cliente EN CONTENEDOR) —"
# Un contenedor NO alcanza un bind a 127.0.0.1 del host: si esto no sirve, la terminal del widget
# está muerta aunque el TCP responda perfecto desde el host. Por eso se prueba aparte, no "por
# simetría": es el transporte que de verdad usa el cliente.
ck "el socket existe"                      test -S "$SOCK"
ck "el socket es 0600"                     bash -c '[[ "$(stat -c %a "'"$SOCK"'")" == "600" ]]'
code="$(curl -s -o "$TMP/sock-health.json" -w '%{http_code}' --max-time 5 --unix-socket "$SOCK" \
        -H "Authorization: Bearer $TOKEN" http://localhost/health)"
ck "socket: /health con token -> 200"      test "$code" = "200"
code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 --unix-socket "$SOCK" http://localhost/health)"
ck "socket: /health sin token -> 401"      test "$code" = "401"
curl -s -N --max-time 25 --unix-socket "$SOCK" -X POST http://localhost/run \
     -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' \
     -d '{"cmd":"echo SOCKET-OK","session":"probe-sock"}' > "$TMP/sockrun.txt"
ck "socket: /run ejecuta de verdad"        grep -q "SOCKET-OK" "$TMP/sockrun.txt"
ck "socket: wire con exit 0 y [DONE]"      bash -c 'grep -q "\"type\":\"exit\",\"code\":0" "'"$TMP"'/sockrun.txt" && grep -q "data: \[DONE\]" "'"$TMP"'/sockrun.txt"'
# El pool de sesiones es UNO SOLO para ambos listeners: una `session` entra por donde entre y es la
# misma shell. Si esto se rompiera, el widget vería su cwd resetearse al cambiar de transporte.
curl -s -N --max-time 25 --unix-socket "$SOCK" -X POST http://localhost/run \
     -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' \
     -d '{"cmd":"pwd","session":"probe"}' > "$TMP/sock-misma-sesion.txt"
ck "socket y TCP comparten el pool de sesiones" grep -q "subdir" "$TMP/sock-misma-sesion.txt"

echo
echo "— el token NO se filtra al \`env\` de la sesión (el prefijo AXON_ tiene que servir de verdad) —"
# Esto es lo que convierte la nota de PROCEDENCIA.md en MECANISMO. La seguridad del prefijo depende
# de que el NOMBRE de la variable (que se define en install.sh, en la unidad y en el lanzador)
# empiece con `AXON_`, porque `buildSessionEnv()` (term-session.ts) barre exactamente ese prefijo.
# Son dos strings en archivos distintos que nadie ataba: renombrar a CORTEX_* pasaría todos los
# demás checks y filtraría el token a CADA terminal del widget.
curl -s -N --max-time 25 -X POST "http://127.0.0.1:$PORT/run" \
     -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' \
     -d '{"cmd":"env","session":"probe-env"}' > "$TMP/env.txt"
ck "la sesión respondió (hay wire)"        grep -q '"type":"exit","code":0' "$TMP/env.txt"
ck "el VALOR del token no está en el env"  bash -c '! grep -qF "'"$TOKEN"'" "'"$TMP"'/env.txt"'
ck "ni el NOMBRE AXON_TERM_BROKER_TOKEN"   bash -c '! grep -q "AXON_TERM_BROKER_TOKEN" "'"$TMP"'/env.txt"'
ck "ninguna AXON_* sobrevive al barrido"   bash -c '! grep -qE "AXON_[A-Z_]+=" "'"$TMP"'/env.txt"'
ck "ANTHROPIC_API_KEY tampoco"             bash -c '! grep -q "ANTHROPIC_API_KEY" "'"$TMP"'/env.txt"'
# CONTROL POSITIVO — que los checks de arriba no sean vacíos. El broker se arrancó con una variable
# gemela SIN el prefijo (`CORTEX_TERM_BROKER_TOKEN`, el nombre "coherente" que alguien va a proponer
# tarde o temprano): tiene que APARECER en el env. Si un día NO aparece, es que el barrido cambió y
# los 4 checks de arriba dejaron de demostrar algo. Esta es la mitad que convierte la nota en prueba.
ck "control: una var SIN prefijo AXON_ SÍ se filtra (por eso el nombre no se cambia)" \
   grep -q "$CONTROL_FUGA" "$TMP/env.txt"

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
