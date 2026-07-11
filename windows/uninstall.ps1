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
$cache   = Join-Path $env:LOCALAPPDATA 'claude-brain'    # dir de cache interno (state/stats/machine-id/account)
$cacheOld = Join-Path $env:LOCALAPPDATA 'claude-quota'   # nombre viejo del cache (migracion): se limpia igual
$runKey  = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'

Write-Host "==> Deteniendo..." -ForegroundColor Cyan
Get-Process ClaudeBrain,ClaudeQuota | Stop-Process -Force
Start-Sleep -Milliseconds 400

Write-Host "==> Quitando autoarranque..." -ForegroundColor Cyan
Remove-ItemProperty -Path $runKey -Name 'ClaudeBrain'
Remove-ItemProperty -Path $runKey -Name 'ClaudeQuota'   # nombre viejo (migracion)

Write-Host "==> Quitando acceso directo del menu Inicio..." -ForegroundColor Cyan
$startMenu = [Environment]::GetFolderPath('Programs')
Remove-Item (Join-Path $startMenu 'Claude Brain.lnk') -Force
Remove-Item (Join-Path $startMenu 'Claude Quota.lnk') -Force   # nombre viejo

foreach ($n in @('ClaudeBrain','ClaudeQuota')) {
    $d = Join-Path $env:LOCALAPPDATA "Programs\$n"
    if (Test-Path $d) { Write-Host "==> Borrando $d ..." -ForegroundColor Cyan; Remove-Item $d -Recurse -Force }
}

if (-not $KeepCache) {
    Write-Host "==> Borrando cache $cache ..." -ForegroundColor Cyan
    Remove-Item $cache -Recurse -Force
    Remove-Item $cacheOld -Recurse -Force   # nombre viejo (migracion): por si un install previo lo dejo
}

Write-Host "Desinstalado." -ForegroundColor Green
