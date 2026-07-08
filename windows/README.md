# Claude Quota — Windows tray app

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
    the slug is mapped back to a readable name via `~/.claude.json`.
- **Right-click → menu:** Actualizar ahora · Iniciar con Windows (toggle) · Salir.

## Why a rewrite (not a port of the fetch script)

Linux and macOS run a bash `claude-quota-fetch` script on a systemd/launchd timer
that writes a cache file the UI reads. Windows has no bash/jq/curl by default, so
the always-running tray app **does the fetch itself in C#** every 5 minutes:

```
┌───────────────────────────────────────────────┐
│  ClaudeQuota.exe (WinForms tray, always on)     │
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

Without Node/ccusage, everything works **except** the `$` figures (they show `—`).
The percentages are exact and come straight from Anthropic; the tokens are parsed
from the same JSONL transcripts ccusage would read, so the Resumen/Modelos tabs
are fully populated on any machine — Node just adds the cost overlay.

The `$` values are **API-equivalent** cost (what pay-per-token would have cost),
labeled "(API equiv local)" — a "how much is my subscription saving me?" signal,
not an invoice. They're local to this machine's transcripts.

## Install

**Self-contained (pulls its own deps via winget — recommended):**

```powershell
irm https://raw.githubusercontent.com/unjordi/claude-brain/main/bootstrap.ps1 | iex
```

`bootstrap.ps1` winget-installs anything missing (Git — brings Git Bash, jq, .NET 10 SDK, Node),
clones the repo to `%USERPROFILE%\claude-brain`, and runs the brain + widget installers. If winget
just installed something, open a fresh terminal and re-run so the new `PATH` is visible. **Or by
hand** from the repo:

```powershell
cd windows
pwsh -File install.ps1              # build, install, autostart, launch
pwsh -File install.ps1 -NoAutostart # skip the "start with Windows" registration
```

`install.ps1` publishes a **self-contained, single-file `.exe`** (bundles the .NET
runtime — no install needed on the target), copies it to
`%LOCALAPPDATA%\Programs\ClaudeQuota\ClaudeQuota.exe`, sets the `HKCU\…\Run`
autostart entry, and launches it. Re-run any time to update in place.

**Build prerequisite:** [.NET 10 SDK](https://dotnet.microsoft.com/download).

## Autoupdate ligero (winturbo-style)

Igual que el puerto macOS, `install.ps1` escribe un `version.json` **junto al exe**
(`%LOCALAPPDATA%\Programs\ClaudeQuota\version.json`) con el `sha`, la `date`, la ruta del
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

The `--shot <dir>` hook fetches once and renders each popup tab and the tray icon
(at 16/24/32 px) to PNGs — the headless way to eyeball the UI without clicking the
tray. Source layout:

| File | Role |
|---|---|
| `Program.cs` | entry point, tray host, 10 s poll timer, autostart, popup positioning |
| `QuotaService.cs` | the fetch pipeline (OAuth + transcript parse + ccusage), cache I/O |
| `Models.cs` | `state.json` / `stats.json` / OAuth DTOs |
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
