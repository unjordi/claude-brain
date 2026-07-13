#!/usr/bin/env bash
# proteger-arbol.sh — PreToolUse/Bash: AVISA (NO bloquea) antes de un git DESTRUCTIVO que podría
# ORFANAR commits sin pushear en el árbol de trabajo actual. Antídoto al un caso REAL (2026-07):
# un agente de fan-out se metió al árbol de trabajo COMPARTIDO y reseteó HEAD, dejando huérfano un
# commit del orquestador (la fuente quedó a medias y el build compiló eso; se recuperó por cherry-pick).
# Solo avisa cuando REALMENTE hay commits en riesgo (bajo ruido). Fail-open. Ignora comandos
# entrecomillados (dato de un grep / mensaje de commit / doc).
command -v jq >/dev/null 2>&1 || exit 0
input=$(cat 2>/dev/null || true)
cmd=$(printf '%s' "$input" | jq -r '.tool_input.command // empty' 2>/dev/null)
[ -z "$cmd" ] && exit 0
# Quita literales entrecomillados para no matchear 'git reset' como dato.
unquoted=$(printf '%s' "$cmd" | sed "s/'[^']*'//g; s/\"[^\"]*\"//g")
# ¿git DESTRUCTIVO que mueve HEAD / descarta commits?
printf '%s' "$unquoted" | grep -qE 'git[[:space:]]+(reset[[:space:]]+(--hard|--merge|--keep)|checkout[[:space:]]+(-f|--force)|rebase([[:space:]]|$)|branch[[:space:]]+-D)' || exit 0

root=$(git -C "${CLAUDE_PROJECT_DIR:-.}" rev-parse --show-toplevel 2>/dev/null || true)
[ -z "$root" ] && exit 0

# ¿Cuántos commits se ORFANARÍAN? (los que HEAD tiene y su upstream no; sin upstream → vs origin/develop|main)
n=0
if git -C "$root" rev-parse --abbrev-ref '@{u}' >/dev/null 2>&1; then
  n=$(git -C "$root" rev-list --count '@{u}..HEAD' 2>/dev/null || echo 0)
else
  mb=$(git -C "$root" merge-base HEAD origin/develop 2>/dev/null || git -C "$root" merge-base HEAD origin/main 2>/dev/null || true)
  [ -n "$mb" ] && n=$(git -C "$root" rev-list --count "$mb..HEAD" 2>/dev/null || echo 0)
fi
[ "${n:-0}" -gt 0 ] 2>/dev/null || exit 0

# ¿Árbol PRINCIPAL (compartido) o worktree aislado?
gd=$(git -C "$root" rev-parse --git-dir 2>/dev/null)
gcd=$(git -C "$root" rev-parse --git-common-dir 2>/dev/null)
if [ "$gd" = "$gcd" ]; then arbol="PRINCIPAL (compartido)"; else arbol="un worktree aislado"; fi

msg="AVISO (proteger-arbol): este git destructivo puede ORFANAR $n commit(s) sin pushear en el árbol $arbol. Si eres un AGENTE de fan-out: NO operes el árbol COMPARTIDO — trabaja en tu worktree aislado (isolation: worktree); si necesitas rebobinar, que lo haga el orquestador. Si es intencional (rebobinar a propósito) y ya lo pensaste, ignora este aviso. Lección real (2026-07): un agente reseteó HEAD en el árbol principal y orfanó un commit del orquestador."
jq -n --arg m "$msg" '{hookSpecificOutput:{hookEventName:"PreToolUse",additionalContext:$m}}'
exit 0
