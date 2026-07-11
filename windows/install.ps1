#!/usr/bin/env pwsh
# Install Claude Brain Widget (Windows tray widget).
#
# By default DOWNLOADS the precompiled self-contained exe (ClaudeBrain.exe) from the rolling
# 'windows-latest' release -> NO .NET SDK needed. Falls back to building from source (dotnet publish)
# if the download fails; -Build forces building. Installs to %LOCALAPPDATA%\Programs\ClaudeBrain,
# registers autostart, and launches. Re-run any time to update in place. Migrates old 'ClaudeQuota'.
#
#   pwsh -File install.ps1            # download exe, install, autostart, launch
#   pwsh -File install.ps1 -Build     # build from source instead (needs .NET SDK)
#   pwsh -File install.ps1 -NoAutostart
#
[CmdletBinding()]
param(
    [switch]$NoAutostart,
    [switch]$NoLaunch,          # build + install but don't launch (e.g. from an elevated installer)
    [switch]$NoClaudeCode,      # skip auto-installing the Claude Code CLI (the thing the widget measures)
    [switch]$Build,             # force build-from-source (dotnet publish) instead of downloading the release exe
    [string]$Configuration = 'Release'
)

$ErrorActionPreference = 'Stop'
$here    = Split-Path -Parent $MyInvocation.MyCommand.Path
$proj    = Join-Path $here 'src\ClaudeQuota\ClaudeQuota.csproj'
$appName  = 'ClaudeBrain'
$dest     = Join-Path $env:LOCALAPPDATA "Programs\$appName"
$exe      = Join-Path $dest "$appName.exe"
$assetUrl = 'https://github.com/unjordi/claude-brain/releases/download/windows-latest/ClaudeBrain.exe'

Write-Host "==> Deteniendo instancia previa (si corre)..." -ForegroundColor Cyan
Get-Process ClaudeBrain,ClaudeQuota -ErrorAction SilentlyContinue | Stop-Process -Force
Start-Sleep -Milliseconds 400

New-Item -ItemType Directory -Force -Path $dest | Out-Null

# Migracion desde el nombre viejo: si un install previo dejo 'ClaudeQuota', quita su autostart y su
# carpeta para no quedar con dos widgets/dos entradas tras el rename a ClaudeBrain.
Remove-ItemProperty -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run' -Name 'ClaudeQuota' -ErrorAction SilentlyContinue
$oldDest = Join-Path $env:LOCALAPPDATA 'Programs\ClaudeQuota'
if (Test-Path $oldDest) { Remove-Item $oldDest -Recurse -Force -ErrorAction SilentlyContinue }

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
$sha    = (git -C $repoRoot rev-parse --short HEAD 2>$null); if (-not $sha)    { $sha = 'unknown' }
$date   = (git -C $repoRoot show -s --format=%cI HEAD 2>$null); if (-not $date) { $date = '' }
$branch = (git -C $repoRoot rev-parse --abbrev-ref HEAD 2>$null); if (-not $branch) { $branch = '' }
$version = [ordered]@{ sha = $sha; date = $date; repo = $repoRoot; branch = $branch }
$version | ConvertTo-Json -Compress | Set-Content -Path (Join-Path $dest 'version.json') -Encoding utf8
Write-Host "==> version.json embebido (sha $sha, rama $branch) para el autoupdate." -ForegroundColor Green

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
    foreach ($js in @('chats-extract.js', 'sessions-extract.js', 'session-move.js')) {
        $srcJs = Join-Path $binSrc $js
        if (Test-Path $srcJs) { Copy-Item $srcJs (Join-Path $binDst $js) -Force }
    }
    Write-Host "==> Helpers de node (chats/sessions/move) empaquetados en $binDst (requieren node)." -ForegroundColor Green
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

