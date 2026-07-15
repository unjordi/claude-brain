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

# H14: en un worktree AISLADO el DESASTRE que este hook vigila —orfanar los commits del ORQUESTADOR en
# el árbol COMPARTIDO— es IMPOSIBLE: el aislado solo tiene SU propia rama. Y el workaround del bug de
# harness H15 (el worktree nace en `origin/HEAD` viejo y el agente hace `git reset --hard <su rama
# objetivo>` al arrancar) dispara un aviso SIEMPRE falso: los "orfanados" son el base RANCIO, no trabajo.
# Feedback real (2026-07): 4 agentes de un fan-out lo dispararon, todos legítimos → desincentiva delegar.
if [ "$gd" != "$gcd" ]; then
  cur=$(git -C "$root" symbolic-ref --short -q HEAD 2>/dev/null)
  # objetivo del reset/checkout destructivo (vacío = a HEAD, inocuo)
  tgt=$(printf '%s' "$unquoted" | grep -oE 'git[[:space:]]+(reset[[:space:]]+--(hard|merge|keep)|checkout[[:space:]]+(-f|--force))[[:space:]]+[^[:space:]|;&]+' | awk '{print $NF}' | head -1)
  # aislado Y (sin objetivo | apunta a su propia rama / su upstream | a una base develop|main) → workaround
  # H15 / rebobinado a la propia rama → aviso falso → SUPRIME.
  if [ -z "$tgt" ] || [ "$tgt" = "$cur" ] || [ "$tgt" = "origin/$cur" ] \
     || printf '%s\n' "$tgt" | grep -qE '^(origin/)?(develop|main)$'; then
    exit 0
  fi
  # aislado pero destructivo hacia OTRO objetivo → nota SUAVE (no la alarma completa): solo tu rama.
  msg="Nota (proteger-arbol): git destructivo en un worktree AISLADO — puede rebobinar $n commit(s) de TU rama, pero el árbol COMPARTIDO del orquestador NO está en riesgo. Si rebobinas a propósito, adelante."
  jq -n --arg m "$msg" '{hookSpecificOutput:{hookEventName:"PreToolUse",additionalContext:$m}}'
  exit 0
fi

# Árbol PRINCIPAL (compartido): aquí SÍ está el peligro real → aviso completo.
msg="AVISO (proteger-arbol): este git destructivo puede ORFANAR $n commit(s) sin pushear en el árbol PRINCIPAL (compartido). Si eres un AGENTE de fan-out: NO operes el árbol COMPARTIDO — trabaja en tu worktree aislado (isolation: worktree); si necesitas rebobinar, que lo haga el orquestador. Si es intencional (rebobinar a propósito) y ya lo pensaste, ignora este aviso. Lección real (2026-07): un agente reseteó HEAD en el árbol principal y orfanó un commit del orquestador."
jq -n --arg m "$msg" '{hookSpecificOutput:{hookEventName:"PreToolUse",additionalContext:$m}}'
exit 0
