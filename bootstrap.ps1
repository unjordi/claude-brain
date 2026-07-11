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
$dir  = if ($env:CLAUDE_BRAIN_DIR) { $env:CLAUDE_BRAIN_DIR } else { "$env:USERPROFILE\claude-brain" }
function Say($m) { Write-Host "claude-brain > $m" -ForegroundColor DarkYellow }

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
  Say 'winget instalo prereqs nuevos -> el PATH de ESTA terminal quiza no los ve todavia.'
  Say 'Si el paso siguiente falla por "git/jq/dotnet no encontrado", ABRE UNA TERMINAL NUEVA y re-corre el mismo comando.'
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

# -- (3) Instalar cerebro (hooks, via Git Bash + jq) + widget de bandeja (.NET) -
Set-Location $dir
Say 'instalando el cerebro (hooks + normas)...'
& "$dir\brain\install-brain.ps1"
Say 'instalando el widget de bandeja...'
& "$dir\windows\install.ps1"
Say 'listo - cerebro + widget puestos.'
