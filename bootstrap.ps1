# bootstrap.ps1 - instalador AUTOCONTENIDO de claude-brain para Windows.
# Un solo comando (jala los prereqs con winget; no necesitas nada preinstalado salvo winget):
#
#   irm https://raw.githubusercontent.com/unjordi/claude-brain/main/bootstrap.ps1 | iex
#
# Para QA de una RAMA (p. ej. develop) en vez de la default, define CLAUDE_BRAIN_REF antes:
#   $env:CLAUDE_BRAIN_REF='develop'; irm .../develop/bootstrap.ps1 | iex
#
# Hace: (1) instala con winget lo que falte (Git, .NET 10 SDK, jq, Node), (2) clona/actualiza el repo,
# (3) instala el cerebro (hooks) + el widget de bandeja. Idempotente.
$ErrorActionPreference = 'Stop'

# Permite ejecutar los .ps1 que este script invoca (install-brain.ps1 / install.ps1) aunque la maquina
# tenga ExecutionPolicy Restricted/AllSigned. Este script corre via `iex` (una CADENA, que la policy no
# frena), pero invocar un ARCHIVO .ps1 con `&` SI esta sujeto a la policy -> lo ponemos en Bypass SOLO
# para ESTE proceso (no toca la config global de la maquina, no persiste). Fix de raiz del gotcha
# "running scripts is disabled on this system" (caso real del onboarding, 2026-07-10).
try { Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass -Force } catch {}

$repo = 'https://github.com/unjordi/claude-brain'
# %LOCALAPPDATA% (no el perfil visible) para no ensuciar el home del usuario -- paridad con Linux/mac
# (~/.claude-brain oculto). Nombre "-repo" para no chocar con %LOCALAPPDATA%\claude-brain (cache del
# daemon: state/stats/account) ni con %LOCALAPPDATA%\Programs\ClaudeBrain (la app instalada).
$dir  = if ($env:CLAUDE_BRAIN_DIR) { $env:CLAUDE_BRAIN_DIR } else { "$env:LOCALAPPDATA\claude-brain-repo" }
$oldDir = "$env:USERPROFILE\claude-brain"   # legado (visible): bootstrap.ps1 clonaba aqui antes de ocultarlo (2026-07-15)
function Say($m) { Write-Host "claude-brain > $m" -ForegroundColor DarkYellow }

# Migracion: si ya existe el clon viejo VISIBLE y el nuevo oculto todavia no, muevelo (no lo dupliques).
# El clon se necesita para que el autoupdate del widget funcione -- no se borra, solo se oculta.
if ((Test-Path "$oldDir\.git") -and -not (Test-Path $dir)) {
  Say "migrando el clon de $oldDir a $dir (ya no vive visible en el perfil)"
  Move-Item -Path $oldDir -Destination $dir
}

