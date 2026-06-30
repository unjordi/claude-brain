# Claude Code Quota Widget — task runner
#
# Run `just --list` to see all targets.

PLASMOID_ID := "io.github.unjordi.claude-quota-widget"
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

# Remove everything (keeps ~/.config/claude-quota/limits.env)
uninstall-keep-cfg:
    ./uninstall.sh --keep-cfg

# Remove everything including config
uninstall:
    ./uninstall.sh

# Upgrade just the plasmoid (after editing main.qml — no systemd touch)
upgrade-plasmoid:
    kpackagetool6 -t Plasma/Applet -u {{PLASMOID_SRC}}

# Restart plasmashell to pick up a plasmoid change
reload-plasmashell:
    kquitapp6 plasmashell
    sleep 1
    (kstart plasmashell >/dev/null 2>&1 &)

# Run the plasmoid standalone for debugging
preview:
    plasmoidviewer -a {{PLASMOID_ID}}

# Build a distributable .plasmoid (zip) of the widget
package:
    rm -f dist/claude-quota-widget-{{VERSION}}.plasmoid
    mkdir -p dist
    cd src/plasmoid && zip -r ../../dist/claude-quota-widget-{{VERSION}}.plasmoid . -x '*.swp' '*.DS_Store'
    @echo "Wrote dist/claude-quota-widget-{{VERSION}}.plasmoid"

# Lint shell scripts (requires shellcheck)
lint:
    shellcheck install.sh uninstall.sh src/bin/claude-quota-fetch

# Force one fetch cycle now (via systemd) and print the result
refresh:
    systemctl --user start claude-quota.service
    sleep 1
    jq . ~/.cache/claude-quota/state.json

# Show timer status + last few journal entries
status:
    systemctl --user status claude-quota.timer --no-pager || true
    @echo ""
    journalctl --user -u claude-quota.service -n 10 --no-pager

# Tail the systemd journal for the fetch service
logs:
    journalctl --user -u claude-quota.service -f

# Wipe build artifacts
clean:
    rm -rf dist
