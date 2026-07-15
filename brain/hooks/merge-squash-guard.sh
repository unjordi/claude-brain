#!/usr/bin/env bash
# merge-squash-guard.sh — PreToolUse guard: al mergear una ramita a develop, EXIGE squash.
# Lee el JSON del hook por stdin; si el comando mergea un MR/PR (glab mr merge|accept, gh pr
# merge) SIN `--squash`/`-s`, devuelve permissionDecision "deny": NO pregunta — bloquea y pide
# rehacerlo con `--squash --squash-message "<resumen curado>"`. Así develop recibe UN commit
# limpio por slice (la ramita puede traer N commits granulares; se colapsan al integrar).
#
# Reparto de responsabilidades: este hook fuerza el SQUASH (mecánico, verificable). La calidad
# del MENSAJE (un resumen bonito en prosa, no el pegote de commits) la exige la skill cerrar-slice
# / flujo-mr-gitlab (es criterio, no se puede checar con grep). El candado server-side definitivo
# es el ajuste de GitLab `squash_option=always` (ver flujo-de-trabajo.md).
#
# Fail-open ante parseo (sin jq no bloquea). Vive en <repo>/.claude/hooks/ (viaja por git).

# dedupe doble-cableado: si soy la copia del REPO y la copia GLOBAL existe, cedo (la global maneja
# esta invocación) → evita disparo doble en máquina con el cerebro global; en un clon SIN bootstrap
# (sin copia global) la del repo sí corre. NO-debilitante: sigue disparando 1× y denegando igual.
case "$0" in "$HOME/.claude/hooks/"*) : ;; *) [ -f "$HOME/.claude/hooks/$(basename "$0")" ] && exit 0 ;; esac
input=$(cat)
cmd=$(printf '%s' "$input" | jq -r '.tool_input.command // empty' 2>/dev/null)
[ -z "$cmd" ] && exit 0

# shellcheck source=analizar-comando-git.sh
. "$(dirname "$0")/analizar-comando-git.sh"

# ¿El comando EJECUTA una integración REAL de MR/PR? (merge/accept glab, pr merge gh; no ayuda/dry-run).
# La lógica de reconocimiento vive en la lib (fuente única con los otros git-guards → no divergen).
acg_es_merge_mr "$cmd" || exit 0

# ¿Ya trae squash? (--squash o -s). Si sí, todo bien.
SQUASH_RE='(--squash([[:space:]]|=|$)|(^|[[:space:]])-s([[:space:]]|$))'
printf '%s' "$cmd" | grep -qE "$SQUASH_RE" && exit 0

# La obligatoriedad de --squash aplica SÓLO cuando el DESTINO es `develop` (1 commit limpio por slice).
# Todo lo demás va LIBRE: `main` es RELEASE (conserva historia — JAMÁS se fuerza squash, así un squash
# olvidado nunca aplasta el histórico de un release), y ramas personales/ramitas son el día a día (a tu
# gusto). El destino lo resuelve la lib (acg_destino_de_mr): caché por MR-id COMPARTIDA con
# confirmar-merge-develop (1 llamada de red, no 2) + timeout interno para no fallar-abierto por muerte
# del proceso (H5). FAIL-SAFE hacia esa prioridad: si NO podemos confirmar que el destino es `develop`
# (vacío por timeout/error), NO forzamos squash (nunca arriesgamos aplastar un release por no resolver).
_destino=$(acg_destino_de_mr "$cmd")
# SOLO `develop` obliga squash; el resto (main/personales/ramitas/desconocido) queda libre.
[ "$_destino" = "develop" ] || exit 0

# El mensaje cita la herramienta REAL del repo (gh vs glab), no siempre glab (P5).
if printf '%s' "$cmd" | grep -qE 'gh[[:space:]]+pr'; then
  _rehaz='gh pr merge <id> --squash --subject "<título curado>" --body "$(cat resumen.md)"'
else
  _rehaz='glab mr merge <id> --squash --squash-message "$(cat resumen.md)" --remove-source-branch --yes'
fi
jq -n --arg r "FLUJO DE GIT (ley interna): integrar a develop SQUASHEA a UN commit limpio por slice. NO reintentes este merge sin squash. Rehazlo con: $_rehaz  — donde el mensaje es un RESUMEN CURADO en prosa del slice (el cambio neto y su porqué), NO el pegote de commits granulares. NOTA: la obligación de squash es SOLO para develop — a main (release) va SIN squash (conserva historia) y tus ramas personales van a tu gusto. Ver skill cerrar-slice." \
  '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:"deny",permissionDecisionReason:$r}}'
exit 0
