#!/usr/bin/env bash
# Install the Claude Code quota widget for the current user.
#
#   ./install.sh              # full install (brain + fetch script + systemd + plasmoid)
#   ./install.sh --reinstall  # uninstall plasmoid first, then reinstall
#   ./install.sh --no-plasmoid # only the brain + fetch script + systemd timer (no GUI)
#   ./install.sh --no-gui      # alias of --no-plasmoid (skip the desktop widget)
#   ./install.sh --no-brain    # skip the Claude-Code brain (hooks/norms); only daemon + GUI
#   ./install.sh --no-claude-code # skip auto-installing the Claude Code CLI (the widget measures IT)
#   ./install.sh --no-reload-shell # don't restart plasmashell at the end (default: restart to load changes)
#   ./install.sh --con-term-broker # OPT-IN, Linux only. Installs the TERMINAL BROKER: a service that
#                                  # serves a shell of THIS machine over a unix socket (for a
#                                  # containerized client) and on 127.0.0.1:8799, authenticated with a
#                                  # token the installer GENERATES. OFF by default; nothing of it is
#                                  # installed without this flag. Read docs/term-broker.md first.
#   ./install.sh --help            # print this usage and exit
#
# This is the MASTER installer for cortex: it lays down the shared Claude-Code brain
# (global hooks, delegation-cost governance, skill, norms) AND the quota daemon + optional GUI.
# Idempotent.

set -euo pipefail

# --help sale ANTES de tocar nada (imprime el bloque de comentarios de arriba).
usage() { sed -n '2,/^$/p' "$0" | sed 's/^#\( \|$\)//'; }

ROOT="$(cd "$(dirname "$0")" && pwd)"
BIN_SRC="$ROOT/src/bin/cortex-fetch"
UNIT_SRC="$ROOT/src/systemd"
PLASMOID_SRC="$ROOT/src/plasmoid"
PLASMOID_ID="io.github.unjordi.cortex"
OLD_PLASMOID_ID="io.github.unjordi.claude-quota-widget"   # legacy: se elimina en el install (borra el previo)
OLD_PLASMOID_ID_BRAIN="io.github.unjordi.claude-brain"    # era intermedia (rename claude-brain→cortex, #312)
BRAIN_INSTALLER="$ROOT/brain/install-brain.sh"

BIN_DEST="$HOME/.local/bin/cortex-fetch"
UNIT_DEST="$HOME/.config/systemd/user"
# Config del widget: con el rebrand COMPLETO (2026-07) pasó a ~/.config/cortex (el código lee
# de ahí). "Borra el previo por completo": NO se migra la config vieja; se instala limpia (defaults).
LIMITS_DEFAULT="$HOME/.config/cortex/limits.env"

# ── Broker de terminal (OPT-IN, ver docs/term-broker.md) ───────────────────────────────────────
# Los .ts vendorizados van a ~/.local/lib/cortex/term-broker/ (no al PATH: no son ejecutables), y el
# lanzador `cortex-term-broker` sí a ~/.local/bin (misma convención que cortex-fetch).
TERM_BROKER_SRC="$ROOT/src/term-broker"
TERM_BROKER_LIB="$HOME/.local/lib/cortex/term-broker"
TERM_BROKER_BIN="$HOME/.local/bin/cortex-term-broker"
TERM_BROKER_ENV="$HOME/.config/cortex/term-broker.env"
TERM_BROKER_UNIT="cortex-term-broker.service"
TERM_BROKER_MIGRATE="$ROOT/bin/migrar-term-broker.sh"
# Los 5 módulos VENDORIZADOS, por nombre y no por glob: `*.ts` arrastraba también los probes
# (`probe-pty-ws.ts`) al runtime del usuario. Lo instalado es lo que el servicio EJECUTA, nada más.
TERM_BROKER_MODULES=(term-host-broker.ts term-session.ts term-pty-bridge.ts ws.ts pty-session.ts)
# Puerto del listener TCP y ruta del socket unix — se usan para la salvaguarda "¿ya hay algo aquí?".
# Se leen del entorno para que un probe pueda apuntarlos a otro lado sin tocar el 8799 real.
TERM_BROKER_PORT="${AXON_TERM_BROKER_PORT:-8799}"
# Espeja EXACTAMENTE `defaultBrokerSocketPath()` de term-host-broker.ts: $XDG_RUNTIME_DIR/axon/… si
# existe, si no ~/.axon/…. Si las dos definiciones se separaran, el instalador vigilaría un socket
# distinto del que el broker abre — la salvaguarda miraría al lado equivocado.
if [[ -n "${XDG_RUNTIME_DIR:-}" ]]; then
  TERM_BROKER_SOCKET="${AXON_TERM_BROKER_SOCKET:-$XDG_RUNTIME_DIR/axon/term-broker.sock}"
else
  TERM_BROKER_SOCKET="${AXON_TERM_BROKER_SOCKET:-$HOME/.axon/term-broker.sock}"
fi
# La unidad LEGACY que instaló a mano una sesión de axon, apuntando al clon ~/code/axon-run. Se
# CONSULTA (para nombrarla en el aviso) pero NUNCA se toca: apagarla es parte de la migración en
# vivo, y eso lo hace `bin/migrar-term-broker.sh`. Ver docs/term-broker.md § migración.
TERM_BROKER_LEGACY_UNIT="axon-term-broker.service"

