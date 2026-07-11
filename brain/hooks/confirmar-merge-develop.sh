#!/usr/bin/env bash
# confirmar-merge-develop.sh — PreToolUse/Bash: EXIGE confirmación EXPRESA de unjordi antes de
# INTEGRAR a develop/main por MR. Hace cumplir, en el punto exacto del merge, la definición de LISTO.
#
# Modelo "MINI-DEVELOP" (acordado con unjordi):
#   - Las ramitas de feature se mergean LIBREMENTE (con `git merge` LOCAL) a una rama de INTEGRACIÓN
#     de larga vida (`integracion/<sprint>` o `epic/<tema>`): ahí Claude trabaja horas/días, rompe y
#     arregla a gusto, reconstruye el stack, sin fricción y sin pedir permiso a cada paso.
#   - El ÚNICO cruce que pasa por este candado es integrar a develop/main vía MR
#     (`glab mr merge|accept` / `gh pr merge`, incluido armar `--auto-merge`): BLOQUEA salvo que en el
#     contexto reciente haya una MARCA de confirmación/autorización expresa de unjordi para ESTE cierre.
#
# `git merge` LOCAL a cualquier rama NO se intercepta (por eso iterar en la rama de integración es
# libre). Complementa a git-branch-guard (bloquea push directo a develop/main) y merge-squash-guard
# (exige --squash). Fail-open sin jq.
set -u
input=$(cat 2>/dev/null || true)
command -v jq >/dev/null 2>&1 || exit 0
cmd=$(printf '%s' "$input" | jq -r '.tool_input.command // empty' 2>/dev/null)
[ -z "$cmd" ] && exit 0

# ¿Es una INTEGRACIÓN server-side de MR/PR? (git merge local NO cuenta → iterar en integración es libre)
MERGE_RE='(glab[[:space:]]+mr[[:space:]]+(merge|accept)|gh[[:space:]]+pr[[:space:]]+merge)'
printf '%s' "$cmd" | grep -qE "$MERGE_RE" || exit 0
# Escapes: ayuda/inspección, no una integración real.
printf '%s' "$cmd" | grep -qE '(^|[[:space:]])(--help|-h|list|view|--dry-run|status)([[:space:]]|$)' && exit 0

# DESTINO del merge: main = RELEASE (autorización SUPER explícita); develop/otro = confirmación normal.
# FAIL-SAFE: si no podemos determinar el destino, se trata como develop (conservador).
destino=""
_repo=$(printf '%s' "$cmd" | grep -oE '(--repo|-R)[[:space:]=]+[^[:space:]]+' | grep -oE '[^[:space:]=]+$')
# Robustez: si el comando no trae --repo, deriva el repo del remote del PROYECTO (CLAUDE_PROJECT_DIR),
# no del cwd del hook — así la detección del destino (develop vs main) no depende de dónde corra el hook.
[ -z "$_repo" ] && _repo=$(git -C "${CLAUDE_PROJECT_DIR:-.}" remote get-url origin 2>/dev/null | sed -E 's#^(git@[^:]+:|https?://[^/]+/)##; s#\.git$##')
_mrid=$(printf '%s' "$cmd" | grep -oE '(mr[[:space:]]+(merge|accept)|pr[[:space:]]+merge)[[:space:]]+#?[0-9]+' | grep -oE '[0-9]+$')
if [ -n "$_mrid" ]; then
  if printf '%s' "$cmd" | grep -qE 'glab[[:space:]]+mr'; then
    destino=$(glab api "projects/:id/merge_requests/$_mrid" ${_repo:+-R "$_repo"} 2>/dev/null | jq -r '.target_branch // empty' 2>/dev/null)
  else
    destino=$(gh pr view "$_mrid" ${_repo:+-R "$_repo"} --json baseRefName -q .baseRefName 2>/dev/null)
  fi
fi

# Mensajes recientes del usuario (autorización).
recent=""
tpath=$(printf '%s' "$input" | jq -r '.transcript_path // empty' 2>/dev/null)
if [ -n "$tpath" ] && [ -f "$tpath" ]; then
  recent=$(tail -n 400 "$tpath" 2>/dev/null | jq -rs '
    [.[] | select((.message.role // .type)=="user")
         | (.message.content // [.message] )
         | (if type=="array" then (map(if type=="string" then . else (.text // "") end) | join(" ")) else (. // "") end)]
    | join("  ")' 2>/dev/null)
fi

if [ "$destino" = "main" ]; then
  # RELEASE a main: exige autorización SUPER explícita de release. Un 'mergea' genérico (que vale
  # para develop) NO autoriza un release a main.
  RELEASE_RE='hasta main|\brelease\b|(a|hacia|hast[ao]) main|liber(a|ar|alo|é)|promue?v(e|er)[a-zé ]*main|merge[a-zé ]* a? *main'
  printf '%s' "$recent" | grep -qiE "$RELEASE_RE" && exit 0
  jq -n --arg r "FRENO (RELEASE a main): promover develop→main es una decisión de RELEASE que exige autorización SUPER explícita de unjordi para ESTE release (p. ej. 'release a main', 'hasta main', 'libera'), y no la encuentro en el contexto reciente.
  (a) Si ya la dio, CÍTALA y reintenta.
  (b) main es release-only: un 'mergea' genérico (que vale para develop) NO autoriza un release a main. Los releases van SIN squash (conservan historia)." \
    '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:"deny",permissionDecisionReason:$r}}'
  exit 0
fi

# Destino develop (o desconocido → conservador): confirmación normal. "sigue/avanza" NO cuenta.
CONF_RE='merg[eé]a|mérga(lo|los)?|dale( el)? merge|haz(lo|le)?( el)? *merge|merge a develop|integra[a-zé ]*a? *develop|s[ií],? merge|ci[eé]rra(lo)?|cierra el slice|ll[eé]valo a develop|ya (puedes|podés|puedo) mergear|adelante[a-zé ]*(el )?merge|autoriz|luz verde (para|de|expresa)|visto bueno|aprob(ado|é|ó)?|va! *(merge|mr|develop|cierra)'
printf '%s' "$recent" | grep -qiE "$CONF_RE" && exit 0

jq -n --arg r "FRENO (definición de LISTO): integrar a develop por MR exige la confirmación EXPRESA de unjordi para ESTE cierre, y no la encuentro en el contexto reciente.
  (a) Si ya te dio el OK explícito, CÍTALO y reintenta.
  (b) Para seguir iterando SIN fricción: trabaja en una rama de INTEGRACIÓN (integracion/<sprint> o epic/<tema>) y mergea las ramitas ahí con 'git merge' LOCAL (libre, no pasa por este candado); solo el MR de esa rama de integración → develop pasa por aquí.
Recuerda: verde técnico != LISTO; 'sigue/avanza' NO autoriza el merge a develop." \
  '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:"deny",permissionDecisionReason:$r}}'
exit 0
