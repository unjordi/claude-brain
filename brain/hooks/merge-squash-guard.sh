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

input=$(cat)
cmd=$(printf '%s' "$input" | jq -r '.tool_input.command // empty' 2>/dev/null)
[ -z "$cmd" ] && exit 0

# ¿El comando integra un MR/PR? (merge/accept en glab, pr merge en gh)
MERGE_RE='(glab[[:space:]]+mr[[:space:]]+(merge|accept)|gh[[:space:]]+pr[[:space:]]+merge)'
printf '%s' "$cmd" | grep -qE "$MERGE_RE" || exit 0

# Escape: ayuda/inspección, no una integración real.
printf '%s' "$cmd" | grep -qE '(^|[[:space:]])(--help|-h)([[:space:]]|$)' && exit 0

# ¿Ya trae squash? (--squash o -s). Si sí, todo bien.
SQUASH_RE='(--squash([[:space:]]|=|$)|(^|[[:space:]])-s([[:space:]]|$))'
printf '%s' "$cmd" | grep -qE "$SQUASH_RE" && exit 0

# EXENCIÓN DE RELEASE: un merge cuyo DESTINO es `main` es un RELEASE y va SIN squash (conserva la
# historia de la ventana de develop). No es un "no puedes": main tiene otra regla. La CONFIRMACIÓN
# explícita del release la exige el hook confirmar-merge-develop; aquí solo dejamos de imponer el
# squash cuando el destino es main. Determinamos el destino consultando el MR/PR (glab/gh).
# FAIL-SAFE: si NO podemos confirmar que el destino es main, mantenemos la exigencia de squash
# (nunca exentamos a ciegas → una ramita→develop sin squash sigue bloqueada).
if command -v jq >/dev/null 2>&1; then
  _repo=$(printf '%s' "$cmd" | grep -oE '(--repo|-R)[[:space:]=]+[^[:space:]]+' | grep -oE '[^[:space:]=]+$')
  # Robustez: si el comando no trae --repo, deriva el repo del remote del PROYECTO (CLAUDE_PROJECT_DIR),
  # no del cwd del hook (que puede no ser el repo → la consulta de destino fallaría y caería a fail-safe).
  [ -z "$_repo" ] && _repo=$(git -C "${CLAUDE_PROJECT_DIR:-.}" remote get-url origin 2>/dev/null | sed -E 's#^(git@[^:]+:|https?://[^/]+/)##; s#\.git$##')
  _mrid=$(printf '%s' "$cmd" | grep -oE '(mr[[:space:]]+(merge|accept)|pr[[:space:]]+merge)[[:space:]]+#?[0-9]+' | grep -oE '[0-9]+$')
  _destino=""
  if [ -n "$_mrid" ]; then
    if printf '%s' "$cmd" | grep -qE 'glab[[:space:]]+mr'; then
      _destino=$(glab api "projects/:id/merge_requests/$_mrid" ${_repo:+-R "$_repo"} 2>/dev/null | jq -r '.target_branch // empty' 2>/dev/null)
    else
      _destino=$(gh pr view "$_mrid" ${_repo:+-R "$_repo"} --json baseRefName -q .baseRefName 2>/dev/null)
    fi
  fi
  [ "$_destino" = "main" ] && exit 0   # release a main → exento del squash (gated por confirmar-merge-develop)
fi

jq -n --arg r "FLUJO DE GIT (ley interna): al integrar una ramita a develop se SQUASHEA a un solo commit. NO reintentes este merge sin squash. Rehazlo con: glab mr merge <id> --squash --squash-message \"\$(cat resumen.md)\" --auto-merge --remove-source-branch --yes  — donde resumen.md es un RESUMEN CURADO en prosa de lo que hizo el slice (el cambio neto y su porqué), NO el pegote de los commits granulares (fix/chore/hotfix de ida y vuelta). Ver skill cerrar-slice." \
  '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:"deny",permissionDecisionReason:$r}}'
exit 0
