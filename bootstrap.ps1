# bootstrap.ps1 - instalador AUTOCONTENIDO de cortex para Windows.
# Un solo comando (jala los prereqs con winget; no necesitas nada preinstalado salvo winget):
#
#   irm https://raw.githubusercontent.com/unjordi/cortex/main/bootstrap.ps1 | iex
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

$repo = 'https://github.com/unjordi/cortex'
# %LOCALAPPDATA% (no el perfil visible) para no ensuciar el home del usuario -- paridad con Linux/mac
# (~/.cortex oculto). Nombre "-repo" para no chocar con %LOCALAPPDATA%\cortex (cache del
# daemon: state/stats/account) ni con %LOCALAPPDATA%\Programs\Cortex (la app instalada).
$dir  = if ($env:CLAUDE_BRAIN_DIR) { $env:CLAUDE_BRAIN_DIR } else { "$env:LOCALAPPDATA\cortex-repo" }
function Say($m) { Write-Host "cortex > $m" -ForegroundColor DarkYellow }

# Migracion del clon de eras viejas -> $dir. El clon se necesita para el autoupdate del widget: no se
# borra, se REUBICA. La era intermedia 'claude-brain' vivia en %LOCALAPPDATA%\claude-brain-repo (oculto)
# o %USERPROFILE%\claude-brain (visible, pre-ocultamiento). Si existe y $dir aun no, muevelo y reapunta
# el remote a cortex; si $dir ya existe, borra el huerfano. Idempotente/fail-safe. (El #312 renombro el
# $oldDir mecanicamente a %USERPROFILE%\cortex -un dir visible que NUNCA existio-; ese puntero muerto se
# quito, las rutas reales de la era claude-brain van abajo.)
foreach ($brainOld in @("$env:LOCALAPPDATA\claude-brain-repo", "$env:USERPROFILE\claude-brain")) {
  if (-not (Test-Path "$brainOld\.git")) { continue }
  # NUNCA operes sobre el destino ACTIVO: si $dir (CLAUDE_BRAIN_DIR, que la era claude-brain PERSISTIO
  # con FORWARD-SLASH) resuelve a esta MISMA ruta vieja, saltala -> si no, el else borraria el clon VIVO
  # (era SISTEMATICO en Windows). Resolve-Path normaliza slashes/casing; un -eq crudo NO lo atrapa (\ vs /).
  $roOld = (Resolve-Path -LiteralPath $brainOld -ErrorAction SilentlyContinue).Path
  $roDir = (Resolve-Path -LiteralPath $dir -ErrorAction SilentlyContinue).Path
  if ($roOld -and $roDir -and ($roOld -eq $roDir)) { continue }
  if (-not (Test-Path $dir)) {
    Say "migrando el clon de $brainOld a $dir (rename claude-brain -> cortex)"
    Move-Item -Path $brainOld -Destination $dir
    try { git -C $dir remote set-url origin $repo } catch {}
  } else {
    Say "quitando el clon huerfano $brainOld (ya existe $dir)"
    Remove-Item -Path $brainOld -Recurse -Force -ErrorAction SilentlyContinue
  }
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
  # Sin REF: alinear SIEMPRE a main con `checkout -B main origin/main`, NO tirando de la rama actual.
  # Igual que bootstrap.sh:69: un clon que quedo en una rama vieja/borrada (leftover de dev) rompia el
  # fast-forward porque su upstream ya no existe en el remoto. Paridad Mac/Linux <-> Windows.
  if ($ref) { git -C $dir checkout -B $ref "origin/$ref" } else { git -C $dir checkout -B main origin/main }
} else {
  Say "clonando en $dir"; git clone $repo $dir
  if ($ref) { git -C $dir fetch -q origin; git -C $dir checkout -B $ref "origin/$ref" }
}
if ($ref) { Say "instalando la rama '$ref' (QA)" }

# CLAUDE_BRAIN_DIR: exporta la ruta del clon-fuente como env var de USUARIO para que los hooks BASH
# (aviso-drift-cerebro, sincronizar-cerebro.sh) encuentren la FUENTE en Windows. Sin esto el hook cae a
# su default de Mac/Linux ($HOME/.cortex) -- que en Windows NO existe (aqui clonamos en
# %LOCALAPPDATA%\cortex-repo) -> el auto-sync del cerebro por-repo fallaba MUDO. La ruta se guarda
# en FORWARD-SLASH: bash se atraganta con los backslashes de Windows (mismo motivo que la ruta del .sh
# del instalador). $dir (con backslashes) se conserva intacto para los usos nativos de PowerShell.
$dirBash = $dir -replace '\\','/'
if ([Environment]::GetEnvironmentVariable('CLAUDE_BRAIN_DIR', 'User') -ne $dirBash) {
  [Environment]::SetEnvironmentVariable('CLAUDE_BRAIN_DIR', $dirBash, 'User')
  Say "CLAUDE_BRAIN_DIR = $dirBash (los hooks bash ya hallan la fuente del cerebro)"
}
$env:CLAUDE_BRAIN_DIR = $dirBash   # y para ESTA sesion (install-brain.ps1 / hooks que corran ya)

# -- Puente HOME <-> USERPROFILE (solo Windows) --------------------------------
# El instalador BASH cabla el cerebro en $HOME/.claude (install-brain.sh:36), pero el WIDGET
# (BrainInspector.cs/.swift) lo LEE desde %USERPROFILE%\.claude. En Windows el $HOME que ve Git Bash
# puede DIVERGIR de %USERPROFILE% (p.ej. HOME apuntando a un HOMESHARE de dominio) -> el cerebro se
# instalaria en un ~/.claude que el widget NO mira. Forzamos HOME=%USERPROFILE% para el proceso: el
# bash hijo (install.ps1 -> install-brain.ps1 -> install-brain.sh) hereda este entorno, asi ambos
# apuntan al MISMO .claude. Es .ps1 -> solo corre en Windows; no toca Mac/Linux.
if ($env:USERPROFILE) { $env:HOME = $env:USERPROFILE }

# -- (3) Instalar cerebro (hooks, via Git Bash + jq) + widget de bandeja (.NET) -
# install.ps1 es el ONE-STOP (cerebro + widget), igual que install.sh en Mac/Linux -> un solo llamado,
# sin asimetria. (Antes bootstrap corria install-brain.ps1 + install.ps1 por separado; ahora install.ps1
# instala el cerebro por defecto. -NoBrain lo saltaria.)
Set-Location $dir
Say 'instalando el cerebro (hooks + normas) + el widget de bandeja...'
# SIN pass-through de banderas, y no es un olvido: este script se corre con `irm ... | iex`, que no
# admite argumentos. A diferencia de bootstrap.sh (que si pasa "$@" a install.sh), aqui no hay nada
# que reenviar. Para opciones (-NoBrain, -Build...) se invoca windows\install.ps1 directo desde el
# clon. El broker de terminal es Linux-only, asi que por esta via no se puede pedir ni por error.
& "$dir\windows\install.ps1"
Say 'listo - cerebro + widget puestos.'
