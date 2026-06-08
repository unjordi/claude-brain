# Claude Code Quota Widget

KDE Plasma 6 widget for Fedora that shows your Claude Code 5-hour block and
weekly usage. Hover for a breakdown; the tray icon flips color as you approach
the cap.

```
┌──────────────────────────────┐
│  Claude Code quota           │
│                              │
│  5-hour block         31 %   │
│  ███░░░░░░░░░░░░░░░░░░       │
│  resets in 2h · $32.60       │
│                              │
│  Weekly                2 %   │
│  ░░░░░░░░░░░░░░░░░░░░░       │
│  resets in 6d · $32.60       │
│                              │
│  updated 4s ago              │
└──────────────────────────────┘
```

## Architecture

Three pieces, each independently testable:

| Piece | Role |
|---|---|
| `claude-quota-fetch` (bash + jq) | Runs `ccusage`, normalizes JSON, atomically writes `~/.cache/claude-quota/state.json`. |
| `claude-quota.{service,timer}` (systemd user) | Fires the fetch script every 5 min — **the 5-minute floor lives here, not in the widget.** |
| Plasma 6 plasmoid (`com.jamesh.claudequota`) | Polls the cache file every 10 s and renders the icon + hover tooltip. |

The systemd timer is the single source of truth for poll cadence. Anthropic
issues API abuse warnings for tighter cadences, so the timer's
`OnUnitActiveSec=5min` is treated as a hard floor.

## Prerequisites

- KDE Plasma 6 (Fedora 41+ ships it; this was developed on Fedora 44).
- `systemd --user` (any modern Linux desktop).
- `jq`.
- `ccusage` — either installed globally (`npm i -g ccusage`) or available via
  `npx`; the fetch script falls back to `npx -y ccusage@latest` automatically.

## Install

```sh
./install.sh
```

Then in Plasma: right-click your panel → **Add or Manage Widgets…** → search
**Claude Code Quota** → drag onto the panel or into the system-tray slot.

### Tuning the caps

The fetch script reads token caps from `~/.config/claude-quota/limits.env`
(seeded on first install with Max-20x defaults). Edit it to match your plan,
then:

```sh
systemctl --user restart claude-quota.service
```

Rough starting points:

| Plan | `FIVE_HOUR_CAP_TOKENS` | `WEEKLY_CAP_TOKENS` |
|---|---|---|
| Pro | 20,000,000 | 400,000,000 |
| Max 5x | 70,000,000 | 1,000,000,000 |
| Max 20x | 140,000,000 | 2,000,000,000 |

These are approximations — ccusage doesn't expose Anthropic's exact subscription
ceilings. Watch the icon over a real working day and tune until the color tier
matches your gut sense of "getting close."

## Debug

```sh
systemctl --user status claude-quota.timer
journalctl --user -u claude-quota.service -n 20
cat ~/.cache/claude-quota/state.json | jq .
```

To iterate on the QML without re-running ccusage:

```sh
# Reinstall just the plasmoid
kpackagetool6 -t Plasma/Applet -u src/plasmoid
# Reload Plasma to pick up the changes
kquitapp6 plasmashell && kstart plasmashell
```

## Uninstall

```sh
./uninstall.sh                # removes everything
./uninstall.sh --keep-cfg     # keep ~/.config/claude-quota/limits.env
```

## License

MIT.
