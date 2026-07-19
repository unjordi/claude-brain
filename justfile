# Claude Code Quota Widget — task runner
#
# Run `just --list` to see all targets.

PLASMOID_ID := "io.github.unjordi.claude-brain"
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

# Remove everything (keeps ~/.config/claude-brain/limits.env)
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
preview:
    plasmoidviewer -a {{PLASMOID_ID}}

# Build a distributable .plasmoid (zip) of the widget
package:
    rm -f dist/claude-brain-{{VERSION}}.plasmoid
    mkdir -p dist
    cd src/plasmoid && zip -r ../../dist/claude-brain-{{VERSION}}.plasmoid . -x '*.swp' '*.DS_Store'
    @echo "Wrote dist/claude-brain-{{VERSION}}.plasmoid"

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
    shellcheck install.sh uninstall.sh src/bin/claude-brain-fetch

# Force one fetch cycle now (via systemd) and print the result
refresh:
    systemctl --user start claude-brain.service
    sleep 1
    jq . ~/.cache/claude-brain/state.json

# Show timer status + last few journal entries
status:
    systemctl --user status claude-brain.timer --no-pager || true
    @echo ""
    journalctl --user -u claude-brain.service -n 10 --no-pager

# Tail the systemd journal for the fetch service
logs:
    journalctl --user -u claude-brain.service -f

# Wipe build artifacts
clean:
    rm -rf dist
