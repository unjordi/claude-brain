#!/usr/bin/env pwsh
# install-brain.ps1 - lanzador DELGADO de Windows para el instalador del cerebro (claude-brain).
# Los hooks del cerebro corren bajo BASH en TODAS las plataformas (decision "bash en todos lados",
# sin drift .sh/.ps1). En Windows eso lo provee Git Bash (viene con Git for Windows). Este script
# NO reimplementa la logica: solo verifica bash + jq y delega en `bash brain/install-brain.sh`,
# que es idempotente y hace todo el trabajo real (hooks, cableado, skill, dashboard, normas).
# Correr tras clonar:  pwsh -File brain\install-brain.ps1
$ErrorActionPreference = 'Continue'

# -- Dependencia dura: GIT BASH (NO el bash de WSL) --
# OJO: `Get-Command bash` en una maquina con WSL devuelve C:\Windows\System32\bash.exe (el lanzador
# de WSL), que NO entiende rutas Windows (C:/... no existe en WSL, seria /mnt/c/...) ni trae las
# herramientas del cerebro (jq, etc.) -> el instalador fallaba con "No such file or directory" y
# "jq no disponible" (bug real Windows+WSL, 2026-07-20). Por eso buscamos PRIMERO el bash.exe de Git
# for Windows en sus ubicaciones conocidas, y solo caemos al 'bash' del PATH si NO es el de System32.
$bash = $null
foreach ($p in @("$env:ProgramFiles\Git\bin\bash.exe","${env:ProgramFiles(x86)}\Git\bin\bash.exe","$env:LOCALAPPDATA\Programs\Git\bin\bash.exe")) {
  if (Test-Path $p) { $bash = $p; break }
}
if (-not $bash) {
  $cmd = Get-Command bash -ErrorAction SilentlyContinue
  # Ignora el bash de WSL (System32\bash.exe): no sirve para los hooks del cerebro.
  if ($cmd -and $cmd.Source -and ($cmd.Source -notlike "*\System32\*")) { $bash = $cmd.Source }
}
if (-not $bash) {
  Write-Host "ERROR: no encuentro Git Bash. Los hooks del cerebro corren bajo bash (Git Bash, NO WSL)."
  Write-Host "  En Windows instala Git for Windows (trae Git Bash):  winget install Git.Git"
  Write-Host "  (Si 'bash' te resuelve al de WSL en System32, este instalador ahora lo ignora a proposito.)"
  Write-Host "  Luego re-corre: pwsh -File brain\install-brain.ps1"
  exit 1
}
$bashExe = $bash

# -- PATH: asegurar que 'bash' quede en el PATH de USUARIO (persistente) --
# Git for Windows / winget ponen git.exe (Git\cmd) en el PATH, pero NO bash.exe (vive en Git\bin).
# Claude Code corre los hooks con "shell":"bash" -> si bash no esta en el PATH, los guardrails NO
# aplican. Anadimos Git\bin (bash.exe) al PATH de usuario; NO anadimos Git\usr\bin (evita que
# find/sort de Unix ensombrezcan los de Windows) - bash resuelve sus coreutils solo al arrancar.
$gitBin = Split-Path -Parent $bashExe
$userPath = [Environment]::GetEnvironmentVariable('PATH','User')
if ($null -eq $userPath) { $userPath = '' }
if (($userPath -split ';') -notcontains $gitBin) {
  Write-Host "==> claude-brain: agrego '$gitBin' al PATH de usuario (Claude Code necesita 'bash' para los hooks)"
  [Environment]::SetEnvironmentVariable('PATH', ($userPath.TrimEnd(';') + ';' + $gitBin), 'User')
  $env:PATH = $env:PATH.TrimEnd(';') + ';' + $gitBin   # visible ya en esta sesion
  $script:pathChanged = $true
}

# -- Auto-sanar CRLF: Git for Windows (core.autocrlf=true) clona los .sh con CRLF y bash muere con el \r --
# El .gitattributes del repo lo previene en clones FUTUROS, pero un clon ya existente (o con config
# rara) sigue con CRLF. Aqui quitamos los CR (byte 0x0D) de TODO .sh del repo antes de correr bash,
# byte a byte para no meter BOM ni tocar la codificacion. Idempotente (si ya esta en LF, no hace nada).
$RepoRoot = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$fixed = 0
Get-ChildItem -Path $RepoRoot -Recurse -Filter *.sh -File -ErrorAction SilentlyContinue | ForEach-Object {
  $bytes = [IO.File]::ReadAllBytes($_.FullName)
  if ($bytes -contains 13) {
    [IO.File]::WriteAllBytes($_.FullName, [byte[]]($bytes | Where-Object { $_ -ne 13 }))
    $fixed++
  }
}
if ($fixed -gt 0) { Write-Host "==> claude-brain: normalice a LF $fixed script(s) .sh que venian con CRLF (fix Git-for-Windows)" }

# -- Dependencia de los hooks: jq (sin jq los guards fallan abierto y no puedo cablear settings.json) --
# jq lo instala winget en %LOCALAPPDATA%\Microsoft\WinGet\Links (u otra carpeta): ese dir SI esta en el
# PATH de Windows y PowerShell lo ve, pero un bash de LOGIN (-l) reconstruye su PATH desde /etc/profile
# y puede NO incluirlo. Resolvemos jq desde PowerShell y prependemos su carpeta a $env:PATH del proceso,
# para que el bash hijo (que hereda este PATH) lo vea igual que PowerShell. Verificamos con un bash
# NO-login (-c), el MISMO modo con que abajo corre install-brain.sh (el check refleja el run).
$jqCmd = Get-Command jq -ErrorAction SilentlyContinue
if ($jqCmd) {
  $jqDir = Split-Path -Parent $jqCmd.Source
  if (($env:PATH -split ';') -notcontains $jqDir) { $env:PATH = $jqDir + ';' + $env:PATH }
}
& $bashExe -c "command -v jq >/dev/null 2>&1"
if ($LASTEXITCODE -ne 0) {
  Write-Host "ADVERTENCIA: 'jq' no esta disponible en bash. Los hooks lo REQUIEREN (sin jq el"
  Write-Host "  git-branch-guard falla abierto y el instalador no cablea el settings.json)."
  Write-Host "  Instalalo: winget install jqlang.jq  (o choco/scoop install jq)"
}

# -- Delegar TODO el trabajo real al instalador .sh (fuente unica, idempotente) --
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$Installer = Join-Path $ScriptDir 'install-brain.sh'
if (-not (Test-Path $Installer)) {
  Write-Host "ERROR: no encuentro el instalador $Installer"
  exit 1
}
Write-Host "==> claude-brain: delegando en bash $Installer"
# Pasar la ruta a bash con '/' (NO '\'): bash lee cada '\U','\A','\L'... de una ruta Windows como
# secuencia de escape y se COME los backslashes -> "No such file or directory" y el instalador real
# nunca corre (bug real en Windows, 2026-07-20). Una ruta con forward-slashes (C:/Users/.../
# install-brain.sh) la entiende Git Bash sin ambiguedad.
& $bashExe ($Installer -replace '\\','/')
$rc = $LASTEXITCODE
if ($script:pathChanged) {
  Write-Host ""
  Write-Host "NOTA: agregue 'bash' al PATH de usuario. Para que Claude Code (y tu terminal) lo vean,"
  Write-Host "  ABRE UNA TERMINAL NUEVA (o reinicia Claude Code). En la actual ya quedo disponible."
}
exit $rc
