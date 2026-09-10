#!/usr/bin/env bash
# probe-instalador.sh — prueba FUNCIONAL del instalador del broker de terminal, en un SANDBOX.
#
# Qué demuestra, corriendo el ./install.sh REAL (no una simulación):
#   A) SIN --con-term-broker no queda NADA del broker (el caso por defecto, el que más importa).
#   B) CON --con-term-broker quedan: los 5 módulos, el lanzador ejecutable, la unidad, y un token
#      generado en un archivo 0600.
#   C) Es IDEMPOTENTE y NO regenera el token en una segunda corrida.
#   D) `install.sh --help` anuncia la bandera y no toca nada.
#   E) uninstall.sh retira todo lo del broker.
#   F) Con el ENDPOINT OCUPADO, NO habilita ni arranca la unidad — y si una corrida previa la había
#      habilitado, la DESHABILITA. Es el caso crítico: dos unidades habilitadas en default.target
#      sobre el mismo puerto y con tokens distintos no se notan hoy y explotan en el próximo reboot
#      (arrancan las dos, una gana el bind, la otra cicla; si gana la nueva el cliente recibe 401 y
#      axon se va al shell del contenedor sin una sola pista para el usuario).
#   G) Los VENDORIZADOS instalados calzan con SHA256SUMS, y los PROBES no se copian al runtime.
#   H) Los 5 módulos VENDORIZADOS typechecan (`tsc --noEmit`), si hay un `tsc` utilizable a mano —
#      si no lo hay, se AVISA y se SALTA (no se falla en falso). Corre sobre el ÁRBOL del repo, no
#      sobre el sandbox de instalación: protege contra un edit DECLARADO que no compila (el hashsum
#      de G solo protege contra un edit NO declarado). Ver PROCEDENCIA.md § "El anti-drift".
#
# Cómo es seguro: HOME apunta a un temporal y PATH a un directorio de stubs donde `systemctl`,
# `kpackagetool6`, `ccusage` y `claude` solo REGISTRAN su invocación en un log. Nada toca el
# systemd real, el plasmoid real ni el $HOME real. Se corre con --no-brain --no-plasmoid
# --no-claude-code --no-reload-shell para acotar el instalador a lo que este probe verifica.
#
# Uso:  bash src/term-broker/probe-instalador.sh
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
pass=0; fail=0
check() { if [[ "$2" == "ok" ]]; then pass=$((pass+1)); echo "  ✅ $1"; else fail=$((fail+1)); echo "  ❌ $1"; fi; }
ck()    { if "${@:2}" >/dev/null 2>&1; then check "$1" ok; else check "$1" no; fi; }
not_in_file()    { ! grep -qF -- "$1" "$2"; }
not_in_file_re() { ! grep -qE -- "$1" "$2"; }
is_hex64()       { [[ "$1" =~ ^[0-9a-f]{64}$ ]]; }

SANDBOX="$(mktemp -d)"
trap '/bin/rm -rf "$SANDBOX"' EXIT
export HOME="$SANDBOX/home"
mkdir -p "$HOME"
STUBS="$SANDBOX/stubs"; mkdir -p "$STUBS"
CALLS="$SANDBOX/systemctl-calls.log"; : > "$CALLS"

# Stubs: registran y salen 0. `systemctl --user is-active` debe salir !=0 (nada está activo en el
# sandbox) para no disparar la rama de "la unidad legacy ocupa el puerto".
cat > "$STUBS/systemctl" <<EOF
#!/usr/bin/env bash
echo "\$*" >> "$CALLS"
case " \$* " in *" is-active "*) exit 3 ;; esac
exit 0
EOF
for s in kpackagetool6 ccusage claude npm kquitapp6 kstart plasmashell; do
  printf '#!/usr/bin/env bash\nexit 0\n' > "$STUBS/$s"
