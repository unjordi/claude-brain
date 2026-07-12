# Claude Brain Widget — macOS menu-bar app

The macOS sibling of the [KDE Plasma widget](../README.md). Puts your Claude
Code subscription usage in the menu bar: a two-row `5h` / `7d` indicator with a
mini progress bar and % per row, orange normally and red only once a bucket is
about to throttle (> 90 %). Click it for a 3-tab popover with the full
breakdown, in Spanish, matching the plasmoid's look.

It shares the Linux port's design and the **same calibration logic** — only the
view layer (a native Swift status-bar app instead of a QML plasmoid) and the
scheduler (a `launchd` agent instead of a systemd timer) differ.

## Why this exists

Claude Code's built-in `/usage` only works inside an interactive session. This
app reads the **same usage data `/usage` shows** — via Anthropic's OAuth usage
endpoint, using the token Claude Code already stores in your Keychain — and
puts it in your menu bar: a "is now a good time to start a long Opus session?"
indicator you can glance at from anywhere. When the endpoint is unreachable
(offline / no credentials) it falls back to a calibrated estimate from local
transcripts via [ccusage](https://github.com/ryoppippi/ccusage).

## What you see

In the menu bar (always visible): a **two-row indicator**, one row per bucket —

```
5h ▬▬▬▬▬░░░ 18% ⟳4h
7d ▬▬░░░░░░  6% ⟳3d
```

- Label + mini progress bar + `N%` + `⟳` and a compact countdown to reset.
- Accent color is **orange** (`#e8884a`) always, switching to **red**
  (`#dc3545`) only once a bucket is **> 90 %** (throttle warning) — there's no
  green/amber tier, this mirrors the plasmoid's `pctColor()` exactly.
- `…` while the cache hasn't been written yet, `!` if the app can't read it.
- Hover for a tooltip: `Claude: 5h 18% · 7d 6%`

Click the indicator for a **3-tab popover**, UI in Spanish, with a vertical
tab rail on the left:

- **Límites** — Sesión (5 h) and Semanal (7 d), each an animated progress bar,
  `%` used, "Se restablece en Xh" and "≈ $Y.YY (API equiv local)"; footer
  shows `datos reales` (OAuth) or `estimado local` (ccusage fallback), the
  5-minute refresh cadence, and how long ago it last updated.
- **Resumen** — 9 stat cards (Sesiones, Mensajes, Tokens totales, Días
  activos, Racha actual, Racha más larga, Hora pico, Modelo favorito, Costo
  API-equiv) plus a GitHub-style daily-activity heatmap, all from **local**
  Claude Code usage on this machine (via `ccusage` + transcript parsing).
- **Modelos** — a stacked bar chart of daily token usage colored per model,
  plus a table with in/out tokens and % share per model.
- The rail's bottom buttons: **refresh** (kicks off a real fetch via
  `~/.local/bin/claude-brain-fetch`, not just a cache re-read) and **quit**.

## How it works

Three pieces, intentionally separated — the same shape as the Linux port:

```
┌────────────────────────────────┐
│ 1. claude-brain-fetch          │ bash + jq + curl (OAuth) + ccusage
│    runs every 5 min via        │     ↓ writes
│    a launchd LaunchAgent        │ ~/Library/Caches/claude-brain/state.json
│                                  │ ~/Library/Caches/claude-brain/stats.json
└────────────────────────────────┘            ↑ reads
                                              │ (every 10s)
┌────────────────────────────────┐            │
│ 2. Claude Brain Widget.app     │────────────┘
│    NSStatusItem 2-row indicator│
│    + 3-tab SwiftUI popover     │
└────────────────────────────────┘
```

The **launchd agent enforces the 5-minute refresh floor** (`StartInterval=300`)
— Anthropic's API issues abuse warnings if you poll the underlying data too
aggressively, so the agent is the single source of truth for cadence. The app is
a pure view: it reads the cache files every 10 s and redraws the menu-bar
indicator.

`state.json` (limits) comes from the OAuth `/usage` endpoint — see below.
`stats.json` (Resumen/Modelos tabs) is a separate write, built from
`ccusage daily --json --breakdown` plus a `grep`/`awk` pass over the raw
`~/.claude/projects/**/*.jsonl` transcripts (session count, message count,
peak local hour) — all local to this machine, not the same data as `/usage`.

## Where the percentage comes from

**Primary: Anthropic's OAuth usage endpoint** (`api.anthropic.com/api/oauth/usage`)
— the exact data source `/usage` renders. The fetch script reads the OAuth token
Claude Code already stores (macOS Keychain entry `Claude Code-credentials`, or
`~/.claude/.credentials.json`) and gets back your real 5-hour and 7-day
utilization percentages *and* their actual reset times (the weekly window is
rolling, not calendar-aligned). When this works the snapshot is marked
`"basis": "oauth"` and **matches `/usage` exactly** — no calibration involved.

**Fallback: ccusage cost estimation** — used only when the endpoint is
unreachable (offline, or no Claude Code credentials). The basis is
**API-equivalent cost**, not raw token count: ccusage's token totals are
~90–97 % *cache-read* tokens, which Anthropic's limits weight at roughly 0.1×,
so dividing raw tokens by a token cap over-reports several-fold. Cost encodes
the weighting (cache-read 0.1×, output 5×, Opus 5× over Sonnet), so cost ÷
cost-cap is a usable approximation — but only an approximation; the snapshot
is marked `"basis": "cost"`.

