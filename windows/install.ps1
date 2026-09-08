#!/usr/bin/env pwsh
# Install Cortex Widget (Windows tray widget).
#
# By default DOWNLOADS the precompiled self-contained exe (Cortex.exe) from the rolling
# 'windows-latest' release -> NO .NET SDK needed. Falls back to building from source (dotnet publish)
# if the download fails; -Build forces building. Also falls back to building from source if the
# downloaded exe's 'build-sha' (from the release body) is behind the clon's HEAD and a .NET SDK is
# available (C4, docs/reaudit-ola1-2026-09-01.md) -- otherwise it just warns and keeps the stale exe.
# Installs to %LOCALAPPDATA%\Programs\Cortex, registers autostart, and launches. Re-run any time to
# update in place. Migrates old 'ClaudeQuota'.
#
#   pwsh -File install.ps1            # brain (hooks) + widget, autostart, launch  <- ONE-STOP
#   pwsh -File install.ps1 -Build     # build from source instead (needs .NET SDK)
#   pwsh -File install.ps1 -NoBrain   # skip the brain (hooks); only widget/daemon  (QA / dev)
#   pwsh -File install.ps1 -NoAutostart
#
# PARIDAD con install.sh de Mac/Linux: este instalador es el ONE-STOP (cerebro + widget), sin
# asimetria entre OS. Asi el boton "Actualizar" del widget (que corre ESTE script) deja la maquina
# completa en un clic, igual que en Mac/Linux. -NoBrain lo salta (para QA de solo-widget / la CI usa
# dotnet publish directo, no este script). El boton-curita sigue siendo el self-heal SIN git pull.
[CmdletBinding()]
param(
    [switch]$NoAutostart,
    [switch]$NoLaunch,          # build + install but don't launch (e.g. from an elevated installer)
    [switch]$NoClaudeCode,      # skip auto-installing the Claude Code CLI (the thing the widget measures)
    [switch]$NoBrain,           # skip the Claude-Code brain (hooks/norms); only daemon + widget (paridad con install.sh --no-brain)
    [switch]$Build,             # force build-from-source (dotnet publish) instead of downloading the release exe
    # El broker de terminal es Linux-only (systemd --user + `script` de util-linux + el login shell).
    # Se ACEPTA la bandera solo para poder decir POR QUE no aplica: sin este parametro, invocar
    # `install.ps1 -ConTermBroker` moriria con "A parameter cannot be found", que parece un typo.
    # Ojo: bootstrap.ps1 corre via `irm | iex` y llama a este script SIN argumentos, asi que por esa
    # via la bandera no llega nunca -- no hay forma de pedir el broker desde el one-liner de Windows.
    [switch]$ConTermBroker,
    [string]$Configuration = 'Release'
)

if ($ConTermBroker) {
    Write-Host "==> Aviso: -ConTermBroker es solo para Linux (systemd --user + script/util-linux); se ignora en Windows." -ForegroundColor Yellow
}

$ErrorActionPreference = 'Stop'
$here    = Split-Path -Parent $MyInvocation.MyCommand.Path
$proj    = Join-Path $here 'src\Cortex\Cortex.csproj'
$appName  = 'Cortex'
$dest     = Join-Path $env:LOCALAPPDATA "Programs\$appName"
$exe      = Join-Path $dest "$appName.exe"
$assetUrl = 'https://github.com/unjordi/cortex/releases/download/windows-latest/Cortex.exe'

# -- Cerebro (hooks + normas), salvo -NoBrain -- ONE-STOP igual que install.sh (Mac/Linux): el
# instalador deja cerebro + widget, para que el boton "Actualizar" (que corre este script) actualice
# TODO en un clic. Best-effort: si Git Bash no esta (install-brain.ps1 sale != 0) NO bloquea el widget
# -> paridad de comportamiento con install.sh, que tampoco tumba el widget si el cerebro falla.
if (-not $NoBrain) {
    $brainInstaller = Join-Path $here '..\brain\install-brain.ps1'
    if (Test-Path $brainInstaller) {
        Write-Host "==> Instalando el cerebro (hooks + normas, via Git Bash)..." -ForegroundColor Cyan
        try { & $brainInstaller } catch { Write-Host "==> Aviso: el cerebro no se instalo ($_); sigo con el widget." -ForegroundColor Yellow }
    } else {
        Write-Host "==> Aviso: no encontre $brainInstaller; instalo solo el widget." -ForegroundColor Yellow
    }
}

