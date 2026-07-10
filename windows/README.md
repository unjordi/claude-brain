# Claude Brain Widget — Windows tray app

A native **WinForms tray widget** (.NET 10) that puts your Claude Code
subscription usage in the Windows notification area. It's the Windows port of
the [KDE plasmoid](../README.md) and the [macOS menu-bar app](../macos/README.md),
and renders the same three-tab breakdown.

- **Tray icon:** two stacked mini-bars — top = 5-hour block, bottom = weekly —
  each filled by its % and colored orange (or **red past 90 %**). The bar lengths
  are the glanceable signal; hover for the exact `Claude: 5h N% · 7d M%` tooltip.
- **Left-click → popup** with a vertical tab rail:
  - **Límites** — 5-hour + weekly progress bars, %, resets-in, API-equiv $.
  - **Resumen** — 9 stat cards (sessions, messages, tokens, active days, current
    & longest streak, peak hour, favorite model, API-equiv cost) + a GitHub-style
    daily-activity heatmap.
  - **Modelos** — stacked per-day token chart + a per-model table with in/out
    tokens and %.
  - **Proyectos** — same, grouped by project folder (`~/.claude/projects/<slug>`);
    the slug is mapped back to a readable name via `~/.claude.json`. A project with
    local Claude Code sessions is **expandable** (chevron): click a session to
    resume it in a new terminal (`claude --resume <id>` in its cwd — Windows
    Terminal if present, else `cmd.exe`). **Right-click a project or session row →
    Renombrar…** opens a small dialog to set a custom label (leave it empty to
    restore the original); a *Restaurar original* entry shows when an alias is
    active. Renames persist to `~/.claude/proyectos-alias.json` /
    `sesiones-alias.json` (honoring `CLAUDE_CONFIG_DIR`) and trigger a refetch so the
    list reloads with the new name — the same maps the macOS/Plasma ports read.
  - **Chats** — recent Claude **desktop-app** conversations (read-only): a per-model
    breakdown with %, a list of recents (title + model badge + relative date), and a
    footer showing the summary of the chat under the cursor. **Only shown when local
    chats exist.**
  - **Resumen / Modelos / Proyectos / Chats** each carry a **{hoy · 7d · 30d · ∞}**
    range footer (default ∞); it recomputes tokens, models, projects, the summary
    cards and the chat list over the chosen window (the heatmap stays all-time).
- **Right-click → menu:** Actualizar ahora · Iniciar con Windows (toggle) · Salir.

## Why a rewrite (not a port of the fetch script)

Linux and macOS run a bash `claude-quota-fetch` script on a systemd/launchd timer
that writes a cache file the UI reads. Windows has no bash/jq/curl by default, so
the always-running tray app **does the fetch itself in C#** every 5 minutes:

```
┌───────────────────────────────────────────────┐
│  ClaudeBrain.exe (WinForms tray, always on)     │
│                                                 │
│  every 5 min ─┬─ 1. OAuth /usage  (HttpClient)  │  → exact 5h / 7d %, resets
│               ├─ 2. transcripts   (System.Text) │  → tokens/day+model,
│               │      ~/.claude/projects/*.jsonl │     sessions, msgs, peak hour
│               └─ 3. ccusage       (if on PATH)  │  → API-equivalent $
│                        ↓ writes                 │
│   %LOCALAPPDATA%\claude-quota\{state,stats}.json │  ← same schema as Linux/mac
│                        ↓ reads (every 10s tick)  │
│              tray icon + tooltip + popup         │
└───────────────────────────────────────────────┘
```

The cache files use the **same schema** the other platforms write, so a snapshot
is inspectable and cross-platform-compatible. The 5-minute floor is preserved
(fetch only fires when the cache is older than 5.5 min, or on demand), keeping the
OAuth polling well under any abuse threshold.

## Data sources

