#!/usr/bin/env pwsh
# Build + install Claude Quota (Windows tray widget).
#
# Publishes a self-contained single-file exe (no .NET runtime needed on the
# target), copies it to %LOCALAPPDATA%\Programs\ClaudeQuota, registers it to
# start with Windows, and launches it. Re-run any time to update in place.
#
#   pwsh -File install.ps1            # build, install, autostart, launch
#   pwsh -File install.ps1 -NoAutostart
#
[CmdletBinding()]
param(
    [switch]$NoAutostart,
    [switch]$NoLaunch,          # build + install but don't launch (e.g. from an elevated installer)
    [string]$Configuration = 'Release'
)

$ErrorActionPreference = 'Stop'
$here    = Split-Path -Parent $MyInvocation.MyCommand.Path
$proj    = Join-Path $here 'src\ClaudeQuota\ClaudeQuota.csproj'
$appName = 'ClaudeQuota'
$dest    = Join-Path $env:LOCALAPPDATA "Programs\$appName"
$exe     = Join-Path $dest "$appName.exe"

Write-Host "==> Deteniendo instancia previa (si corre)..." -ForegroundColor Cyan
Get-Process $appName -ErrorAction SilentlyContinue | Stop-Process -Force
Start-Sleep -Milliseconds 400

Write-Host "==> Publicando ($Configuration, self-contained, single-file)..." -ForegroundColor Cyan
$pub = Join-Path $here 'publish'
if (Test-Path $pub) { Remove-Item $pub -Recurse -Force }
dotnet publish $proj -c $Configuration -r win-x64 --self-contained true `
    -p:PublishSingleFile=true -p:IncludeNativeLibrariesForSelfExtract=true `
    -o $pub
if ($LASTEXITCODE -ne 0) { throw "dotnet publish falló ($LASTEXITCODE)" }

Write-Host "==> Instalando en $dest ..." -ForegroundColor Cyan
New-Item -ItemType Directory -Force -Path $dest | Out-Null
Copy-Item (Join-Path $pub "$appName.exe") $exe -Force

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

# Empaqueta el cerebro (brain/) JUNTO al exe para que el boton-curita 🩹 de la pestaña Cerebro
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

$runKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'
if ($NoAutostart) {
    Remove-ItemProperty -Path $runKey -Name $appName -ErrorAction SilentlyContinue
    Write-Host "==> Autoarranque: desactivado" -ForegroundColor Yellow
} else {
    New-ItemProperty -Path $runKey -Name $appName -Value "`"$exe`"" -PropertyType String -Force | Out-Null
    Write-Host "==> Autoarranque: activado (inicia con Windows)" -ForegroundColor Green
}

if ($NoLaunch) {
    Write-Host "==> Instalado (sin lanzar; arranca en el proximo inicio de sesion)." -ForegroundColor Cyan
} else {
    Write-Host "==> Lanzando..." -ForegroundColor Cyan
    Start-Process $exe
}

Write-Host ""
Write-Host "Listo. El icono de 2 barras (5h / 7d) aparece en la bandeja." -ForegroundColor Green
Write-Host "Clic izquierdo = popup de 4 pestañas · clic derecho = menú (Actualizar / Salir)." -ForegroundColor Green
Write-Host ""
Write-Host "Nota: los tokens/sesiones/hora pico salen de tus transcripts locales." -ForegroundColor DarkGray
Write-Host "El costo `$ (API-equiv) requiere Node + ccusage en el PATH; si no, sale '—'." -ForegroundColor DarkGray
