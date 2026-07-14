#!/usr/bin/env bash
# git-branch-guard.sh — PreToolUse guard de la NORMA DE GIT (ley interna).
# Lee el JSON del hook por stdin; si el comando Bash intenta tocar una rama
# protegida (push a main/develop, o mergear la MR de develop = promover a main),
# devuelve permissionDecision "deny": NO pregunta — bloquea la acción incorrecta y
# REDIRIGE a Claude al flujo correcto (ramita → MR → develop).
#
# CLAVE (evita falsos positivos): main/develop debe ser el DESTINO del push (mismo
# segmento tras `git push`, sin cruzar ; && ||), no aparecer en cualquier lado.
# Así `git checkout -b x develop && git push origin x` (flujo normal) PASA, y
# `... && git push origin develop` (el disfraz) se bloquea. grep corre por línea.
# Fail-open ante parseo. Vive en <repo>/.claude/hooks/ (viaja por git) y ~/.claude (por máquina).
# Releases develop→main = acción deliberada del humano en la web de GitLab, no por CLI.

# dedupe doble-cableado: si soy la copia del REPO y la copia GLOBAL existe, cedo (la global maneja
# esta invocación) → evita disparo doble en máquina con el cerebro global; en un clon SIN bootstrap
# (sin copia global) la del repo sí corre. NO-debilitante: sigue disparando 1× y denegando igual.
case "$0" in "$HOME/.claude/hooks/"*) : ;; *) [ -f "$HOME/.claude/hooks/$(basename "$0")" ] && exit 0 ;; esac
input=$(cat)
cmd=$(printf '%s' "$input" | jq -r '.tool_input.command // empty' 2>/dev/null)
[ -z "$cmd" ] && exit 0

block() {
  jq -n --arg r "$1" '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:"deny",permissionDecisionReason:$r}}'
  exit 0
}

# main/develop como DESTINO, dentro del mismo segmento de comando ([^;&|] = no cruza ; && ||),
# precedido por espacio/':'/'/' y seguido por espacio/fin/comilla. NO matchea feat/develop-x.
PUSH_RE='git[[:space:]]+push[^;&|]*[[:space:]:/](main|develop)([[:space:]]|$|["'"'"'])'
MERGE_RE='(glab[[:space:]]+mr[[:space:]]+merge|gh[[:space:]]+pr[[:space:]]+merge)[^;&|]*[[:space:]:/](main|develop)([[:space:]]|$|["'"'"'])'

if printf '%s' "$cmd" | grep -qE "$PUSH_RE"; then
  block "NORMA DE GIT (ley interna): no se hace push a main/develop. NO reintentes esto. Haz el cambio por el flujo: ramita (feat/fix/chore/docs) desde develop → commit → push de la ramita → MR/PR → merge a develop. A main solo llega un release deliberado que hace el humano en la web de GitLab, no por CLI."
fi

if printf '%s' "$cmd" | grep -qE "$MERGE_RE"; then
  block "NORMA DE GIT (ley interna): mergear develop→main es un RELEASE, y lo hace el humano deliberadamente en la web de GitLab, no Claude por CLI. NO reintentes. El trabajo se integra a develop por MR de una ramita, no a main."
fi

exit 0