| Figure | Source | Needs |
|---|---|---|
| 5-hour & weekly **%** and reset times | Anthropic OAuth `/usage` endpoint | just the token in `%USERPROFILE%\.claude\.credentials.json` |
| **Tokens** by day & model, days/heatmap | local transcripts, parsed in C# | nothing |
| **Sessions / messages / peak hour** | local transcripts, parsed in C# | nothing |
| API-equivalent **$ cost** | [ccusage](https://github.com/ryoppippi/ccusage) (`ccusage` or `npx ccusage@latest`) | Node.js on `PATH` |
| **Chats** tab + Proyectos **resume** list | bundled `bin\*.js` extractors run via `node` | Node.js on `PATH` |

Without Node/ccusage, everything works **except** the `$` figures (they show `—`),
the **Chats** tab, and the Proyectos **resume** list (all three need Node). The
percentages are exact and come straight from Anthropic; the tokens are parsed from
the same JSONL transcripts ccusage would read, so the Resumen/Modelos tabs are
fully populated on any machine — Node just adds the cost overlay and the two
extractors.

**Chats / sessions extraction.** `chats.json` and `sessions.json` are produced the
same way as Linux/macOS: `install.ps1` copies the bundled `bin\chats-extract.js`
and `bin\sessions-extract.js` next to the exe (`…\Programs\ClaudeBrain\bin`), and
each fetch runs them with `node` (fail-open: no Node / no script / an error just
leaves the file absent, so the Chats tab hides and the resume list stays empty).
`chats-extract.js` reads the desktop app's local IndexedDB (no network);
`sessions-extract.js` lists `~/.claude/projects/<slug>/*.jsonl`. They write into
`%LOCALAPPDATA%\claude-quota` alongside `state.json`/`stats.json`.

The `$` values are **API-equivalent** cost (what pay-per-token would have cost),
labeled "(API equiv local)" — a "how much is my subscription saving me?" signal,
not an invoice. They're local to this machine's transcripts.

## Install

**Self-contained (pulls its own deps via winget — recommended):**

```powershell
irm https://raw.githubusercontent.com/unjordi/claude-brain/main/bootstrap.ps1 | iex
```

`bootstrap.ps1` winget-installs anything missing (Git — brings Git Bash, jq, Node; and .NET 10 SDK,
now only a **build fallback** since the widget install downloads the precompiled `ClaudeBrain.exe`),
clones the repo to `%USERPROFILE%\claude-brain`, and runs the brain + widget installers. If winget
just installed something, open a fresh terminal and re-run so the new `PATH` is visible. **Or by
hand** from the repo:

> The widget measures **Claude Code (the `claude` CLI)** — not the desktop app. The installer also
> installs the CLI (skip with `-NoClaudeCode`), but **you log in**: run `claude` and `/login` once, or
> the widget only shows the calibrated fallback. Your Pro/Max subscription works.

```powershell
cd windows
pwsh -File install.ps1              # download exe, install, autostart, launch
pwsh -File install.ps1 -Build       # build from source instead (needs .NET SDK)
pwsh -File install.ps1 -NoAutostart # skip the "start with Windows" registration
```

By default `install.ps1` **downloads the precompiled, self-contained `ClaudeBrain.exe`**
(bundles the .NET runtime) from the rolling `windows-latest` release — **no .NET SDK needed**.
It copies it to `%LOCALAPPDATA%\Programs\ClaudeBrain\ClaudeBrain.exe`, sets the `HKCU\…\Run`
autostart entry, and launches it. Re-run any time to update in place; it also migrates an old
`ClaudeQuota` install (removes its autostart + folder).

**Fallback / devs:** if the download fails (e.g. the release is rebuilding, ~1–2 min) it builds from
source with `dotnet publish` — that path needs the [.NET 10 SDK](https://dotnet.microsoft.com/download).
`-Build` forces it.

## Autoupdate ligero (winturbo-style)

Igual que el puerto macOS, `install.ps1` escribe un `version.json` **junto al exe**
(`%LOCALAPPDATA%\Programs\ClaudeBrain\version.json`) con el `sha`, la `date`, la ruta del
`repo` (el clon local) y la `branch` del commit con que se buildeó (lee git desde el repo).
Al abrir la pestaña **Cerebro**, el widget consulta `commits/main` de
`github.com/unjordi/claude-brain` (throttle 1×/15 min, timeout 6 s, **fail-open**: sin red /
sin `version.json` / sin clon → no molesta). Si el remoto avanzó, dibuja arriba un banner naranja
**"⬆ Actualizar widget (local → remoto)"**.

Al pulsarlo, corre un `.ps1` **temporal y detachado** (`UseShellExecute`, ventana oculta) que
hace `git -C <repo> fetch origin` + `git merge --ff-only origin/main` y **solo si el fast-forward
tiene éxito** llama a `windows\install.ps1`. Como el exe es self-contained single-file, no puede
sobreescribirse mientras corre: por eso NO nos auto-cerramos a ciegas — es `install.ps1` quien
detiene la instancia vieja (soltando el lock del exe), reconstruye, recopia y relanza. El script
vive en un proceso pwsh/powershell aparte, así que sobrevive a que maten al widget. Si el ff aborta
(árbol sucio / no-ff) no toca nada: la app sigue viva → **nunca te quedas sin widget**; un respaldo
a 60 s resetea el banner y avisa. Requiere `git` + `pwsh`/`powershell` en el PATH del clon.

## Account guard (opt-in)

Claude Code and the Claude desktop app can share a single OS credential slot, so a
re-login on either can silently switch which account the widget reads. To catch
that, **pin the expected account**: right-click the tray icon → **Fijar esta
cuenta** (writes the active account's UUID to `%LOCALAPPDATA%\claude-quota\account`).
If the active account ever differs from the pinned one, the footer turns red with a
`⚠ … no es la cuenta fijada` warning and the tooltip shows `⚠ otra cuenta`.
**Quitar cuenta fijada** removes the pin. The file may hold a UUID or an email.

All three platforms share this guard (Linux/macOS read the same pin from
`~/.config/claude-quota/account`, overridable via `$CLAUDE_QUOTA_ACCOUNT`).

## Sync between machines (opt-in)

Roll up your Claude usage across every computer you use into one **combined view**.
It is **opt-in** — nothing is uploaded unless you point the widget at a cloud folder
your machines already share (Google Drive, etc.). Turn it on by setting the sync
folder in **one** of two ways (the env var wins):

- Env var `CLAUDE_QUOTA_SYNC_DIR`, or
- a plain-text file `%LOCALAPPDATA%\claude-quota\sync-dir` (same config style as the
  account pin).

The value is either an **explicit path** to the shared folder, or the literal
`auto` to autodetect Google Drive on Windows. `auto` probes, in order:
`%USERPROFILE%\My Drive`, `%USERPROFILE%\Google Drive`, `%USERPROFILE%\Mi unidad`,
`G:\My Drive`, `G:\Mi unidad`, `G:\` — and uses the first that exists, under a
`claude-brain-sync` subfolder. An explicit path is used **verbatim** (no subfolder
appended), so several machines must point at the *same* folder. Empty/unset = off.

How it works (mirrors the mac/linux `claude-quota-fetch` bash+jq exactly, so the
files are interchangeable across platforms):

1. After each fetch, this machine writes its own snapshot `<hostname>.json` =
   `{ machine, updated_at, account, stats }` into the sync folder (atomic write).
2. It reads every `*.json` there, keeps only those whose `account` matches this
   machine's (uuid, else email, else `default`), and merges them by day/model/
   project into `%LOCALAPPDATA%\claude-quota\stats-global.json`.

The combined view drives a toggle in the footer of **Resumen / Modelos / Proyectos**:
**🖥 this machine** vs **☁️ all** (the ☁️ pill shows the machine count when >1). The
toggle appears **only** when `stats-global.json` exists. Chats and per-project
sessions always stay local. Every step is **fail-open**: no cloud folder, a locked
file, or a broken snapshot just leaves the last good state and hides the toggle.

## Uninstall

```powershell
pwsh -File uninstall.ps1             # stop, remove autostart, delete app + cache
pwsh -File uninstall.ps1 -KeepCache  # keep %LOCALAPPDATA%\claude-quota
```

Your Claude Code credentials and transcripts are never touched.

## Development

```powershell
cd windows\src\ClaudeQuota
dotnet build                         # compile
dotnet run                           # run from source (framework-dependent)
dotnet run -- --shot ..\..\..\shots  # render the 3 popup tabs + tray icons to PNG
```

The `--shot <dir>` hook fetches once and renders every popup tab (Límites, Resumen,
Modelos, Proyectos, Chats, Cerebro) and the tray icon (at 16/24/32 px) to PNGs —
the headless way to eyeball the UI without clicking the tray. Source layout:

| File | Role |
|---|---|
| `Program.cs` | entry point, tray host, 10 s poll timer, autostart, popup positioning |
| `QuotaService.cs` | the fetch pipeline (OAuth + transcript parse + ccusage), cache I/O |
| `SyncService.cs` | (e) cross-machine sync: writes `<host>.json`, merges → `stats-global.json` |
| `Models.cs` | `state.json` / `stats.json` / `stats-global.json` / OAuth DTOs |
| `Format.cs` | pctColor, `Fmt.*`, `Rel.*`, prettyModel, palette — ports of main.qml |
| `StatsCompute.cs` | streaks, heatmap cells, model colors |
| `TrayIconRenderer.cs` | the two-row tray bitmap → `Icon` |
| `PopupForm.cs` | the owner-drawn 5-tab popover (incl. the Cerebro tab + update banner) |
| `Updater.cs` | lightweight autoupdate: reads `version.json`, checks GitHub, launches the detached ff-merge + reinstall |

## Notes / differences from Linux & macOS

- **No numeric % or ⟳reset in the tray icon.** The Windows notification area
  renders a *square* icon (the macOS status item and KDE panel are
  variable-width), so a bar + 2–3 digit number × 2 rows won't fit legibly at
  16 px. The two bar lengths carry the glance; the exact numbers live in the
  tooltip and the popup.
- **Light/dark theme** follows `AppsUseLightTheme`; the orange accent is fixed.
- **Cost needs Node.** See the table above — this is the one thing that silently
  degrades to `—` on a machine without Node/ccusage.
- **Token de-duplication.** Claude Code writes one JSONL line per content block of
  an assistant turn, each repeating the same `message.id` and the same cumulative
  `usage`. The parser dedupes by `message.id` (Linux/macOS get this for free from
  ccusage); without it the token counts inflate ~2–3×. "Mensajes" is a deliberate
  exception — it counts raw user/assistant lines, matching the other platforms.

## License

MIT (same as the rest of the repo — a fork of
[fuziontech/claude-quota-widget](https://github.com/fuziontech/claude-quota-widget)).
See [../LICENSE](../LICENSE).