done
chmod +x "$STUBS"/*
# PATH mínimo: los stubs primero, luego lo indispensable del sistema (coreutils, jq, sed, node…).
export PATH="$STUBS:/usr/bin:/bin"

# Corre el instalador REAL con el sandbox puesto; la salida va a un archivo (no a una variable:
# incrustarla en un `bash -c` rompe con las comillas del propio texto del instalador).
# El endpoint que vigila el instalador se apunta a valores LIBRES del sandbox: si se dejara en el
# 8799 real, el probe tomaría la rama de "endpoint ocupado" por el broker que el usuario está usando
# — y de paso el resultado dependería de si hay o no un broker vivo en la máquina. `ss` es real aquí
# (no está stubeado), así que esto no es cosmético.
export AXON_TERM_BROKER_PORT=18799
export AXON_TERM_BROKER_SOCKET="$SANDBOX/probe-instalador.sock"
run_install() { ( cd "$ROOT" && bash ./install.sh --no-brain --no-plasmoid --no-claude-code --no-reload-shell "$@" ) > "$SANDBOX/out.txt" 2>&1; }

LIB="$HOME/.local/lib/cortex/term-broker"
BIN="$HOME/.local/bin/cortex-term-broker"
MIG="$HOME/.local/bin/migrar-term-broker.sh"
UNIT="$HOME/.config/systemd/user/cortex-term-broker.service"
ENVF="$HOME/.config/cortex/term-broker.env"

echo "— D) install.sh --help anuncia la bandera y no instala nada —"
( cd "$ROOT" && bash ./install.sh --help ) > "$SANDBOX/help.txt" 2>&1; help_rc=$?
ck "--help sale 0"                  test "$help_rc" -eq 0
ck "--help menciona --con-term-broker" grep -q -- "--con-term-broker" "$SANDBOX/help.txt"
ck "--help dice que es opt-in Linux" grep -qi "Linux only" "$SANDBOX/help.txt"
ck "--help no creó nada"            test ! -e "$HOME/.local/bin"

echo
echo "— A) SIN la bandera: cero rastro del broker (camino por defecto) —"
run_install; rc_a=$?
ck "install sin bandera sale 0"     test "$rc_a" -eq 0
ck "instaló lo de siempre (cortex-fetch)" test -x "$HOME/.local/bin/cortex-fetch"
ck "NO hay módulos del broker"      test ! -e "$LIB"
ck "NO hay lanzador"                test ! -e "$BIN"
ck "NO hay unidad del broker"       test ! -e "$UNIT"
ck "NO hay token"                   test ! -e "$ENVF"
ck "systemd NO recibió NADA del broker" not_in_file "cortex-term-broker" "$CALLS"
ck "la salida no habla del broker"  not_in_file "TERMINAL BROKER" "$SANDBOX/out.txt"

echo
echo "— B) CON --con-term-broker: instala todo, con token generado —"
run_install --con-term-broker; rc_b=$?
cp "$SANDBOX/out.txt" "$SANDBOX/out-b.txt"
ck "install con bandera sale 0"     test "$rc_b" -eq 0
for f in term-host-broker term-session term-pty-bridge ws pty-session; do
  ck "módulo $f.ts instalado"       test -f "$LIB/$f.ts"
done
ck "módulos idénticos a la fuente"  bash -c 'cd "'"$LIB"'" && sha256sum -c "'"$ROOT"'/src/term-broker/SHA256SUMS"'
# El instalador copiaba con `*.ts`, que arrastraba también los PROBES al runtime del usuario. Lo que
# se instala es lo que el servicio EJECUTA, ni un archivo más.
ck "los probes NO se copiaron al runtime" test ! -e "$LIB/probe-pty-ws.ts"
ck "en el lib SOLO están los 5 módulos"   bash -c '[[ "$(ls -1 "'"$LIB"'" | wc -l)" == "5" ]]'
ck "lanzador instalado y ejecutable" test -x "$BIN"
ck "migrador instalado y ejecutable" test -x "$MIG"
ck "unidad instalada"               test -f "$UNIT"
ck "unidad usa %h para ExecStart"   grep -q "ExecStart=%h/.local/bin/cortex-term-broker" "$UNIT"
ck "unidad sin rutas absolutas de \$HOME" not_in_file "/home/" "$UNIT"
ck "token generado"                 test -f "$ENVF"
ck "token con modo 0600"            test "$(stat -c '%a' "$ENVF")" = "600"
TOK1="$(grep '^AXON_TERM_BROKER_TOKEN=' "$ENVF" | cut -d= -f2-)"
ck "token de 64 hex (32 bytes)"     is_hex64 "$TOK1"
ck "systemd recibió daemon-reload"  grep -q "daemon-reload" "$CALLS"
ck "systemd recibió enable --now del broker" grep -q "enable --now cortex-term-broker.service" "$CALLS"
# La unidad legacy solo se CONSULTA (is-active) para no chocar en el puerto; jamás se muta.
ck "a la unidad legacy solo se le hizo is-active" test "$(grep -c 'axon-term-broker' "$CALLS")" = "$(grep -c 'is-active --quiet axon-term-broker' "$CALLS")"
ck "ningún disable/stop/start sobre la legacy" not_in_file_re "(disable|stop|start|restart|enable)[^\n]*axon-term-broker" "$CALLS"
ck "el token NO se imprimió en la salida" not_in_file "$TOK1" "$SANDBOX/out-b.txt"

echo
echo "— C) idempotencia: segunda corrida NO regenera el token —"
run_install --con-term-broker >/dev/null 2>&1
TOK2="$(grep '^AXON_TERM_BROKER_TOKEN=' "$ENVF" | cut -d= -f2-)"
ck "token intacto tras reinstalar"  test "$TOK1" = "$TOK2"

echo
echo "— F) endpoint OCUPADO: ni habilita ni arranca (el hallazgo C-1) —"
# Se levanta un listener de mentiras en un puerto propio y se apunta ahí el instalador. No se usa el
# 8799 real ni se toca ningún servicio: lo que se prueba es la DECISIÓN del instalador, no el broker.
BUSY_PORT=18811
python3 - "$BUSY_PORT" <<'PY' &
import socket, sys, time
s = socket.socket(); s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
s.bind(("127.0.0.1", int(sys.argv[1]))); s.listen(1)
time.sleep(30)
PY
BUSY_PID=$!
for _ in $(seq 1 40); do ss -ltnH "sport = :$BUSY_PORT" 2>/dev/null | grep -q . && break; sleep 0.1; done
: > "$CALLS"
( export AXON_TERM_BROKER_PORT="$BUSY_PORT"; run_install --con-term-broker ); rc_f=$?
kill "$BUSY_PID" 2>/dev/null; wait "$BUSY_PID" 2>/dev/null
ck "el install sale 0 igual (instala, solo no arranca)" test "$rc_f" -eq 0
ck "avisa que el endpoint está ocupado"  grep -q "endpoint del broker YA está ocupado" "$SANDBOX/out.txt"
ck "NO hizo enable --now del broker"     not_in_file "enable --now cortex-term-broker" "$CALLS"
ck "NO hizo start del broker"            not_in_file_re "(^| )start[^\n]*cortex-term-broker" "$CALLS"
ck "manda al migrador, no a pegar comandos" grep -q "migrar-term-broker.sh" "$SANDBOX/out.txt"
# …y si una corrida previa (con el bug) dejó la unidad habilitada, la deshabilita: el stub de
# systemctl responde 0 a `is-enabled`, así que aquí SÍ se dispara esa rama.
ck "deshabilita la unidad que estaba habilitada" grep -q "disable cortex-term-broker.service" "$CALLS"
ck "a la legacy no le hizo NADA"         not_in_file_re "(disable|stop|start|restart|enable)[^\n]*axon-term-broker" "$CALLS"

# ── F) REINSTALAR sobre una máquina YA MIGRADA no debe apagar nuestra propia unidad ──────────────
# El caso que se rompía: en una máquina ya migrada el endpoint está ocupado por cortex-term-broker
# .service, que es justo lo que queremos que esté ahí. El instalador lo leía como conflicto, entraba
# a la rama de "ocupado" y su `disable` apagaba NUESTRA unidad sana → al siguiente reboot el usuario
# se quedaba sin broker, con axon degradando al shell del contenedor sin decir por qué.
echo
echo "— F) reinstalar sobre una máquina YA MIGRADA (el ocupante somos nosotros) —"
# Stub distinto: aquí `is-active` de NUESTRA unidad responde 0 (está corriendo), que es lo que
# `era_actualizacion` consulta. La legacy sigue respondiendo !=0.
cat > "$STUBS/systemctl" <<EOF
#!/usr/bin/env bash
echo "\$*" >> "$CALLS"
case " \$* " in
  *" is-active "*" cortex-term-broker.service "*) exit 0 ;;
  *" is-active "*) exit 3 ;;
esac
exit 0
EOF
chmod +x "$STUBS/systemctl"
# El escenario COMPLETO: además de la unidad activa, el endpoint tiene que estar OCUPADO — si no, el
# instalador toma la rama "libre" y el bug ni se asoma (una prueba que pasa con el bug presente no
# prueba nada). Se ocupa un puerto propio del sandbox, como en D).
MIGR_PORT=18812
python3 - "$MIGR_PORT" <<'PY2' &
import socket, sys, time
s = socket.socket(); s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
s.bind(("127.0.0.1", int(sys.argv[1]))); s.listen(1)
time.sleep(30)
PY2
MIGR_PID=$!
for _ in $(seq 1 40); do ss -ltnH "sport = :$MIGR_PORT" 2>/dev/null | grep -q . && break; sleep 0.1; done
: > "$CALLS"
( export AXON_TERM_BROKER_PORT="$MIGR_PORT"; run_install --con-term-broker ); rc_g=$?
kill "$MIGR_PID" 2>/dev/null; wait "$MIGR_PID" 2>/dev/null
ck "el install sale 0 en una reinstalación"     test "$rc_g" -eq 0
ck "NO trata a nuestra propia unidad como conflicto" not_in_file "endpoint del broker YA está ocupado" "$SANDBOX/out.txt"
ck "NO deshabilita la unidad que está sirviendo"     not_in_file_re "(^| )disable[^\n]*cortex-term-broker" "$CALLS"
ck "avisa que hay que reiniciar para cargar el código nuevo" grep -q "ya estaba CORRIENDO" "$SANDBOX/out.txt"
# El instructivo del token tiene que nombrar la variable que lee el CLIENTE. Decía
# AXON_TERM_BROKER_SOCKET, que solo la lee el SERVIDOR: quien lo seguía al pie de la letra montaba
# bien el socket, ponía bien el token, y axon degradaba al contenedor EN SILENCIO.
ck "el instructivo del cliente usa AXON_TERM_BROKER_URL con esquema unix:" grep -qE "AXON_TERM_BROKER_URL=unix:" "$SANDBOX/out.txt"
ck "el instructivo NO le pide al cliente AXON_TERM_BROKER_SOCKET" not_in_file "      AXON_TERM_BROKER_SOCKET=" "$SANDBOX/out.txt"
# Se restaura el stub original para que E) (uninstall) corra como antes.
cat > "$STUBS/systemctl" <<EOF
#!/usr/bin/env bash
echo "\$*" >> "$CALLS"
case " \$* " in *" is-active "*) exit 3 ;; esac
exit 0
EOF
chmod +x "$STUBS/systemctl"

echo
echo "— E) uninstall retira el broker —"
( cd "$ROOT" && bash ./uninstall.sh --no-brain --keep-cfg >/dev/null 2>&1 )
ck "módulos retirados"              test ! -e "$LIB"
ck "lanzador retirado"              test ! -e "$BIN"
ck "migrador retirado"              test ! -e "$MIG"
ck "unidad retirada"                test ! -e "$UNIT"
ck "systemd recibió disable del broker" grep -q "disable --now cortex-term-broker.service" "$CALLS"
ck "--keep-cfg conserva el token"   test -f "$ENVF"
( cd "$ROOT" && bash ./uninstall.sh --no-brain >/dev/null 2>&1 )
ck "sin --keep-cfg el token se borra" test ! -e "$ENVF"

echo
echo "— H) los 5 módulos vendorizados TYPECHECAN (tsc --noEmit) —"
# El chequeo (1) de PROCEDENCIA.md (sha256sum contra SHA256SUMS, arriba en B/G) protege de un edit NO
# declarado: alguien "arregla" un módulo aquí y la copia deja de ser copia sin que nada se queje. NO
# protege de un edit DECLARADO que no compila — que es justo lo que pasó: el parche de topes usó
# `opts.maxSessions` en term-session.ts sin declararlo en `ShellSessionPoolOptions`, y como esta
# carpeta corre con `node --experimental-strip-types` (nunca pasa por tsc), vivió así hasta que el
# mismo código se typechequeó del lado de axon.
#
# cortex no trae TypeScript propio a propósito (cero deps de npm es parte del diseño de esta carpeta,
# ver PROCEDENCIA.md § "Por qué COPIA…" punto 4) y este chequeo no le agrega una: instalar `typescript`
# solo para esto metería una dependencia pesada a un instalador que hoy corre con `curl | bash` en una
# máquina limpia, sin red garantizada. En vez de eso se aprovecha, SI YA ESTÁ, el `tsc` que trae el
# propio axon (el repo de origen de estos módulos — casi siempre clonado como hermano de cortex en la
# máquina de quien desarrolla), con las MISMAS compilerOptions de su tsconfig.json (no se puede pasar
# `--project` junto con una lista de archivos: TypeScript lo rechaza con TS5042, así que se replican
# los flags a mano; si axon cambia su tsconfig, este bloque se re-sincroniza igual que se re-sincroniza
# el commit vendorizado). Si no hay un tsc+@types/node verificable a mano (máquina limpia, sin axon
# clonado al lado, o axon sin `npm install` corrido), el chequeo se SALTA con un aviso EXPLÍCITO —
# fallar en falso en la máquina de un colega es peor que no tener el chequeo.
# Dónde buscar axon. Una sola ruta hermana NO alcanza: en un WORKTREE (`cortex/.git-worktrees/x`) o en
# el checkout de CI (`_work/cortex/cortex`), el hermano de $ROOT no es `~/code`, así que el chequeo se
# saltaba EN SILENCIO justo en los dos sitios donde más importa. Se prueban varios candidatos, y `AXON_DIR`
# permite fijarlo a mano donde el layout sea otro.
AXON_SIBLING=""
for cand in "${AXON_DIR:-}" "$(dirname "$ROOT")/axon" "$HOME/code/axon" \
            "$(git -C "$ROOT" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)/../../axon"; do
  [[ -n "$cand" && -x "$cand/node_modules/.bin/tsc" ]] && { AXON_SIBLING="$cand"; break; }
done
[[ -z "$AXON_SIBLING" ]] && AXON_SIBLING="$(dirname "$ROOT")/axon"   # para que el aviso diga dónde buscó
AXON_TSC="$AXON_SIBLING/node_modules/.bin/tsc"
AXON_TYPES="$AXON_SIBLING/node_modules/@types/node"
if [[ -x "$AXON_TSC" && -d "$AXON_TYPES" ]]; then
  VEND_TS=(term-host-broker term-session term-pty-bridge ws pty-session)
  VEND_PATHS=()
  for f in "${VEND_TS[@]}"; do VEND_PATHS+=("$ROOT/src/term-broker/$f.ts"); done
  "$AXON_TSC" --noEmit --target ES2022 --module ES2022 --moduleResolution bundler --lib ES2023 \
    --strict --esModuleInterop --skipLibCheck --forceConsistentCasingInFileNames \
    --allowImportingTsExtensions --resolveJsonModule \
    --typeRoots "$AXON_SIBLING/node_modules/@types" --types node \
    "${VEND_PATHS[@]}" > "$SANDBOX/tsc-out.txt" 2>&1
  rc_tsc=$?
  ck "tsc --noEmit sale limpio sobre los 5 módulos" test "$rc_tsc" -eq 0
  [[ "$rc_tsc" -ne 0 ]] && sed 's/^/      /' "$SANDBOX/tsc-out.txt"
else
  # El salto CUENTA. Antes solo hacía `echo`, así que `pass`/`fail` salían idénticos con y sin chequeo y
  # el exit seguía 0: un probe que se salta su bloque más caro sin dejar rastro en el marcador miente por
  # omisión. Ahora suma un ⚠️ propio, visible en el resumen.
  omitidos=$((omitidos + 1))
  echo "  ⚠️  SALTADO: no encontré un tsc utilizable (busqué en $AXON_TSC y sus alternativas; no se instala"
  echo "      nada para este chequeo). Fija AXON_DIR=/ruta/a/axon para forzarlo."
fi

echo
echo "— I) PARIDAD: la copia vendorizada ES el commit que PROCEDENCIA.md dice —"
# El chequeo (1) —sha256sum contra SHA256SUMS— compara la copia CONSIGO MISMA: detecta que alguien la
# editó después de sellarla, pero un `SHA256SUMS` regenerado en la misma tanda la vuelve a firmar en verde.
# Es justo lo que pasó (C-1 de la tupla): se re-vendorizó 17 minutos ANTES de commitear un fix en axon, y
# los hashes firmaron en verde una copia que ya iba atrás. La única forma de ver ESO es comparar contra
# AFUERA — el commit de axon anotado en PROCEDENCIA.md —, que hasta hoy solo existía como receta a mano
# ("(2) ¿axon cambió desde el commit anotado?"). Una receta que nadie corre no es un candado (F-10).
#
# Se lee el commit del propio PROCEDENCIA.md para que no haya un segundo lugar donde el sha pueda driftear.
# Si no hay clon de axon, o ese clon no tiene el commit (fetch superficial, clon recién hecho), se SALTA
# contando el ⚠️ — igual que el bloque H: fallar en falso en la máquina de un colega es peor que no medir.
VEND_SHA="$(grep -m1 -oP '\*\*Commit de origen:\*\*\s*`\K[0-9a-f]{7,40}' "$ROOT/src/term-broker/PROCEDENCIA.md" 2>/dev/null || true)"
if [[ -z "$VEND_SHA" ]]; then
  omitidos=$((omitidos + 1))
  echo "  ⚠️  SALTADO: no pude leer el '**Commit de origen:**' de PROCEDENCIA.md."
elif [[ ! -d "$AXON_SIBLING/.git" ]] || ! git -C "$AXON_SIBLING" cat-file -e "${VEND_SHA}^{commit}" 2>/dev/null; then
  omitidos=$((omitidos + 1))
  echo "  ⚠️  SALTADO: no encontré el commit ${VEND_SHA} en un clon de axon (busqué en $AXON_SIBLING)."
  echo "      Fija AXON_DIR=/ruta/a/axon, o corre 'git fetch' ahí, para que este chequeo pueda medir."
else
  drift_par=0
  for f in term-host-broker term-session term-pty-bridge ws pty-session; do
    # OJO a las LLAVES: `${VEND_SHA}:`, no `$VEND_SHA:` — en zsh la segunda forma se lee como el
    # modificador de historia `:s` y el `show` falla en los cinco, reportando DRIFT sobre una copia sana.
    if ! git -C "$AXON_SIBLING" show "${VEND_SHA}:src/server/${f}.ts" 2>/dev/null \
         | diff -q - "$ROOT/src/term-broker/${f}.ts" >/dev/null 2>&1; then
      drift_par=$((drift_par + 1))
      echo "      ↳ $f.ts DIFIERE de ${VEND_SHA}:src/server/$f.ts"
    fi
  done
  ck "los 5 módulos son BYTE A BYTE el commit ${VEND_SHA} de axon" test "$drift_par" -eq 0
  # Y, informativo: cuánto se ha movido axon desde el pin. No es un fallo —vendorizar es un acto
  # deliberado, no una sincronización automática—, pero saberlo es lo que dispara la próxima pasada.
  if git -C "$AXON_SIBLING" cat-file -e "origin/develop^{commit}" 2>/dev/null; then
    movidos="$(git -C "$AXON_SIBLING" diff --name-only "${VEND_SHA}" origin/develop -- \
                 src/server/term-host-broker.ts src/server/term-session.ts src/server/term-pty-bridge.ts \
                 src/server/ws.ts src/server/pty-session.ts 2>/dev/null | wc -l | tr -d " ")"
    [[ "${movidos:-0}" -gt 0 ]] \
      && echo "  ℹ️  axon ha movido $movidos de los 5 módulos desde ${VEND_SHA} — toca re-vendorizar cuando cierres." \
      || echo "  ℹ️  origin/develop de axon no ha tocado ninguno de los 5 desde ${VEND_SHA}."
  fi
fi

echo
if [[ "${omitidos:-0}" -gt 0 ]]; then
  echo "  ${pass} ✅   ${fail} ❌   ${omitidos} ⚠️ omitido(s)"
else
  echo "  ${pass} ✅   ${fail} ❌"
fi
[[ "$fail" -eq 0 ]] || exit 1
