#!/usr/bin/env bash
# git-branch-guard.sh — WRAPPER delgado sobre analizar-comando-git.sh. Bloquea (deny) push/merge a una
# rama protegida (develop/main) y redirige al flujo ramita→MR→develop. NO pregunta: bloquea la acción
# incorrecta. La LÓGICA de "qué toca una base" vive en la lib (fuente ÚNICA de los git-guards → no
# divergen). Fail-open ante parseo. Vive en <repo>/.claude/hooks/ (viaja por git) y ~/.claude (por máquina).
# Releases develop→main = acción de release deliberada; normalmente el humano en la web de GitLab, por
# CLI solo con OK súper-explícito (lo vigila confirmar-merge-develop). Este guard bloquea el PUSH a base.
#
# Cubre (via lib): push explícito a develop/main, push PELÓN/`HEAD`/`--force` estando EN develop/main
# (H1), ignora menciones entrecomilladas (H13) y valores de --repo/-R (repo llamado …/develop, H11).

# dedupe doble-cableado: si soy la copia del REPO y la copia GLOBAL existe, cedo (la global maneja esta
# invocación) → evita disparo doble; en un clon SIN bootstrap (sin copia global) la del repo sí corre.
case "$0" in "$HOME/.claude/hooks/"*) : ;; *) [ -f "$HOME/.claude/hooks/$(basename "$0")" ] && exit 0 ;; esac

command -v jq >/dev/null 2>&1 || exit 0
input=$(cat)
cmd=$(printf '%s' "$input" | jq -r '.tool_input.command // empty' 2>/dev/null)
[ -z "$cmd" ] && exit 0

# shellcheck source=analizar-comando-git.sh
. "$(dirname "$0")/analizar-comando-git.sh"

block() {
  jq -n --arg r "$1" '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:"deny",permissionDecisionReason:$r}}'
  exit 0
}

if acg_push_toca_base "$cmd"; then
  block "NORMA DE GIT (ley interna): no se hace push a main/develop (incluye el push PELÓN estando parado EN develop/main). NO reintentes esto. Haz el cambio por el flujo: ramita (feat/fix/chore/docs) desde develop → commit → push de la ramita → MR/PR → merge a develop. A main solo llega un release deliberado: normalmente el humano en la web de GitLab; por CLI solo con OK súper-explícito (lo vigila confirmar-merge-develop)."
fi

if acg_merge_menciona_base "$cmd"; then
  block "NORMA DE GIT (ley interna): mergear develop→main es un RELEASE, y lo hace el humano deliberadamente en la web de GitLab, no Claude por CLI. NO reintentes. El trabajo se integra a develop por MR de una ramita, no a main."
fi

exit 0