Write-Host "==> Deteniendo instancia previa (si corre)..." -ForegroundColor Cyan
Get-Process Cortex,ClaudeBrain,ClaudeQuota -ErrorAction SilentlyContinue | Stop-Process -Force
Start-Sleep -Milliseconds 400

New-Item -ItemType Directory -Force -Path $dest | Out-Null

# Migracion desde los nombres viejos: si un install previo dejo 'ClaudeQuota' (era vieja-vieja) o
# 'ClaudeBrain' (era intermedia del rename #312), quita su autostart y su carpeta para no quedar con
# dos widgets/dos entradas tras el rename a Cortex.
foreach ($old in @('ClaudeQuota','ClaudeBrain')) {
    Remove-ItemProperty -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run' -Name $old -ErrorAction SilentlyContinue
    $oldDest = Join-Path $env:LOCALAPPDATA "Programs\$old"
    if (Test-Path $oldDest) { Remove-Item $oldDest -Recurse -Force -ErrorAction SilentlyContinue }
}

# "Borra el previo por completo" (regla 2026-07-15): NO migramos el cache de los nombres viejos; los
# ELIMINAMOS. El install nuevo regenera limpio (machine-id/account/calibracion se re-crean solos).
# 'claude-quota' (era vieja-vieja) y 'claude-brain' (era intermedia del rename #312).
foreach ($oldCacheName in @('claude-quota','claude-brain')) {
    $oldCache = Join-Path $env:LOCALAPPDATA $oldCacheName
    if (Test-Path $oldCache) { Remove-Item $oldCache -Recurse -Force -ErrorAction SilentlyContinue; Write-Host "==> Cache viejo '$oldCacheName' eliminado (install limpio)." -ForegroundColor Green }
}

# Preferimos BAJAR el exe precompilado del release (SIN .NET SDK). Fallback: compilar desde fuente
# (requiere SDK). -Build fuerza compilar (devs). Nota: si el release se esta re-construyendo, la
# descarga puede dar 404 por ~1-2 min -> reintenta, o instala el SDK.
$got = $false
if (-not $Build) {
    Write-Host "==> Bajando el exe precompilado del release 'windows-latest' (sin .NET SDK)..." -ForegroundColor Cyan
    try {
        Invoke-WebRequest -Uri $assetUrl -OutFile $exe -UseBasicParsing
        if ((Test-Path $exe) -and (Get-Item $exe).Length -gt 1000000) {
            $got = $true; Write-Host "    listo ($((Get-Item $exe).Length) bytes)" -ForegroundColor Green
        }
    } catch { Write-Host "    no pude bajar el exe: $($_.Exception.Message)" -ForegroundColor Yellow }
}
if (-not $got) {
    if (-not (Get-Command dotnet -ErrorAction SilentlyContinue)) {
        throw "No pude bajar el exe y no hay .NET SDK para compilar. Reintenta en 1-2 min (el release 'windows-latest' se esta construyendo) o instala el .NET 10 SDK y re-corre."
    }
    Write-Host "==> Compilando desde fuente ($Configuration, self-contained, single-file)..." -ForegroundColor Cyan
    $pub = Join-Path $here 'publish'
    if (Test-Path $pub) { Remove-Item $pub -Recurse -Force }
    dotnet publish $proj -c $Configuration -r win-x64 --self-contained true `
        -p:PublishSingleFile=true -p:IncludeNativeLibrariesForSelfExtract=true `
        -o $pub
    if ($LASTEXITCODE -ne 0) { throw "dotnet publish fallo ($LASTEXITCODE)" }
    Copy-Item (Join-Path $pub "$appName.exe") $exe -Force
}
Write-Host "==> Instalado en $dest" -ForegroundColor Cyan

