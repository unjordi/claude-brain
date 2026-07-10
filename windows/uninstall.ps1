#!/usr/bin/env pwsh
# Uninstall Claude Brain Widget (Windows): stop it, drop autostart, remove the app and
# its cache. Also cleans up the old 'ClaudeQuota' name if a previous install left it.
# Leaves your Claude Code credentials/transcripts untouched.
#
#   pwsh -File uninstall.ps1
#   pwsh -File uninstall.ps1 -KeepCache
#
[CmdletBinding()]
param([switch]$KeepCache)

$ErrorActionPreference = 'SilentlyContinue'
$cache   = Join-Path $env:LOCALAPPDATA 'claude-quota'   # dir de cache interno (id sin renombrar)
$runKey  = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'

Write-Host "==> Deteniendo..." -ForegroundColor Cyan
Get-Process ClaudeBrain,ClaudeQuota | Stop-Process -Force
Start-Sleep -Milliseconds 400

Write-Host "==> Quitando autoarranque..." -ForegroundColor Cyan
Remove-ItemProperty -Path $runKey -Name 'ClaudeBrain'
Remove-ItemProperty -Path $runKey -Name 'ClaudeQuota'   # nombre viejo (migracion)

foreach ($n in @('ClaudeBrain','ClaudeQuota')) {
    $d = Join-Path $env:LOCALAPPDATA "Programs\$n"
    if (Test-Path $d) { Write-Host "==> Borrando $d ..." -ForegroundColor Cyan; Remove-Item $d -Recurse -Force }
}

if (-not $KeepCache) {
    Write-Host "==> Borrando cache $cache ..." -ForegroundColor Cyan
    Remove-Item $cache -Recurse -Force
}

Write-Host "Desinstalado." -ForegroundColor Green