# Acceso directo en el menu Inicio -> se re-abre tecleando "Claude Brain" (si la cierras, tray app sin
# ventana no deja como reinvocarla). Usa WScript.Shell (sin deps). Migra un .lnk viejo con el otro nombre.
$startMenu = [Environment]::GetFolderPath('Programs')   # %APPDATA%\...\Start Menu\Programs
Remove-Item (Join-Path $startMenu 'Claude Quota.lnk') -ErrorAction SilentlyContinue   # nombre viejo (migracion)
try {
    $lnk = Join-Path $startMenu 'Claude Brain.lnk'
    $ws  = New-Object -ComObject WScript.Shell
    $sc  = $ws.CreateShortcut($lnk)
    $sc.TargetPath       = $exe
    $sc.WorkingDirectory = $dest
    $sc.IconLocation     = $exe        # el mismo icono del exe
    $sc.Description       = 'Claude Brain Widget'
    $sc.Save()
    Write-Host "==> Acceso directo en el menu Inicio: 'Claude Brain'." -ForegroundColor Green
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
# El widget lee el token OAuth y los transcripts que escribe el CLI 'claude'. Sin el CLI no hay que medir.
if (-not $NoClaudeCode) {
    if (Get-Command claude -ErrorAction SilentlyContinue) {
        Write-Host ""
        Write-Host "==> Claude Code (CLI) ya esta instalado." -ForegroundColor Green
    } else {
        Write-Host ""
        Write-Host "==> Instalando Claude Code (CLI) -- es lo que el widget mide (instalador nativo)..." -ForegroundColor Cyan
        try { Invoke-RestMethod https://claude.ai/install.ps1 | Invoke-Expression }
        catch { Write-Host "    No pude instalarlo automaticamente; hazlo a mano: irm https://claude.ai/install.ps1 | iex" -ForegroundColor Yellow }
    }
    # Asegurar 'claude' en el PATH de usuario: el instalador nativo deja claude.exe pero su cambio de
    # PATH no siempre aplica (ni en esta sesion ni de forma persistente confiable). Lo buscamos en los
    # lugares tipicos y agregamos su bin al PATH de USUARIO (como Git\bin en install-brain.ps1) para
    # que el usuario pueda hacer 'claude' -> /login y el widget lea el token. (Caso real: Windows de Liora.)
    if (-not (Get-Command claude -ErrorAction SilentlyContinue)) {
        $roots = @("$env:LOCALAPPDATA", "$env:USERPROFILE\.local", "$env:USERPROFILE\.claude", "$env:APPDATA\npm") | Where-Object { Test-Path $_ }
        $found = Get-ChildItem $roots -Recurse -Filter "claude.exe" -ErrorAction SilentlyContinue -Depth 4 |
                 Select-Object -First 1 -ExpandProperty FullName
        if ($found) {
            $cdir = Split-Path $found
            $u = [Environment]::GetEnvironmentVariable('PATH','User'); if (-not $u) { $u = '' }
            if (($u -split ';') -notcontains $cdir) {
                [Environment]::SetEnvironmentVariable('PATH', $u.TrimEnd(';') + ';' + $cdir, 'User')
                $env:PATH = $env:PATH.TrimEnd(';') + ';' + $cdir   # visible ya en esta sesion
                Write-Host "==> Agregue '$cdir' (claude) al PATH de usuario." -ForegroundColor Green
            }
        }
    }
}

# Recordatorio de login (interactivo y por-usuario: el script NO puede hacerlo por ti).
$cc = Get-Command claude -ErrorAction SilentlyContinue
if ($cc) {
    & $cc.Source auth status *> $null
    if ($LASTEXITCODE -ne 0) {
        Write-Host ""
        Write-Host "IMPORTANTE: inicia sesion en Claude Code para que el widget muestre tu cuota real:" -ForegroundColor Yellow
        Write-Host "  claude        (luego /login con tu cuenta)" -ForegroundColor Yellow
    }
} else {
    Write-Host ""
    Write-Host "NOTA: 'claude' aun no esta en el PATH (instalacion nueva) -> abre una terminal NUEVA y corre:" -ForegroundColor Yellow
    Write-Host "  claude        (y /login, para que el widget vea tu cuota real)" -ForegroundColor Yellow
}
