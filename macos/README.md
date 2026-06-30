# Claude Code Quota — macOS menu-bar app

The macOS sibling of the [KDE Plasma widget](../README.md). Puts your Claude
Code subscription usage in the menu bar: a small color-coded pill showing your
5-hour-block %, green → amber → red as you approach the cap. Click it for the
full breakdown.

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

In the menu bar (always visible):

- A small color-coded pill showing your **5-hour block %**
- Green ≤ 60 %, amber 60–85 %, red > 85 %
- Hover for a tooltip: `Claude Code: 5h 18% · wk 6%`

Click the pill for the popover:

- **5-hour block** — progress bar, % used, resets-in, API-equivalent cost
- **Weekly** — progress bar, % used, resets-in, API-equivalent cost
- Last-refresh timestamp, plus **Refresh** and **Quit** buttons

## How it works

Three pieces, intentionally separated — the same shape as the Linux port:

```
┌────────────────────────────────┐
│ 1. claude-quota-fetch          │ bash + jq + curl (OAuth) + ccusage
│    runs every 5 min via        │     ↓ writes
│    a launchd LaunchAgent        │ ~/Library/Caches/claude-quota/state.json
└────────────────────────────────┘            ↑ reads
                                              │ (every 10s)
┌────────────────────────────────┐            │
│ 2. ClaudeQuota.app (Swift)     │────────────┘
│    NSStatusItem pill + popover │
└────────────────────────────────┘
```

The **launchd agent enforces the 5-minute refresh floor** (`StartInterval=300`)
— Anthropic's API issues abuse warnings if you poll the underlying data too
aggressively, so the agent is the single source of truth for cadence. The app is
a pure view: it reads the cache file every 10 s and renders the pill.

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

```sh
cd macos
./install.sh
```

Or with [just](https://github.com/casey/just):

```sh
just install
```

This builds `Claude Quota.app` into `~/Applications`, installs the fetch script
and launchd agent, primes the cache with one run, and launches the app. Look for
the colored % pill in your menu bar.

To launch at login: **System Settings → General → Login Items → +** and add
**Claude Quota**.

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
launchctl kickstart -k gui/$(id -u)/io.github.unjordi.claude-quota
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
just app        # assemble Claude Quota.app under build/
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

- **Pill shows `…`** — the cache file hasn't been written yet. Run
  `just refresh`; the first `ccusage` run can take a few seconds to cold-start.
- **Pill shows `!`** — the app can't read `state.json`. Check the fetch agent:
  `cat /tmp/claude-quota.err.log`.
- **No pill at all** — confirm the app is running (`pgrep -lf ClaudeQuota`); if
  not, `open "~/Applications/Claude Quota.app"`.
- **Percentages way off from `/usage`** — check `jq .basis` on
  `~/Library/Caches/claude-quota/state.json`. If it says `"cost"`, the OAuth
  endpoint isn't reachable (are Claude Code credentials in your Keychain? are
  you online?) and you're on the calibrated fallback — see above. If it says
  `"oauth"`, the numbers come straight from Anthropic and should match.

## Uninstall

```sh
just uninstall   # remove app, agent, fetch script (keeps limits.env)
just purge       # also remove ~/.config/claude-quota and the cache
```

## License

MIT. See [../LICENSE](../LICENSE).