# ── PASO 0 del broker: la puerta de OS y prerrequisitos ────────────────────────────────────────
# Corre PEGADA al parseo de argumentos, ANTES de instalar nada del resto de cortex. Antes vivía
# dentro de install_term_broker(), que se invoca al FINAL: en un Linux sin `node` el instalador ya
# había puesto el cerebro, el daemon, el timer y el widget, y RECIÉN ENTONCES abortaba con error —
# dejando la máquina a medias por una bandera que se podía descartar en el primer segundo.
# Solo VALIDA: no escribe nada.
precheck_term_broker() {
  # (1) Puerta por OS. El broker usa `script`(util-linux) para el PTY, el login shell del usuario y
  #     systemd --user: es Linux. Falla RUIDOSO en vez de saltarse en silencio — el usuario pidió
  #     esto explícitamente con una bandera, merece saber por qué no pasó.
  if [[ "$(uname -s)" != "Linux" ]]; then
    echo "--con-term-broker es solo para Linux (usa 'script' de util-linux, el login shell y systemd --user)." >&2
    echo "En macOS/Windows: instala sin la bandera; el resto de cortex funciona igual." >&2
    # Aquí SÍ aborta (este instalador ya es el de Linux: si el OS no calza, nada de lo del broker
    # aplica). En macos/install.sh la MISMA bandera solo AVISA y sigue: allá llega por el
    # pass-through del bootstrap y tumbar la instalación entera por una bandera inaplicable
    # sería peor que ignorarla con una explicación.
    exit 2
  fi

  # (2) Prerrequisitos.
  local missing=0
  command -v node   >/dev/null 2>&1 || { echo "missing: node (>=22, por --experimental-strip-types)" >&2; missing=1; }
  command -v script >/dev/null 2>&1 || { echo "missing: script (paquete util-linux) — el PTY lo necesita" >&2; missing=1; }
  command -v systemctl >/dev/null 2>&1 || { echo "missing: systemctl (systemd --user) — el broker es un servicio de usuario" >&2; missing=1; }
  local m
  for m in "${TERM_BROKER_MODULES[@]}"; do
    [[ -f "$TERM_BROKER_SRC/$m" ]] || { echo "missing: $TERM_BROKER_SRC/$m" >&2; missing=1; }
  done
  [[ -f "$TERM_BROKER_MIGRATE" ]] || { echo "missing: $TERM_BROKER_MIGRATE" >&2; missing=1; }
  if [[ "$missing" -ne 0 ]]; then
    echo "--con-term-broker: instala lo que falta y vuelve a correr. NO se instaló NADA." >&2
    exit 1
  fi
}

REINSTALL=0
SKIP_PLASMOID=0
SKIP_CCUSAGE=0
SKIP_BRAIN=0
SKIP_CLAUDE_CODE=0
RELOAD_SHELL=1
WITH_TERM_BROKER=0
for arg in "$@"; do
  case "$arg" in
    --reinstall)       REINSTALL=1 ;;
    --no-plasmoid)     SKIP_PLASMOID=1 ;;
    --no-gui)          SKIP_PLASMOID=1 ;;
    --no-brain)        SKIP_BRAIN=1 ;;
    --no-ccusage)      SKIP_CCUSAGE=1 ;;
    --no-claude-code)  SKIP_CLAUDE_CODE=1 ;;
    --no-reload-shell) RELOAD_SHELL=0 ;;
    --con-term-broker) WITH_TERM_BROKER=1 ;;
    -h|--help)         usage; exit 0 ;;
    *) echo "unknown arg: $arg" >&2; echo "try: $0 --help" >&2; exit 2 ;;
  esac
done

# La puerta del broker, en el PASO 0 REAL: pegada al parseo, antes de escribir un solo archivo.
# Con `if`, no con `[[ … ]] && …`: bajo `set -e` un `&&` que resulta falso en el nivel superior
# TERMINA el script (el estado de la lista es 1). Bug clásico, y aquí sería el camino por DEFAULT.
if [[ "$WITH_TERM_BROKER" -eq 1 ]]; then precheck_term_broker; fi

# Asegura que ~/.local/bin (donde viven el fetch y, típicamente, el CLI `claude`) esté en el PATH,
# en zsh Y bash. Idempotente por marcador; crea el rc si falta. Se aplica también a ESTE proceso.
ensure_path_local_bin() {
  local marker="# cortex: ~/.local/bin en el PATH (claude, cortex-fetch)"
  # rebrand cleanup: marcadores de eras VIEJAS cuyo bloque PATH (marcador + su línea 'case' siguiente)
  # hay que barrer para no dejar un bloque PATH duplicado (inofensivo) al actualizar. OJO: el rename
  # claude-brain→cortex (#312) renombró MECÁNICAMENTE el string del old_marker a
  # '# cortex: …claude-quota-fetch', que NUNCA se escribió en ningún rc → el bloque real de la era
  # 'claude-brain' quedaba SIN barrer. Estos son los strings que las eras previas SÍ escribieron.
  local old_markers=(
    "# claude-brain: ~/.local/bin en el PATH (claude, claude-brain-fetch)"  # era claude-brain
    "# claude-brain: ~/.local/bin en el PATH (claude, claude-quota-fetch)"  # era claude-quota (la barría #220)
  )
  local block om
  printf -v block '\n%s\ncase ":$PATH:" in *":$HOME/.local/bin:"*) ;; *) export PATH="$HOME/.local/bin:$PATH" ;; esac\n' "$marker"
  local f
  for f in "$HOME/.zshrc" "$HOME/.bashrc" "$HOME/.bash_profile"; do
    for om in "${old_markers[@]}"; do
      if [[ -e "$f" ]] && grep -qF "$om" "$f" 2>/dev/null; then
        awk -v m="$om" 'skip { skip=0; next } index($0,m) { skip=1; next } { print }' "$f" > "$f.cbtmp" && mv "$f.cbtmp" "$f"
      fi
    done
    if [[ -e "$f" ]] && grep -qF "$marker" "$f" 2>/dev/null; then continue; fi
    printf '%s' "$block" >> "$f"
  done
  case ":$PATH:" in *":$HOME/.local/bin:"*) ;; *) export PATH="$HOME/.local/bin:$PATH" ;; esac
}

