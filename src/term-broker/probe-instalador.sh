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
run_install() { ( cd "$ROOT" && bash ./install.sh --no-brain --no-plasmoid --no-claude-code --no-reload-shell "$@" ) > "$SANDBOX/out.txt" 2>&1; }

LIB="$HOME/.local/lib/cortex/term-broker"
BIN="$HOME/.local/bin/cortex-term-broker"
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
ck "módulos idénticos a la fuente"  diff -r "$ROOT/src/term-broker" "$LIB" --exclude="*.md" --exclude="*.sh"
ck "lanzador instalado y ejecutable" test -x "$BIN"
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
echo "— E) uninstall retira el broker —"
( cd "$ROOT" && bash ./uninstall.sh --no-brain --keep-cfg >/dev/null 2>&1 )
ck "módulos retirados"              test ! -e "$LIB"
ck "lanzador retirado"              test ! -e "$BIN"
ck "unidad retirada"                test ! -e "$UNIT"
ck "systemd recibió disable del broker" grep -q "disable --now cortex-term-broker.service" "$CALLS"
ck "--keep-cfg conserva el token"   test -f "$ENVF"
( cd "$ROOT" && bash ./uninstall.sh --no-brain >/dev/null 2>&1 )
ck "sin --keep-cfg el token se borra" test ! -e "$ENVF"

echo
echo "  ${pass} ✅   ${fail} ❌"
[[ "$fail" -eq 0 ]] || exit 1
