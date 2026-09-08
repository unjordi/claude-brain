#!/usr/bin/env bash
# no-bypass-deploy.sh — PreToolUse/Bash: AVISA (NO bloquea) cuando se corre A MANO el instalador/deploy
# de un proyecto en vez de su HERRAMIENTA OFICIAL. Mecaniza la norma "Actualiza por la herramienta real"
# (B1): el cerebro/widget se actualiza con el WIDGET (su updater ⬆), NUNCA corriendo install-brain.sh /
# install.sh a pelo — generalizado a CUALQUIER install/deploy del proyecto (deploy.sh, publish, make
# install/deploy, just deploy). Correr el script crudo se salta backup/escritura-atómica/sello-de-versión/
# re-cableado/verificación que la herramienta orquesta → deja media instalación o una versión que MIENTE.
#
# FAIL-SAFE: solo AVISA (additionalContext), jamás bloquea; ante duda NO dispara. Precisión: NO dispara
# en --dry-run/-n/--help/-h (no mutan), NI en CI (ahí el pipeline ES la herramienta), NI sobre una
# MENCIÓN entrecomillada del instalador (dato de un grep/echo/mensaje). Fail-open sin jq.
#
# dedupe doble-cableado (tier both): si soy la copia del REPO y la copia GLOBAL existe, cedo (evita el
# aviso DUPLICADO). No-debilitante: sigue avisando 1×.
case "$0" in "$HOME/.claude/hooks/"*) : ;; *) [ -f "$HOME/.claude/hooks/$(basename "$0")" ] && exit 0 ;; esac

command -v jq >/dev/null 2>&1 || exit 0

# CI: el pipeline ES la herramienta oficial → nunca avisamos ahí.
if [ -n "${CI:-}" ] || [ -n "${GITLAB_CI:-}" ] || [ -n "${GITHUB_ACTIONS:-}" ] || [ -n "${BUILD_ID:-}" ]; then
  exit 0
fi

input=$(cat 2>/dev/null || true)
cmd=$(printf '%s' "$input" | jq -r '.tool_input.command // empty' 2>/dev/null)
[ -z "$cmd" ] && exit 0

# PRE-FILTRO barato (capa determinista, en-proceso): si el comando NO menciona NINGÚN gatillo posible
# (install/deploy/publish/make/just — 'uninstall-brain' contiene 'install'), no puede disparar → early-exit
# ANTES de gastar sed/tr/grep (~5 subprocesos) en el camino COMÚN. Conservador: filtra sobre el cmd CRUDO
# (superset de lo que verían los regex tras des-entrecomillar) → JAMÁS salta un caso que sí debería avisar;
# a lo más CONTINÚA de más (p. ej. 'deploy' dentro de comillas), y ahí el chequeo real decide. nocasematch
# (bash≥3.1, macOS-safe) para cubrir INSTALL/Deploy/etc. sin re-lowercasear aquí.
shopt -s nocasematch 2>/dev/null
case "$cmd" in *install*|*deploy*|*publish*|*make*|*just*) : ;; *) exit 0 ;; esac
shopt -u nocasematch 2>/dev/null

# Quita literales entrecomillados → una MENCIÓN del instalador (grep/echo/doc) no dispara.
unquoted=$(printf '%s' "$cmd" | sed "s/'[^']*'//g; s/\"[^\"]*\"//g")

# Excepciones que NO mutan: dry-run / help. Si aparecen, calla (se está inspeccionando, no desplegando).
printf '%s' "$unquoted" | grep -qE '(^|[[:space:]])(--dry-run|--help|-h|-n)([[:space:]]|$)' && exit 0

# ── Detección de EJECUCIÓN (no edición/cat) del instalador/deploy ──
# (1) BRAIN: install-brain / uninstall-brain (.sh|.ps1) corrido a mano → la vía oficial es el WIDGET.
# (2) GENÉRICO: un install/deploy/publish .sh|.ps1 ejecutado, o make/just con target install|deploy.
# El basename debe aparecer en contexto de EJECUCIÓN: tras bash/sh/zsh/pwsh, tras ./, o con ruta /…/.
# PREFIJO de EJECUCIÓN (no una mención suelta): inicio de comando, tras un separador (;&|`+espacios),
# o tras un runner (bash/sh/zsh/pwsh -file). Un espacio PELÓN NO cuenta → así `grep install-brain.sh`
# (el nombre como ARGUMENTO, no ejecución) NO dispara.
_pfx='(^|[;&|`][[:space:]]*|bash[[:space:]]+|sh[[:space:]]+|zsh[[:space:]]+|pwsh[[:space:]]+-file[[:space:]]+)'
# RUTA opcional entre el prefijo y el basename: solo cuenta si la ruta COMPLETA arranca justo tras el
# prefijo de arriba (ejecución real: ./foo.sh, /abs/path/foo.sh, bash brain/foo.sh) — antes bastaba un
# "/" SUELTO pegado al basename como prefijo, y eso disparaba sobre cualquier MENCIÓN con subcarpeta
# como ARGUMENTO de otro comando ("git add brain/install-brain.sh", "git log -- scripts/deploy.sh",
# "git show HEAD~1:brain/x.sh" → ahí el "/" queda pegado al basename pero el TOKEN no arranca en
# posición de ejecución). Exigir que la ruta entera nazca justo tras el prefijo cierra ese hueco sin
# tocar la detección real (bash/./ /abs siguen exigiendo el prefijo correcto antes del primer tramo).
_path='(\./|/)?([A-Za-z0-9_.-]+/)*'
brain_re="${_pfx}${_path}(install-brain|uninstall-brain)\\.(sh|ps1)([[:space:]]|$|[;&|])"
gen_re="${_pfx}${_path}(install|deploy|publish)\\.(sh|ps1)([[:space:]]|$|[;&|])"
mk_re='(^|[;&|`][[:space:]]*)(make|just)[[:space:]]+(install|deploy|publish)([[:space:]]|$|[;&|])'

low=$(printf '%s' "$unquoted" | tr 'A-Z' 'a-z')

msg=""
if printf '%s' "$low" | grep -qE "$brain_re"; then
  msg="AVISO (no-bypass-deploy): estás corriendo el instalador del CEREBRO a mano (install-brain/uninstall-brain). La vía OFICIAL para actualizar el cerebro es el WIDGET (su updater ⬆: backup + escritura atómica + re-cableado + sello de versión + verificación). Correrlo crudo se salta esos pasos y puede dejar media instalación o una versión que MIENTE sobre lo instalado. Si es un bootstrap/depuración deliberada, ignora este aviso."
elif printf '%s' "$low" | grep -qE "$gen_re" || printf '%s' "$low" | grep -qE "$mk_re"; then
  msg="AVISO (no-bypass-deploy): parece que corres un instalador/deploy a mano (install/deploy/publish). Si el proyecto tiene una vía OFICIAL para aplicar el cambio (script de release, pipeline, herramienta dedicada), úsala en vez del script crudo — se salta pasos que la herramienta orquesta (backup, atomicidad, versión, verificación). Si es deliberado (o no hay herramienta oficial), ignora este aviso."
fi

[ -z "$msg" ] && exit 0
jq -n --arg m "$msg" '{hookSpecificOutput:{hookEventName:"PreToolUse",additionalContext:$m}}'
exit 0
