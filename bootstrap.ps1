# bootstrap.ps1 — instalador AUTOCONTENIDO de claude-brain para Windows.
# Un solo comando (jala los prereqs con winget; no necesitas nada preinstalado salvo winget):
#
#   irm https://raw.githubusercontent.com/unjordi/claude-brain/main/bootstrap.ps1 | iex
#
# Hace: (1) instala con winget lo que falte (Git, .NET 10 SDK, jq, Node), (2) clona/actualiza el repo,
# (3) instala el cerebro (hooks) + el widget de bandeja. Idempotente.
$ErrorActionPreference = 'Stop'
$repo = 'https://github.com/unjordi/claude-brain'
$dir  = if ($env:CLAUDE_BRAIN_DIR) { $env:CLAUDE_BRAIN_DIR } else { "$env:USERPROFILE\claude-brain" }
function Say($m) { Write-Host "claude-brain > $m" -ForegroundColor DarkYellow }

# ── (1) Prerrequisitos con winget (idempotente) ──────────────────────────────
if (-not (Get-Command winget -ErrorAction SilentlyContinue)) {
  Say 'Necesitas winget (App Installer, de la Microsoft Store). Instálalo y re-corre.'; return
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
    Say "instalando $($p.id) (winget)…"
    winget install --exact --id $p.id --accept-source-agreements --accept-package-agreements --silent | Out-Null
    $installedSomething = $true
  }
}
if ($installedSomething) {
  Say 'winget instaló prereqs nuevos → el PATH de ESTA terminal quizá no los ve todavía.'
  Say 'Si el paso siguiente falla por "git/jq/dotnet no encontrado", ABRE UNA TERMINAL NUEVA y re-corre el mismo comando.'
}

# ── (2) Clonar o actualizar ──────────────────────────────────────────────────
if (Test-Path "$dir\.git") { Say "actualizando $dir"; git -C $dir pull --ff-only }
else { Say "clonando en $dir"; git clone $repo $dir }

# ── (3) Instalar cerebro (hooks, vía Git Bash + jq) + widget de bandeja (.NET) ─
Set-Location $dir
Say 'instalando el cerebro (hooks + normas)…'
& "$dir\brain\install-brain.ps1"
Say 'instalando el widget de bandeja…'
& "$dir\windows\install.ps1"
Say 'listo — cerebro + widget puestos.'