The dollar figures in the popover are **API-equivalent** cost from ccusage —
what your token volume *would* cost at public pay-per-token list prices — not
your subscription billing and not a real spend. Cache-read-heavy coding inflates
this figure ~10×, so a heavy week can read as hundreds of API-equivalent dollars.

> **The `*_CAP_USD` values are fallback calibration denominators, not budgets.**
> A `WEEKLY_CAP_USD` of 4800 does **not** mean Anthropic grants you $4,800/week —
> it's just the API-equivalent figure that corresponds to 100 % of your limit.
> It exists only to turn cost into a percentage when the OAuth endpoint is
> unavailable; the popover shows the **% of limit** and the API-equivalent
> **$ spent**, never a "$X of $Y" ceiling.

## Prerequisites

- **macOS 13+** (built and tested on macOS 26 / Apple silicon).
- **Xcode command-line tools** (`swift` — `xcode-select --install`).
- **`jq`** for JSON normalization (`brew install jq`).
- **Node.js** (`npm`/`npx`) to install `ccusage`. The installer runs
  `npm i -g ccusage` for you; if you already have `ccusage` on `PATH` it's used
  directly. Pass `--no-ccusage` to fall back to `npx -y ccusage@latest` at every
  fire (~6 s slower per refresh).

## Install

**Self-contained (pulls its own deps — recommended):**

```sh
curl -fsSL https://raw.githubusercontent.com/unjordi/claude-brain/main/bootstrap.sh | bash
```

`bootstrap.sh` installs any missing `jq`/`node` via Homebrew, clones the repo to `~/claude-brain`,
and runs the top-level `install.sh`. (It won't auto-install Homebrew itself, and asks you to run
`xcode-select --install` if `swift` is missing.) **Or by hand** from the repo:

> The widget measures **Claude Code (the `claude` CLI)**: the installer also installs it (skip with
> `--no-claude-code`), but **you log in** — run `claude` and `/login` once, or the widget only shows the
> calibrated fallback, not your real quota.

```sh
cd macos
./install.sh
```

Or with [just](https://github.com/casey/just):

```sh
just install
```

This builds `Claude Brain Widget.app` into `~/Applications`, installs the fetch script
and launchd agent, primes the cache with one run, and launches the app. Look for
the `5h` / `7d` indicator in your menu bar.

To launch at login: **System Settings → General → Login Items → +** and add
**Claude Brain Widget**.

## Tuning the fallback caps

When the OAuth endpoint is reachable the percentages are exact and **no tuning
is needed** — the caps in `~/.config/claude-quota/limits.env` only matter for
the offline/no-credentials fallback. To calibrate them, run `/usage` once and
set each USD cap to **the popover's "$ used" ÷ the `/usage` fraction**, then
reload the agent:

```sh
# e.g. popover shows "$16" on the 5-hour bar and /usage says 36% →
#   FIVE_HOUR_CAP_USD = 16 / 0.36 ≈ 45
$EDITOR ~/.config/claude-quota/limits.env
launchctl kickstart -k gui/$(id -u)/io.github.unjordi.claude-brain
```

Rough starting points (eyeballed against `/usage` on Max 20x — your mileage will
vary with how cache-heavy your sessions are):

| Plan | `FIVE_HOUR_CAP_USD` | `WEEKLY_CAP_USD` |
|---|---|---|
| Pro | 2.5 | 250 |
| Max 5x | 11 | 1,200 |
| Max 20x | 45 | 4,800 |

## Development

```sh
just build      # compile the release binary
just app        # assemble Claude Brain Widget.app under build/
just run        # run the just-built binary in the foreground (logs to terminal)
just reload     # rebuild + reinstall + relaunch after editing Swift sources
just refresh    # force one fetch cycle now and print state.json
just status     # launchd agent state + last exit code
just logs       # tail the fetch agent logs
just lint       # shellcheck the bash scripts
```

The app is a Swift Package (no Xcode project): `swift build` produces the
binary, `make-app.sh` wraps it in a `.app` bundle with an `LSUIElement` Info.plist
(menu-bar agent, no Dock icon).

## Troubleshooting

- **Indicator rows show `…`** — the cache file hasn't been written yet. Run
  `just refresh`; the first `ccusage` run can take a few seconds to cold-start.
- **Indicator rows show `!`** — the app can't read `state.json`. Check the
  fetch agent: `cat /tmp/claude-brain.err.log`.
- **No indicator at all** — confirm the app is running
  (`pgrep -lf ClaudeQuota`); if not, `open "~/Applications/Claude Brain Widget.app"`.
- **Percentages way off from `/usage`** — check `jq .basis` on
  `~/Library/Caches/claude-brain/state.json`. If it says `"cost"`, the OAuth
  endpoint isn't reachable (are Claude Code credentials in your Keychain? are
  you online?) and you're on the calibrated fallback — see above. If it says
  `"oauth"`, the numbers come straight from Anthropic and should match.
- **Resumen/Modelos tabs empty or stale** — those come from `stats.json`, not
  `state.json`. Check it exists and is fresh:
  `jq .updated_at ~/Library/Caches/claude-brain/stats.json`. It's written by
  the same `claude-brain-fetch` run but is best-effort (missing `ccusage` or
  an empty `~/.claude/projects` just leaves it absent, without failing the
  limits fetch).

## Uninstall

```sh
just uninstall   # remove app, agent, fetch script (keeps limits.env)
just purge       # also remove ~/.config/claude-quota and the cache
```

## License

MIT. See [../LICENSE](../LICENSE).
