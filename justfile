# Claude Code Quota Widget — task runner
#
# Run `just --list` to see all targets.

PLASMOID_ID := "io.github.unjordi.cortex"
PLASMOID_SRC := justfile_directory() + "/src/plasmoid"
VERSION := `jq -r '.KPlugin.Version' src/plasmoid/metadata.json`

default: help

# Show all available targets
help:
    @just --list

# Install everything: fetch script, systemd timer, plasmoid
install:
    ./install.sh

# Install only the fetch script + systemd timer (skip the plasmoid)
install-headless:
    ./install.sh --no-plasmoid

# Reinstall — removes the plasmoid first, then full install
reinstall:
    ./install.sh --reinstall

# Remove everything (keeps ~/.config/cortex/limits.env)
uninstall-keep-cfg:
    ./uninstall.sh --keep-cfg

# Remove everything including config
uninstall:
    ./uninstall.sh

# Upgrade just the plasmoid (after editing main.qml — no systemd touch)
upgrade-plasmoid:
    kpackagetool6 -t Plasma/Applet -u {{PLASMOID_SRC}}

# Restart plasmashell to pick up a plasmoid change (relanzamiento robusto: command -v explícito +
# setsid/nohup + verificación — un `( kstart & )` pelón "triunfa" aunque kstart no exista)
reload-plasmashell:
    kquitapp6 plasmashell || true
    sleep 1
    sh -c 'if command -v kstart >/dev/null 2>&1; then setsid nohup kstart plasmashell >/dev/null 2>&1 </dev/null & else setsid nohup plasmashell >/dev/null 2>&1 </dev/null & fi'
    sh -c 'sleep 2; pgrep -x plasmashell >/dev/null && echo "plasmashell arriba ✓" || echo "⚠️  no levantó — a mano: plasmashell & disown"'

# Run the plasmoid standalone for debugging
#
# ⚠️ TRAMPA (medida en vivo 2026-09-09): la superficie de plasmoidviewer NO REPINTA cuando su
# ventana no tiene el foco. Una captura de pantalla te devuelve el PRIMER frame pintado, para
# siempre — así que un estado que llega 1 s después de abrir (cualquier DataSource "executable")
# se ve eternamente en su texto de "cargando…" aunque el dato ya esté. Cuesta caro: se puede
# perseguir un bug de binding que no existe.
#   · Cómo distinguirlo: mete un contador con un `Timer { interval: 500; repeat: true }` en el
#     label que estés mirando. Si sigue en t=0 al cabo de unos segundos, el frame está congelado
#     y la captura NO es un oráculo válido.
#   · Qué SÍ vale como oráculo: `console.warn` (no `console.log` — Plasma lo filtra) leído con
#     `journalctl --user`, corriendo el viewer con QT_LOGGING_RULES="*.debug=true;*.info=true".
# Además la ventana RECORTA el popup si es más grande que ella: el texto de la derecha no aparece,
# así que un marcador de depuración va al PRINCIPIO de la cadena, no al final.
preview:
    plasmoidviewer -a {{PLASMOID_ID}}

# Build a distributable .plasmoid (zip) of the widget
package:
    rm -f dist/cortex-{{VERSION}}.plasmoid
    mkdir -p dist
    cd src/plasmoid && zip -r ../../dist/cortex-{{VERSION}}.plasmoid . -x '*.swp' '*.DS_Store'
    @echo "Wrote dist/cortex-{{VERSION}}.plasmoid"

# Install ONLY the shared Claude-Code brain (global hooks, delegation-cost governance, norms)
install-brain:
    bash brain/install-brain.sh

# Remove ONLY the Claude-Code brain (inverse of install-brain; keeps dashboard + memory)
uninstall-brain:
    bash brain/uninstall-brain.sh

# Run the brain's self-tests (isolated fake $HOME; touches nothing in ~/.claude)
test-brain:
    bash brain/test-brain.sh

# Lint shell scripts (requires shellcheck)
lint:
    shellcheck install.sh uninstall.sh src/bin/cortex-fetch

# Force one fetch cycle now (via systemd) and print the result
refresh:
    systemctl --user start cortex.service
    sleep 1
    jq . ~/.cache/cortex/state.json

# Show timer status + last few journal entries
status:
    systemctl --user status cortex.timer --no-pager || true
    @echo ""
    journalctl --user -u cortex.service -n 10 --no-pager

# Tail the systemd journal for the fetch service
logs:
    journalctl --user -u cortex.service -f

# Wipe build artifacts
clean:
    rm -rf dist
