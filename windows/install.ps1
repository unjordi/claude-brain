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