# ── Broker de terminal: instalación OPT-IN ──────────────────────────────────────────────────────
# SOLO se llama si el usuario pasó --con-term-broker. Sin la bandera, ni una línea de esta función
# corre y no queda NADA del broker en la máquina (probado por src/term-broker/probe-instalador.sh).
#
# Genera un token de 32 bytes hex. Preferimos openssl; si no está, /dev/urandom por `od` (coreutils,
# siempre presente). Sin fallback a $RANDOM: un token adivinable aquí es ejecución de comandos.
gen_token() {
  if command -v openssl >/dev/null 2>&1; then
    openssl rand -hex 32
  elif [[ -r /dev/urandom ]]; then
    od -An -tx1 -N32 /dev/urandom | tr -d ' \n'
  else
    echo "cortex: no hay fuente de aleatoriedad (ni openssl ni /dev/urandom) para el token" >&2
    return 1
  fi
}

# ¿Hay YA algo escuchando donde este broker quiere escuchar? Se pregunta por el RECURSO (el puerto
# y el socket), no por el nombre de una unidad conocida: la salvaguarda anterior solo miraba
# `is-active axon-term-broker.service`, así que no veía un broker corrido A MANO, ni otro proceso
# cualquiera en el 8799, ni una unidad en `activating`. Es la misma técnica que ya usaba
# `src/term-broker/probe-broker-vivo.sh` para no hablarle a un broker ajeno — traída al instalador.
# Imprime una descripción de QUIÉN ocupa (stdout) y devuelve 0 si está ocupado.
term_broker_endpoint_ocupado() {
  local quien=""
  local l=""
  if command -v ss >/dev/null 2>&1; then
    # -p da el proceso cuando es nuestro; si no hay permiso, igual sirve la línea de LISTEN.
    l="$(ss -ltnpH "sport = :$TERM_BROKER_PORT" 2>/dev/null | head -1 | tr -s ' ')"
    if [[ -n "$l" ]]; then quien="TCP :$TERM_BROKER_PORT ocupado -> $l"; fi
    # Un socket unix EN ESCUCHA aparece en `ss -lx`. La sola PRESENCIA del archivo no prueba nada:
    # un socket unix no se borra cuando muere su proceso (por eso el propio broker sondea antes).
    if ss -lxH 2>/dev/null | grep -qF -- "$TERM_BROKER_SOCKET"; then
      quien="${quien:+$quien; }socket $TERM_BROKER_SOCKET EN ESCUCHA"
    elif [[ -S "$TERM_BROKER_SOCKET" ]]; then
      echo "    (nota: $TERM_BROKER_SOCKET existe pero nadie escucha — huérfano de un crash; el broker lo limpia al arrancar)" >&2
    fi
  elif [[ -S "$TERM_BROKER_SOCKET" ]]; then
    # Sin `ss` no se puede distinguir vivo de huérfano: conservador, se cuenta como ocupado.
    quien="socket $TERM_BROKER_SOCKET existe (sin 'ss' no puedo confirmar si está vivo)"
  fi
  if [[ -z "$quien" ]]; then return 1; fi
  echo "$quien"
}