# -- (1) Prerrequisitos con winget (idempotente) ------------------------------
if (-not (Get-Command winget -ErrorAction SilentlyContinue)) {
  Say 'Necesitas winget (App Installer, de la Microsoft Store). Instalalo y re-corre.'; return
}
# Git.Git trae Git Bash (lo necesita el cerebro); jq para los guardias; .NET SDK para buildear el exe;
# Node para el costo $ (ccusage, opcional).
$pkgs = @(
  @{ id = 'Git.Git';                cmd = 'git' },
  @{ id = 'jqlang.jq';              cmd = 'jq' },
  @{ id = 'Microsoft.DotNet.SDK.10';cmd = 'dotnet' },
  @{ id = 'OpenJS.NodeJS';          cmd = 'node' }
)
$installedSomething = $false
foreach ($p in $pkgs) {
  if (-not (Get-Command $p.cmd -ErrorAction SilentlyContinue)) {
    Say "instalando $($p.id) (winget)..."
    winget install --exact --id $p.id --accept-source-agreements --accept-package-agreements --silent | Out-Null
    $installedSomething = $true
  }
}
if ($installedSomething) {
  # winget actualiza el PATH persistente (Machine/User) + su carpeta de Links, pero el PATH de ESTE
  # proceso quedo capturado al arrancar y NO ve lo recien instalado -> los pasos (2) y (3) fallaban
  # ("git/jq no encontrado") en la MISMA corrida y obligaban a abrir otra terminal. Refrescamos el
  # PATH del proceso releyendo Machine+User del registro (+ la carpeta Links de winget), asi git/jq/
  # dotnet/node quedan visibles YA, en esta misma corrida. Idempotente.
  $machinePath = [Environment]::GetEnvironmentVariable('PATH','Machine')
  $userPath    = [Environment]::GetEnvironmentVariable('PATH','User')
  $wingetLinks = Join-Path $env:LOCALAPPDATA 'Microsoft\WinGet\Links'
  $env:PATH = (@($machinePath, $userPath, $wingetLinks) | Where-Object { $_ } ) -join ';'
  $faltan = @($pkgs | Where-Object { -not (Get-Command $_.cmd -ErrorAction SilentlyContinue) } | ForEach-Object { $_.cmd })
  if ($faltan.Count -gt 0) {
    Say "OJO: tras refrescar el PATH aun no veo: $($faltan -join ', '). ABRE UNA TERMINAL NUEVA y re-corre el mismo comando."
  } else {
    Say 'PATH refrescado en esta corrida -> git/jq/dotnet/node ya visibles (sin abrir otra terminal).'
  }
}

# -- (2) Clonar o actualizar --------------------------------------------------
# CLAUDE_BRAIN_REF (opcional): rama a instalar (p. ej. develop para QA); sin ella, la default.
$ref = $env:CLAUDE_BRAIN_REF
if (Test-Path "$dir\.git") {
  Say "actualizando $dir"; git -C $dir fetch -q origin
  if ($ref) { git -C $dir checkout -B $ref "origin/$ref" } else { git -C $dir pull --ff-only }
} else {
  Say "clonando en $dir"; git clone $repo $dir
  if ($ref) { git -C $dir fetch -q origin; git -C $dir checkout -B $ref "origin/$ref" }
}
if ($ref) { Say "instalando la rama '$ref' (QA)" }

# CLAUDE_BRAIN_DIR: exporta la ruta del clon-fuente como env var de USUARIO para que los hooks BASH
# (aviso-drift-cerebro, sincronizar-cerebro.sh) encuentren la FUENTE en Windows. Sin esto el hook cae a
# su default de Mac/Linux ($HOME/.claude-brain) -- que en Windows NO existe (aqui clonamos en
# %LOCALAPPDATA%\claude-brain-repo) -> el auto-sync del cerebro por-repo fallaba MUDO. La ruta se guarda
# en FORWARD-SLASH: bash se atraganta con los backslashes de Windows (mismo motivo que la ruta del .sh
# del instalador). $dir (con backslashes) se conserva intacto para los usos nativos de PowerShell.
$dirBash = $dir -replace '\\','/'
if ([Environment]::GetEnvironmentVariable('CLAUDE_BRAIN_DIR', 'User') -ne $dirBash) {
  [Environment]::SetEnvironmentVariable('CLAUDE_BRAIN_DIR', $dirBash, 'User')
  Say "CLAUDE_BRAIN_DIR = $dirBash (los hooks bash ya hallan la fuente del cerebro)"
}
$env:CLAUDE_BRAIN_DIR = $dirBash   # y para ESTA sesion (install-brain.ps1 / hooks que corran ya)

# -- (3) Instalar cerebro (hooks, via Git Bash + jq) + widget de bandeja (.NET) -
Set-Location $dir
Say 'instalando el cerebro (hooks + normas)...'
& "$dir\brain\install-brain.ps1"
Say 'instalando el widget de bandeja...'
& "$dir\windows\install.ps1"
Say 'listo - cerebro + widget puestos.'