# Version EMBEBIDA para el autoupdate (winturbo-style), espejo del bloque version.json de
# macos/make-app.sh: el SHA + la fecha del commit con que se buildeo y la ruta del clon, para que
# la app compare contra GitHub y sepa desde donde re-jalar. install.ps1 corre DESDE el repo, asi
# que puede leer git. El repo raiz es el padre de windows/ ($here). Fail-safe: si git no responde,
# quedan valores neutros y el chequeo de la app falla-abierto (no molesta).
$repoRoot = Split-Path -Parent $here

# Sha EFECTIVO que describe el binario que quedo instalado:
#  - compilado desde fuente (-Build / fallback) -> HEAD del clon (es literal lo que se compilo).
#  - DESCARGADO del rolling -> el 'build-sha:' del cuerpo del release, NO el HEAD del clon. El asset
#    'windows-latest' puede ir unos minutos DETRAS de main mientras el runner reconstruye (RACE real,
#    caso Danny): si estamparamos el HEAD del clon, el widget se creeria al dia con un exe viejo (y su
#    cerebro empaquetado viejo contaria hooks de menos -> el "(5)" fantasma). Estampando la VERDAD del
#    asset, si va detras de main el widget lo detecta y ofrece "Actualizar" cuando el runner termine.
#    Paridad con macOS, donde el .app trae su version.json estampado por el CI dentro del bundle.
# Fail-safe: sin red / sin gh-api / clon sin ese commit -> cae al HEAD del clon (comportamiento previo).
$effSha = (git -C $repoRoot rev-parse HEAD 2>$null)
if ($got) {
    try {
        $rel = Invoke-RestMethod "https://api.github.com/repos/unjordi/cortex/releases/tags/windows-latest" `
                 -Headers @{ 'User-Agent' = 'cortex'; 'Accept' = 'application/vnd.github+json' } -UseBasicParsing
        $m = [regex]::Match([string]$rel.body, 'build-sha: ([0-9a-f]+)')
        if ($m.Success -and $m.Groups[1].Value) {
            $effSha = $m.Groups[1].Value
            $headSha = (git -C $repoRoot rev-parse HEAD 2>$null)
            if ($effSha -ne $headSha) {
                Write-Host "==> OJO: el asset 'windows-latest' va detras de main (build-sha $($effSha.Substring(0,7))); el widget lo detectara y ofrecera actualizar cuando el runner reconstruya." -ForegroundColor Yellow
                # C4 (docs/reaudit-ola1-2026-09-01.md): la mitigacion previa (commit cf0a5285) solo
                # avisaba sin cerrar la ventana. La EXTENDEMOS: si hay SDK de .NET, recompilar desde
                # fuente en vez de conformarse con el asset rancio -- mismo patron que el fallback de
                # arriba (linea ~90), reusado aqui para el caso "SI bajo pero va detras de HEAD".
                if (Get-Command dotnet -ErrorAction SilentlyContinue) {
                    Write-Host "    ...compilo desde fuente en su lugar (SDK de .NET disponible)." -ForegroundColor Cyan
                    $pub = Join-Path $here 'publish'
                    if (Test-Path $pub) { Remove-Item $pub -Recurse -Force }
                    dotnet publish $proj -c $Configuration -r win-x64 --self-contained true `
                        -p:PublishSingleFile=true -p:IncludeNativeLibrariesForSelfExtract=true `
                        -o $pub
                    if ($LASTEXITCODE -eq 0) {
                        Copy-Item (Join-Path $pub "$appName.exe") $exe -Force
                        $effSha = $headSha
                        Write-Host "    listo: exe recompilado desde HEAD ($($effSha.Substring(0,7)))." -ForegroundColor Green
                    } else {
                        Write-Host "    dotnet publish fallo ($LASTEXITCODE); me quedo con el exe descargado (quedara pendiente hasta que el runner alcance)." -ForegroundColor Yellow
                    }
                } else {
                    Write-Host "    sin .NET SDK no puedo compilar; me quedo con el exe descargado (el widget ofrecera 'Actualizar' cuando el runner alcance)." -ForegroundColor Yellow
                }
            }
        }
    } catch { Write-Host "    (no pude leer el build-sha del release; estampo el HEAD del clon)" -ForegroundColor DarkYellow }
}
$sha    = if ($effSha) { $effSha.Substring(0, [Math]::Min(7, $effSha.Length)) } else { 'unknown' }
$date   = (git -C $repoRoot show -s --format=%cI $effSha 2>$null); if (-not $date) { $date = '' }
$branch = (git -C $repoRoot rev-parse --abbrev-ref HEAD 2>$null); if (-not $branch) { $branch = '' }

# Version LEGIBLE que INCREMENTA: MAJOR.MINOR (de brain/VERSION) . <conteo de commits>, p.ej.
# "0.1.176". Robusto: toma solo los PRIMEROS DOS componentes punteados de brain/VERSION (da igual
# si dice "0.1.0" o "0.1"); el conteo de commits (git rev-list --count) es el tercer numero y sube
# con cada commit. Espejo del esquema del lado macOS/brain. NO se edita brain/VERSION, solo se lee.
# Fail-safe: sin brain/VERSION o sin git -> cae a "0.0" / count 0 sin romper el install.
$prefix = '0.0'
$brainVerFile = Join-Path $repoRoot 'brain/VERSION'
if (Test-Path $brainVerFile) {
    $raw = (Get-Content $brainVerFile -Raw -ErrorAction SilentlyContinue)
    if ($raw) {
        $parts = ($raw.Trim() -split '\.')
        if     ($parts.Count -ge 2) { $prefix = "$($parts[0]).$($parts[1])" }
        elseif ($parts.Count -eq 1 -and $parts[0]) { $prefix = "$($parts[0]).0" }
    }
}
# Conteo de commits del sha EFECTIVO (el del asset si se descargo), no de HEAD -> la version legible
# no sobrepasa al binario real. Fail-safe: si el clon no tiene ese commit, cae a HEAD y luego a 0.
$count = (git -C $repoRoot rev-list --count $effSha 2>$null)
if (-not $count) { $count = (git -C $repoRoot rev-list --count HEAD 2>$null) }
if (-not $count) { $count = '0' }
$version_str = "$prefix.$($count.ToString().Trim())"

$version = [ordered]@{ version = $version_str; sha = $sha; date = $date; repo = $repoRoot; branch = $branch }
$version | ConvertTo-Json -Compress | Set-Content -Path (Join-Path $dest 'version.json') -Encoding utf8
Write-Host "==> version.json embebido (v$version_str, sha $sha, rama $branch) para el autoupdate." -ForegroundColor Green

# Empaqueta el cerebro (brain/) JUNTO al exe para que el boton-curita de la pestana Cerebro
# pueda correr install-brain.ps1 sin depender de donde este el clon del repo. El boton lo busca
# en <AppDir>\brain\install-brain.ps1 (relativo a AppContext.BaseDirectory).
$brainSrc = Join-Path $here '..\brain'
if (Test-Path $brainSrc) {
    $brainDst = Join-Path $dest 'brain'
    if (Test-Path $brainDst) { Remove-Item $brainDst -Recurse -Force }
    Copy-Item $brainSrc $brainDst -Recurse -Force
    Write-Host "==> Cerebro (brain/) empaquetado junto al app (para el boton-curita)." -ForegroundColor Green
} else {
    Write-Host "==> Aviso: no encontre brain/ en $brainSrc; el boton-curita no tendra instalador." -ForegroundColor Yellow
}

# Empaqueta los helpers de node (bin/*.js) JUNTO al exe (en <AppDir>\bin) para que el servicio
# los pueda invocar. chats/sessions-extract producen chats.json / sessions.json (pestana Chats +
# "resumir" de Proyectos) leyendo el cache local; session-move.js lo invoca la GUI al "Mover a...".
# Igual que en mac/linux. Requisito: 'node' en el PATH (fail-open: sin node no se generan y esas
# piezas quedan vacias). El servicio los busca en AppContext.BaseDirectory\bin.
$binSrc = Join-Path $repoRoot 'bin'
if (Test-Path $binSrc) {
    $binDst = Join-Path $dest 'bin'
    New-Item -ItemType Directory -Force -Path $binDst | Out-Null
    # session-lib.js = helpers compartidos que require()an move/export/import; claude-session = wrapper
    # bash del sync cross-maquina (corre bajo Git Bash). Ver diseno-sync-sesiones.md.
    foreach ($js in @('chats-extract.js', 'sessions-extract.js', 'session-move.js', 'session-lib.js', 'session-export.js', 'session-import.js', 'claude-session')) {
        $srcJs = Join-Path $binSrc $js
        if (Test-Path $srcJs) { Copy-Item $srcJs (Join-Path $binDst $js) -Force }
    }
    Write-Host "==> Helpers de node (chats/sessions/move/export/import) + claude-session empaquetados en $binDst (requieren node; claude-session corre bajo Git Bash)." -ForegroundColor Green
} else {
    Write-Host "==> Aviso: no encontre bin/ en $binSrc; no habra chats.json/sessions.json." -ForegroundColor Yellow
}

$runKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'
if ($NoAutostart) {
    Remove-ItemProperty -Path $runKey -Name $appName -ErrorAction SilentlyContinue
    Write-Host "==> Autoarranque: desactivado" -ForegroundColor Yellow
} else {
    New-ItemProperty -Path $runKey -Name $appName -Value "`"$exe`"" -PropertyType String -Force | Out-Null
    Write-Host "==> Autoarranque: activado (inicia con Windows)" -ForegroundColor Green
}

# Acceso directo en el menu Inicio -> se re-abre tecleando "Cortex" (si la cierras, tray app sin
# ventana no deja como reinvocarla). Usa WScript.Shell (sin deps). Migra un .lnk viejo con el otro nombre.
$startMenu = [Environment]::GetFolderPath('Programs')   # %APPDATA%\...\Start Menu\Programs
Remove-Item (Join-Path $startMenu 'Claude Quota.lnk') -ErrorAction SilentlyContinue   # nombre viejo-viejo (migracion)
Remove-Item (Join-Path $startMenu 'Claude Brain.lnk') -ErrorAction SilentlyContinue   # era intermedia claude-brain (#312)
try {
    $lnk = Join-Path $startMenu 'Cortex.lnk'
    $ws  = New-Object -ComObject WScript.Shell
    $sc  = $ws.CreateShortcut($lnk)
    $sc.TargetPath       = $exe
    $sc.WorkingDirectory = $dest
    $sc.IconLocation     = $exe        # el mismo icono del exe
    $sc.Description       = 'Cortex Widget'
    $sc.Save()
    Write-Host "==> Acceso directo en el menu Inicio: 'Cortex'." -ForegroundColor Green
} catch {
    Write-Host "==> Aviso: no pude crear el acceso directo del menu Inicio ($($_.Exception.Message))." -ForegroundColor Yellow
}

if ($NoLaunch) {
    Write-Host "==> Instalado (sin lanzar; arranca en el proximo inicio de sesion)." -ForegroundColor Cyan
} else {
    Write-Host "==> Lanzando..." -ForegroundColor Cyan
    Start-Process $exe
}

Write-Host ""
Write-Host "Listo. El icono de 2 barras (5h / 7d) aparece en la bandeja." -ForegroundColor Green
Write-Host "Clic izquierdo = popup de 4 pestanas | clic derecho = menu (Actualizar / Salir)." -ForegroundColor Green
Write-Host ""
Write-Host "Nota: los tokens/sesiones/hora pico salen de tus transcripts locales." -ForegroundColor DarkGray
Write-Host "El costo `$ (API-equiv) requiere Node + ccusage en el PATH; si no, sale '-'." -ForegroundColor DarkGray

# -- Claude Code CLI: es lo que el widget MIDE -> asegurarlo (instalador nativo, se auto-actualiza) --
# El widget lee el token OAuth (~/.claude/.credentials.json) y los transcripts que escribe el CLI
# 'claude'. Sin el CLI no hay que medir. OJO: la app de ESCRITORIO tambien registra un claude.exe
# (AppData\Local\AnthropicClaude\claude.exe) que resuelve por 'claude' pero NO escribe .credentials.json
# ni transcripts como la CLI -> hay que detectar/asegurar la CLI ESPECIFICAMENTE, no cualquier 'claude'.
# (Caso real: Windows "Asistente Dir": la app tapaba a la CLI de .local\bin en el PATH -> OAuth sin
# credenciales; y el instalador, al ver la app con Get-Command claude, creia que la CLI ya estaba y se
# saltaba exponer .local\bin.)
function Resolve-ClaudeCli {
    # 1) el binario nativo tipico (lo que deja https://claude.ai/install.ps1)
    $native = "$env:USERPROFILE\.local\bin\claude.exe"
    if (Test-Path $native) { return $native }
    # 2) cualquier claude.exe del PATH que NO sea la app de escritorio
    Get-Command claude -All -ErrorAction SilentlyContinue |
        Where-Object { $_.Source -and $_.Source -notmatch 'AnthropicClaude' } |
        Select-Object -First 1 -ExpandProperty Source
}

$cli = $null
if (-not $NoClaudeCode) {
    $cli = Resolve-ClaudeCli
    if ($cli) {
        Write-Host ""
        Write-Host "==> Claude Code (CLI) ya esta instalado: $cli" -ForegroundColor Green
    } else {
        Write-Host ""
        Write-Host "==> Instalando Claude Code (CLI) -- es lo que el widget mide (instalador nativo)..." -ForegroundColor Cyan
        try { Invoke-RestMethod https://claude.ai/install.ps1 | Invoke-Expression }
        catch { Write-Host "    No pude instalarlo automaticamente; hazlo a mano: irm https://claude.ai/install.ps1 | iex" -ForegroundColor Yellow }
        $cli = Resolve-ClaudeCli
    }
    # Poner el DIR de la CLI AL FRENTE del PATH de usuario (prepend), para que 'claude' gane a la app de
    # escritorio (que tambien registra claude.exe). Paridad con install.sh en Linux, que expone
    # ~/.local/bin en el PATH. Prepend (no append) porque la app suele estar ya en el PATH.
    if ($cli) {
        $cdir = Split-Path $cli
        $u = [Environment]::GetEnvironmentVariable('PATH','User'); if (-not $u) { $u = '' }
        $parts = @($u -split ';' | Where-Object { $_ -ne '' -and $_ -ne $cdir })
        $newU = (@($cdir) + $parts) -join ';'
        if ($newU -ne $u) {
            [Environment]::SetEnvironmentVariable('PATH', $newU, 'User')
            Write-Host "==> Puse '$cdir' (CLI) al frente del PATH de usuario (gana a la app de escritorio)." -ForegroundColor Green
        }
        # visible ya en ESTA sesion, tambien al frente
        $sess = @($env:PATH -split ';' | Where-Object { $_ -ne '' -and $_ -ne $cdir })
        $env:PATH = (@($cdir) + $sess) -join ';'
    }
}

# Recordatorio de login contra la CLI ESPECIFICA (no la app que resuelva 'claude').
if ($cli) {
    & $cli auth status *> $null
    if ($LASTEXITCODE -ne 0) {
        Write-Host ""
        Write-Host "IMPORTANTE: inicia sesion en Claude Code para que el widget muestre tu cuota real:" -ForegroundColor Yellow
        Write-Host "  claude        (luego /login con tu cuenta)" -ForegroundColor Yellow
    }
} else {
    Write-Host ""
    Write-Host "NOTA: la CLI 'claude' aun no esta lista -> abre una terminal NUEVA y corre:" -ForegroundColor Yellow
    Write-Host "  claude        (y /login, para que el widget vea tu cuota real)" -ForegroundColor Yellow
}