install_term_broker() {
  echo "==> Installing the TERMINAL BROKER (opt-in) — see docs/term-broker.md"
  # OS y prerrequisitos YA se validaron en precheck_term_broker(), pegado al parseo de argumentos:
  # si algo faltaba, este instalador no llegó hasta aquí ni escribió nada.

  # (1) ¿Hay un servicio NUESTRO corriendo? Entonces esto es una ACTUALIZACIÓN, y copiar el código
  #     nuevo NO lo aplica: el proceso vivo se queda con los .ts que ya cargó. Se avisa al final
  #     (no se reinicia por nuestra cuenta: un restart MATA las sesiones abiertas del usuario).
  local era_actualizacion=0
  if systemctl --user is-active --quiet "$TERM_BROKER_UNIT" 2>/dev/null; then era_actualizacion=1; fi

  # (2) Módulos vendorizados (0644: son librería, no ejecutables) + lanzador (0755, al PATH).
  #     Por NOMBRE, no por glob: `*.ts` metía también los probes en el runtime del usuario.
  echo "    módulos -> $TERM_BROKER_LIB"
  install -d "$TERM_BROKER_LIB"
  local m
  for m in "${TERM_BROKER_MODULES[@]}"; do
    install -D -m 0644 "$TERM_BROKER_SRC/$m" "$TERM_BROKER_LIB/$m"
  done
  echo "    lanzador -> $TERM_BROKER_BIN"
  install -D -m 0755 "$ROOT/bin/cortex-term-broker" "$TERM_BROKER_BIN"
  echo "    migrador -> $HOME/.local/bin/migrar-term-broker.sh"
  install -D -m 0755 "$TERM_BROKER_MIGRATE" "$HOME/.local/bin/migrar-term-broker.sh"

  # (3) Token per-máquina, GENERADO aquí. Idempotente: si el archivo ya existe NO se toca (regenerarlo
  #     rompería al cliente que ya lo tiene). Nunca hay un token por defecto ni horneado en el repo.
  local token_is_new=0
  if [[ ! -f "$TERM_BROKER_ENV" ]]; then
    echo "    generando token per-máquina -> $TERM_BROKER_ENV (0600)"
    install -d -m 0700 "$(dirname "$TERM_BROKER_ENV")"
    # umask ANTES de crear: que el archivo no exista ni un instante con el token adentro y 0644.
    ( umask 077
      cat > "$TERM_BROKER_ENV" <<EOF
# cortex — broker de terminal. Generado por ./install.sh --con-term-broker el $(date -Iseconds).
# ⚠️ SECRETO: quien tenga este token puede ejecutar CUALQUIER comando como tu usuario en esta
# máquina (el broker no es una sandbox). Modo 0600, y NO lo copies a un repo.
#
# El prefijo AXON_ es intencional: es el contrato con el cliente (axon-en-contenedor) y además es
# como buildSessionEnv() lo BARRE del entorno de cada shell. Ver src/term-broker/PROCEDENCIA.md.
AXON_TERM_BROKER_TOKEN=$(gen_token)
# AXON_TERM_BROKER_SOCKET=$TERM_BROKER_SOCKET
#   Transporte del cliente CONTENERIZADO (un contenedor NO alcanza un bind a loopback del host).
#   Su DIRECTORIO lo crea systemd (RuntimeDirectory=axon) y es el que monta el contenedor.
#   \`off\` lo desactiva: entonces solo queda el TCP y un cliente en contenedor NO llegará.
# AXON_TERM_BROKER_PORT=$TERM_BROKER_PORT   # listener TCP, para clientes NATIVOS del host
# AXON_TERM_BROKER_BIND=127.0.0.1           # ⚠️ cualquier cosa que no sea loopback expone RCE a la red
# AXON_TERM_BROKER_HOME=$HOME               # cwd inicial de las sesiones
#
# TOPES (ver docs/term-broker.md § Topes). Todos traen default; descoméntalos solo para cambiarlos.
# AXON_TERM_BROKER_MAX_SESSIONS=32          # sesiones de shell (/run) concurrentes; al pasarlo, SESSION_LIMIT
# AXON_TERM_BROKER_MAX_PTYS=32              # PTYs (/pty) concurrentes; al pasarlo, el upgrade recibe 503
# AXON_TERM_BROKER_WS_HIGH_WATER=1048576    # 1 MiB: buffer pendiente al que se PAUSA al productor
# AXON_TERM_BROKER_WS_MAX_BUFFER=8388608    # 8 MiB: válvula dura, cierra ESA conexión (nunca el broker)
EOF
    )
    chmod 600 "$TERM_BROKER_ENV"
    token_is_new=1
  else
    echo "    token ya existe -> $TERM_BROKER_ENV (no se regenera)"
  fi

  # (4) La unidad.
  echo "    unidad -> $UNIT_DEST/$TERM_BROKER_UNIT"
  install -D -m 0644 "$UNIT_SRC/$TERM_BROKER_UNIT" "$UNIT_DEST/$TERM_BROKER_UNIT"
  systemctl --user daemon-reload

  # (5) Arranque — o NO. La regla es una sola y vale para cualquier ocupante, no solo para la unidad
  #     legacy conocida: si el puerto o el socket ya están tomados, este instalador NO arranca NI
  #     HABILITA la unidad, y manda a la migración.
  #
  #     El `enable` es la parte que importa: habilitar mientras la otra sigue viva deja DOS unidades
  #     en default.target.wants sobre el MISMO endpoint y con tokens DISTINTOS. Hoy no se nota; en el
  #     siguiente reboot systemd arranca las dos, una gana el bind y la otra cicla — y si la que gana
  #     es la nuestra, el cliente que trae el token viejo recibe 401 y axon degrada AL SHELL DEL
  #     CONTENEDOR: el usuario ve su terminal "rara" sin una sola pista de por qué. Se descartó
  #     `Conflicts=` en la unidad (arbitraría matando las sesiones que el usuario tiene abiertas).
  #     OJO con el caso "el ocupante SOMOS NOSOTROS": en una máquina ya migrada, el endpoint está
  #     ocupado por $TERM_BROKER_UNIT, que es exactamente lo que queremos que esté ahí. Tratar eso
  #     como un conflicto y caer al bloque de abajo tenía una consecuencia seria: el `disable` de más
  #     abajo apagaba NUESTRA propia unidad, ya sana y habilitada, y en el siguiente reboot el usuario
  #     se quedaba SIN broker (axon degradando al shell del contenedor, sin una pista de por qué).
  #     El dato para distinguirlo ya estaba calculado en el paso (1): `era_actualizacion` es
  #     precisamente "$TERM_BROKER_UNIT está activa". Si lo está, el ocupante es ella y no hay
  #     conflicto que reportar — solo el aviso de reinicio del paso (7).
  local ocupante=""
  if [[ "$era_actualizacion" -eq 1 ]]; then
    # Somos nosotros. Ni se avisa de conflicto ni se toca el enable: la unidad se queda como está.
    # (El `enable --now` tampoco hace falta: ya está activa; y `enable` sería idempotente pero
    #  ruidoso.) El paso (7) le dirá que reinicie para cargar el código nuevo.
    :
  elif ocupante="$(term_broker_endpoint_ocupado)"; then
    echo ""
    echo "    ⚠️  El endpoint del broker YA está ocupado — NO arranqué ni habilité $TERM_BROKER_UNIT."
    echo "        ocupante: $ocupante"
    if systemctl --user is-active --quiet "$TERM_BROKER_LEGACY_UNIT" 2>/dev/null; then
      echo "        Es $TERM_BROKER_LEGACY_UNIT (la unidad que instaló a mano una sesión de axon)."
      echo "        Para cambiarte, con el orden correcto y verificación real:"
      echo "            ~/.local/bin/migrar-term-broker.sh"
      echo "        (apaga la vieja, arranca ésta, comprueba con el token de verdad y sabe revertir)"
    else
      echo "        No es la unidad legacy conocida: averigua qué es antes de seguir."
      echo "        Cuando el endpoint esté libre:  systemctl --user enable --now $TERM_BROKER_UNIT"
    fi
    # Si una corrida ANTERIOR (con el bug) dejó nuestra unidad habilitada, se deshace: es un enlace
    # inerte hoy y una bomba en el próximo reboot. Solo se toca lo NUESTRO; la legacy no se roza.
    if systemctl --user is-enabled --quiet "$TERM_BROKER_UNIT" 2>/dev/null; then
      echo "        (deshabilitando $TERM_BROKER_UNIT, que una instalación previa había habilitado:"
      echo "         dos unidades habilitadas sobre el mismo endpoint arrancarían juntas al reiniciar)"
      systemctl --user disable "$TERM_BROKER_UNIT" >/dev/null 2>&1 || true
    fi
  else
    systemctl --user enable --now "$TERM_BROKER_UNIT"
    echo "    servicio arriba: systemctl --user status $TERM_BROKER_UNIT"
  fi

  # (6) Cómo se COMPARTE el token con el cliente. El instalador no lo escribe en el .env de nadie
  #     (no sabe dónde vive el compose de quien clona); imprime la línea exacta a pegar.
  echo ""
  #     La variable que se imprime aquí es la que lee el CLIENTE: `AXON_TERM_BROKER_URL`.
  #     Antes decía `AXON_TERM_BROKER_SOCKET`, que solo la lee el SERVIDOR para decidir dónde abrir
  #     el socket — el cliente no la mira. Quien seguía el instructivo al pie de la letra montaba
  #     bien el socket, ponía bien el token, y axon degradaba al shell del CONTENEDOR en silencio,
  #     porque para él el broker simplemente no estaba configurado. Un socket se le pasa al cliente
  #     con el esquema `unix:` en la URL (ver docker/axon.yml del fork de Odysseus).
  echo "    El cliente axon EN CONTENEDOR necesita el socket montado + el token:"
  echo "      volumen:  $(dirname "$TERM_BROKER_SOCKET"):$(dirname "$TERM_BROKER_SOCKET")   # el DIRECTORIO, no el archivo"
  echo "      AXON_TERM_BROKER_URL=unix:$TERM_BROKER_SOCKET"
  echo "      AXON_TERM_BROKER_TOKEN=<el valor que está en $TERM_BROKER_ENV>"
  echo "    Un cliente NATIVO del host usa en cambio:"
  echo "      AXON_TERM_BROKER_URL=http://127.0.0.1:$TERM_BROKER_PORT"
  echo "    Para copiar el token SIN imprimirlo aquí:"
  echo "      grep '^AXON_TERM_BROKER_TOKEN=' $TERM_BROKER_ENV >> /ruta/al/.env/del/cliente"
  echo "    (sin AXON_TERM_BROKER_TOKEN, axon degrada solo al shell del contenedor — no falla)"
  if [[ "$token_is_new" -eq 1 ]]; then
    echo "    ⚠️  token NUEVO: el cliente que tuviera el anterior ya no autentica."
  fi

  # (7) Actualización: el código nuevo está en disco pero el proceso vivo NO lo cargó.
  if [[ "$era_actualizacion" -eq 1 ]]; then
    echo ""
    echo "    ⚠️  $TERM_BROKER_UNIT ya estaba CORRIENDO: copié el código nuevo, pero el proceso vivo"
    echo "        sigue con el anterior. Para aplicarlo:"
    echo "            systemctl --user restart $TERM_BROKER_UNIT"
    echo "        OJO: el restart MATA las sesiones de terminal abiertas (son hijas del broker)."
    echo "        Por eso no lo hago yo. Ver docs/term-broker.md § Actualizar."
  fi
  echo ""
}

if [[ "$SKIP_BRAIN" -eq 0 ]]; then
  if [[ -f "$BRAIN_INSTALLER" ]]; then
    echo "==> Installing the Claude-Code brain (global hooks, delegation-cost governance, norms)"
    bash "$BRAIN_INSTALLER"
  else
    echo "==> (brain installer not found at $BRAIN_INSTALLER — skipping)"
  fi
fi

echo "==> Checking prerequisites"
need() { command -v "$1" >/dev/null 2>&1 || { echo "missing: $1" >&2; exit 1; }; }
need systemctl
need jq
if [[ "$SKIP_PLASMOID" -eq 0 ]]; then
  need kpackagetool6
fi

echo "==> Ensuring ccusage is installed"
if command -v ccusage >/dev/null 2>&1; then
  echo "    already present ($(command -v ccusage))"
elif [[ "$SKIP_CCUSAGE" -eq 1 ]]; then
  if command -v npx >/dev/null 2>&1; then
    echo "    --no-ccusage set; will fall back to 'npx -y ccusage@latest' at runtime"
  else
    echo "missing: ccusage and npx (need one); rerun without --no-ccusage or install npm" >&2
    exit 1
  fi
elif command -v npm >/dev/null 2>&1; then
  echo "    installing globally via npm"
  npm i -g ccusage
else
  echo "missing: npm (needed to install ccusage); install Node.js or pass --no-ccusage if you have npx" >&2
  exit 1
fi

if [[ "$SKIP_CLAUDE_CODE" -eq 0 ]]; then
  echo "==> Ensuring the Claude Code CLI is installed (the widget measures ITS usage)"
  if command -v claude >/dev/null 2>&1; then
    echo "    already present ($(command -v claude))"
  elif [[ -x "$HOME/.local/bin/claude" ]]; then
    echo "    present in ~/.local/bin but not on PATH — exposing it (see below)"
  else
    echo "    installing via the native installer (auto-updates itself)"
    curl -fsSL https://claude.ai/install.sh | bash \
      || echo "    (could not auto-install; do it by hand: curl -fsSL https://claude.ai/install.sh | bash)"
  fi
fi
echo "==> Ensuring ~/.local/bin on PATH (zsh + bash)"
ensure_path_local_bin

# ── "Borra el previo por completo" (regla 2026-07-15). Idempotente / fail-safe. ──
# El rebrand claude-quota → cortex NO migra nada: ELIMINA el install viejo y reinstala limpio.
echo "==> Eliminando cualquier instalación previa 'claude-quota' (install limpio)"
# 1) Baja y deshabilita las units VIEJAS (evita timer/daemon duplicado).
systemctl --user disable --now claude-quota.timer claude-quota.service 2>/dev/null || true
rm -f "$HOME/.config/systemd/user/claude-quota.timer" "$HOME/.config/systemd/user/claude-quota.service"
rm -f "$HOME/.local/bin/claude-quota-fetch"   # el fetch viejo (renombrado a cortex-fetch)
systemctl --user daemon-reload 2>/dev/null || true
# 2) Borra el cache y la config VIEJOS por completo (no migramos: se regeneran limpios).
rm -rf "$HOME/.cache/claude-quota" "$HOME/.config/claude-quota"

# ── Barre la era INTERMEDIA 'claude-brain' (rename claude-brain → cortex, #312). Idempotente/fail-safe. ──
# El #312 renombró todo a 'cortex' pero NO dejó barrido de la era 'claude-brain': quien la tenía quedaba
# con DOBLE timer/daemon + DOBLE plasmoid tras actualizar. Gemelo del bloque de arriba (claude-quota).
# (El plasmoid viejo se quita junto al OLD_PLASMOID_ID, más abajo, donde vive kpackagetool6.)
echo "==> Eliminando cualquier instalación previa 'claude-brain' (era intermedia del rename a cortex)"
# 1) Deshabilita y borra las units VIEJAS (evita timer/daemon duplicado).
systemctl --user disable --now claude-brain.timer claude-brain.service 2>/dev/null || true
rm -f "$HOME/.config/systemd/user/claude-brain.timer" "$HOME/.config/systemd/user/claude-brain.service" 2>/dev/null || true
rm -f "$HOME/.local/bin/claude-brain-fetch" 2>/dev/null || true   # el fetch viejo (renombrado a cortex-fetch); NO toca los helpers compartidos
systemctl --user daemon-reload 2>/dev/null || true
# 2) Borra el cache y la config VIEJOS por completo (se regeneran limpios bajo ~/…/cortex).
rm -rf "$HOME/.cache/claude-brain" "$HOME/.config/claude-brain" 2>/dev/null || true

echo "==> Installing fetch script -> $BIN_DEST"
install -D -m 0755 "$BIN_SRC" "$BIN_DEST"

# chats-extract.js / sessions-extract.js / session-move.js junto al fetch (el fetch corre los
# extractores con node -> chats.json / sessions.json; session-move.js lo invoca la GUI al "Mover a…").
CHATS_SRC="$ROOT/bin/chats-extract.js"
[[ -f "$CHATS_SRC" ]] && install -D -m 0755 "$CHATS_SRC" "$(dirname "$BIN_DEST")/chats-extract.js"
SESSIONS_SRC="$ROOT/bin/sessions-extract.js"
[[ -f "$SESSIONS_SRC" ]] && install -D -m 0755 "$SESSIONS_SRC" "$(dirname "$BIN_DEST")/sessions-extract.js"
SESSIONMOVE_SRC="$ROOT/bin/session-move.js"
[[ -f "$SESSIONMOVE_SRC" ]] && install -D -m 0755 "$SESSIONMOVE_SRC" "$(dirname "$BIN_DEST")/session-move.js"
# Sync de sesiones cross-máquina: session-lib.js (helpers compartidos que require()an move/export/import),
# session-export.js/session-import.js y el wrapper `claude-session` (ver diseno-sync-sesiones.md).
for _s in session-lib.js session-export.js session-import.js claude-session; do
  _src="$ROOT/bin/$_s"
  [[ -f "$_src" ]] && install -D -m 0755 "$_src" "$(dirname "$BIN_DEST")/$_s"
done

if [[ ! -f "$LIMITS_DEFAULT" ]]; then
  echo "==> Seeding default limits at $LIMITS_DEFAULT"
  install -d "$(dirname "$LIMITS_DEFAULT")"
  cat > "$LIMITS_DEFAULT" <<'EOF'
# FALLBACK calibration — only used when the OAuth usage endpoint is
# unreachable (offline, or no ~/.claude/.credentials.json). When Claude Code's
# OAuth token is available the widget reads the exact /usage percentages and
# these caps are ignored.
# After editing, run: systemctl --user restart cortex.service
#
# Basis is API-EQUIVALENT COST (USD), not raw tokens — cache-read tokens
# dominate raw counts and Anthropic weights them ~0.1x. Calibrate:
#   CAP = (the popup's "$ used") / (the /usage fraction)
# Rough starting points (eyeballed against /usage on Max 20x):
#   Pro     : FIVE_HOUR_CAP_USD=2.5  WEEKLY_CAP_USD=250
#   Max 5x  : FIVE_HOUR_CAP_USD=11   WEEKLY_CAP_USD=1200
#   Max 20x : FIVE_HOUR_CAP_USD=45   WEEKLY_CAP_USD=4800
FIVE_HOUR_CAP_USD=45
WEEKLY_CAP_USD=4800
WARN_PCT=60
CRIT_PCT=85

# (e) Sync entre máquinas (opt-in): comparte un snapshot de uso vía una carpeta que tu nube ya
# replica, y el widget muestra un toggle "esta máquina / todas". "auto" autodetecta Google Drive
# (en Linux no hay cliente oficial: mejor pon la ruta explícita del mount de rclone/insync); o una
# ruta. Ausente/vacío = off (100% local, no sube nada).
# SYNC_DIR=auto
# SYNC_COMBINE_ALL=1 → el toggle "todas" combina el uso de TODAS las cuentas de tu carpeta de sync
# (misma persona, varias cuentas: p. ej. una por máquina). Sin él, solo combina máquinas de la MISMA
# cuenta (default: aísla cuentas ajenas si compartes la carpeta). Ponlo igual en cada máquina.
# SYNC_COMBINE_ALL=1
EOF
fi

echo "==> Installing systemd user units -> $UNIT_DEST"
install -D -m 0644 "$UNIT_SRC/cortex.service" "$UNIT_DEST/cortex.service"
install -D -m 0644 "$UNIT_SRC/cortex.timer"   "$UNIT_DEST/cortex.timer"

echo "==> Reloading systemd user manager"
systemctl --user daemon-reload

echo "==> Enabling timer"
systemctl --user enable --now cortex.timer

# Broker de terminal: ÚNICO punto de entrada, y solo con la bandera. Sin --con-term-broker aquí no
# pasa nada (ni archivos, ni unidad, ni token) — es el camino por DEFAULT y el que más importa.
if [[ "$WITH_TERM_BROKER" -eq 1 ]]; then
  install_term_broker
fi

echo "==> Priming cache with one run"
systemctl --user start cortex.service || true
sleep 1
if [[ -f "$HOME/.cache/cortex/state.json" ]]; then
  echo "    state.json written:"
  jq -c '{status, five: .five_hour.percent, wk: .weekly.percent}' \
     "$HOME/.cache/cortex/state.json" | sed 's/^/    /'
else
  echo "    (no state.json yet — check: journalctl --user -u cortex.service)"
fi

if [[ "$SKIP_PLASMOID" -eq 0 ]]; then
  # Empaqueta brain/ DENTRO del plasmoid (contents/brain) para que la curita self-healing de la
  # pestaña Cerebro tenga una ruta GARANTIZADA al install-brain.sh (análogo al bundle .app de macOS).
  # Se copia justo antes de empaquetar y se limpia después, para no ensuciar el árbol fuente.
  BRAIN_IN_PKG="$PLASMOID_SRC/contents/brain"
  rm -rf "$BRAIN_IN_PKG"
  if [[ -d "$ROOT/brain" ]]; then
    cp -R "$ROOT/brain" "$BRAIN_IN_PKG"
  fi
  # Versión EMBEBIDA para el autoupdate LIGERO (winturbo-style, espeja macos/make-app.sh): el SHA + la
  # fecha del commit con que se empaqueta el plasmoid, la ruta del clon y la rama, para que la pestaña
  # Cerebro compare contra GitHub y sepa desde dónde re-jalar. Se escribe justo antes de empaquetar y se
  # limpia después (como brain/), para no ensuciar el árbol fuente. FAIL-OPEN: si no hay git → "unknown"/"".
  VERSION_IN_PKG="$PLASMOID_SRC/contents/version.json"
  _sha="$(git -C "$ROOT" rev-parse --short HEAD 2>/dev/null || echo unknown)"
  _date="$(git -C "$ROOT" show -s --format=%cI HEAD 2>/dev/null || echo "")"
  _repo="$ROOT"
  _branch="$(git -C "$ROOT" rev-parse --abbrev-ref HEAD 2>/dev/null || echo "")"
  printf '{"sha":"%s","date":"%s","repo":"%s","branch":"%s"}\n' \
    "$_sha" "$_date" "$_repo" "$_branch" > "$VERSION_IN_PKG"
  if [[ "$REINSTALL" -eq 1 ]]; then
    echo "==> Removing existing plasmoid (if any)"
    kpackagetool6 -t Plasma/Applet -r "$PLASMOID_ID" 2>/dev/null || true
  fi
  # Borra los plasmoides VIEJOS (Ids legacy) SIEMPRE — que no queden 2 widgets tras el rename del Id.
  # claude-quota-widget (era vieja-vieja) y claude-brain (era intermedia del rename #312).
  kpackagetool6 -t Plasma/Applet -r "$OLD_PLASMOID_ID" 2>/dev/null || true
  kpackagetool6 -t Plasma/Applet -r "$OLD_PLASMOID_ID_BRAIN" 2>/dev/null || true
  echo "==> Installing plasmoid"
  if kpackagetool6 -t Plasma/Applet -l 2>/dev/null | grep -q "^${PLASMOID_ID}$"; then
    kpackagetool6 -t Plasma/Applet -u "$PLASMOID_SRC"
  else
    kpackagetool6 -t Plasma/Applet -i "$PLASMOID_SRC"
  fi
  rm -rf "$BRAIN_IN_PKG"   # limpia el árbol fuente tras empaquetar
  rm -f "$VERSION_IN_PKG"  # idem: version.json es temporal, no se versiona

  # Recarga plasmashell para que tome el plasmoide nuevo: actualizar el PAQUETE no refresca la instancia
  # viva. Guardado: solo si hay sesión gráfica (nada sobre SSH/headless); se salta con
  # --no-reload-shell. Si no aplica, imprime el comando manual. El panel parpadea ~1s.
  #
  # OJO (bug real, 2026-07-24): `kpackagetool6 -u` sobre un plasmoide CARGADO EN VIVO puede tumbar
  # plasmashell por su cuenta, ANTES de llegar aquí — así que ya NO condicionamos el relanzamiento a
  # `pgrep -x plasmashell` (si ya está muerto, esa condición es falsa y el bloque entero se saltaba,
  # dejando el escritorio muerto con solo un mensaje impreso a un log que nadie lee). El pgrep ahora
  # solo decide si hace falta un kquitapp6 primero; el relanzamiento + verificación corren SIEMPRE.
  if [[ "$RELOAD_SHELL" -eq 1 ]] && [[ -n "${WAYLAND_DISPLAY:-}${DISPLAY:-}" ]]; then
    echo "==> Recargando plasmashell para aplicar los cambios (el panel parpadeará un momento)..."
    if command -v kquitapp6 >/dev/null 2>&1 && pgrep -x plasmashell >/dev/null 2>&1; then
      kquitapp6 plasmashell >/dev/null 2>&1 || true
    fi
    sleep 1
    # Relanzamiento ROBUSTO. El patrón viejo `( kstart … & ) || ( plasmashell … & )` tenía un bug:
    # un subshell con `&` SIEMPRE regresa 0 (el backgrounding "triunfa" aunque el comando no exista)
    # → si kstart faltaba, el fallback jamás corría y plasmashell quedaba MUERTO (bug real en
    # CachyOS, 2026-07-18: el update cerró Plasma y no lo levantó). Ahora: candidato elegido con
    # `command -v` explícito, detach real (setsid+nohup, stdin cerrado — sobrevive a `curl|bash`),
    # y VERIFICACIÓN con pgrep + reintento directo + aviso ruidoso si aun así no levantó.
    _kstart=""
    for _c in kstart kstart6 kstart5; do
      command -v "$_c" >/dev/null 2>&1 && { _kstart="$_c"; break; }
    done
    if [[ -n "$_kstart" ]]; then
      ( setsid nohup "$_kstart" plasmashell >/dev/null 2>&1 </dev/null & ) || true
    else
      ( setsid nohup plasmashell >/dev/null 2>&1 </dev/null & ) || true
    fi
    for _i in 1 2 3 4 5; do sleep 1; pgrep -x plasmashell >/dev/null 2>&1 && break; done
    if ! pgrep -x plasmashell >/dev/null 2>&1; then
      echo "    (no levantó vía ${_kstart:-directo}; reintento lanzando plasmashell directo…)"
      ( setsid nohup plasmashell >/dev/null 2>&1 </dev/null & ) || true
      sleep 2
    fi
    if pgrep -x plasmashell >/dev/null 2>&1; then
      echo "    plasmashell arriba de nuevo ✓"
    else
      echo "⚠️  plasmashell NO volvió a levantar — levántalo a mano:  kstart plasmashell   (o:  plasmashell & disown)"
    fi
  else
    echo "==> Para ver los cambios, recarga plasmashell:  kquitapp6 plasmashell; kstart plasmashell"
    echo "    (o:  just reload-plasmashell  ·  o cierra sesión y vuelve a entrar en Wayland)"
  fi
fi

cat <<EOF

Done.

The Claude-Code brain is installed globally (hooks + delegation-cost governance + norms in
  ~/.claude). See README.md; re-run any time (idempotent). Skip it with --no-brain.

Next steps:
  - Right-click your Plasma panel -> Add or Manage Widgets -> search "Cortex Widget"
  - Drag it onto the panel (or into the system tray slot).
  - Hover for the breakdown; tune caps in: $LIMITS_DEFAULT

Debug:
  systemctl --user status cortex.timer
  journalctl --user -u cortex.service -n 20
  cat ~/.cache/cortex/state.json | jq .
EOF

# Login reminder: sin sesión de Claude Code el widget no ve tu cuota real (solo el fallback calibrado).
# El login es interactivo/por-usuario: el instalador NO puede hacerlo por ti.
if command -v claude >/dev/null 2>&1; then
  if ! claude auth status >/dev/null 2>&1; then
    echo ""
    echo "IMPORTANT: log in to Claude Code so the widget reads your REAL quota:"
    echo "  claude        # then /login with your account"
  fi
else
  echo ""
  echo "NOTE: 'claude' isn't on PATH yet (maybe a fresh install) — open a new shell, then:"
  echo "  claude        # /login so the widget shows your real quota"
fi
