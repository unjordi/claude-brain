#!/usr/bin/env bash
# aviso-drift-cerebro.sh — SessionStart hook (tier GLOBAL). Al INICIAR sesión en un repo que tiene el
# cerebro POR-REPO instalado (sello .brain-version o el hook repo-scoped clásico), compara esa copia
# contra la FUENTE ÚNICA local (el clon de instalación ~/.claude-brain, o $CLAUDE_BRAIN_DIR) usando
# sincronizar-cerebro.sh en DRY-RUN (diff-aware por CONTENIDO — comparar versiones NO sirve: VERSION
# no se bumpea por cambio) y, si la copia quedó ATRÁS, INYECTA un aviso ruidoso vía additionalContext.
#
# Diseño de unjordi (2026-07-18): "es tan sencillo como poner un hook en el global para que en el
# inicio de sesión revise que el local y global sean el mismo y actualice el local si no" — con dos
# matices acordados en la misma conversación: (a) el comparador es el DIFF real, no la versión; (b) en
# repos COMPARTIDOS "actualizar el local" = commit por ramita→MR, así que este hook NO escribe NADA al
# árbol (un write silencioso ensuciaría el working tree y se mezclaría a commits de feature): DETECTA
# y AVISA para que Claude proponga la propagación por el flujo. Evidencia de necesidad: MegaFlux
# acumuló 9 archivos de drift porque nadie corría el sync (detectado 2026-07-18).
#
# Throttle: si el último chequeo de ESTE repo salió LIMPIO, no se re-chequea por AVISO_DRIFT_HORAS
# (default 6; stamp en ~/.claude/memory/.drift-cerebro/). Un chequeo CON drift no se cachea → avisa en
# cada inicio de sesión hasta que se propague (esa insistencia es el punto).
# Fail-open SIEMPRE: sin clon canónico / repo no-brained / cualquier error del sync → silencio.
set -u

ROOT="${CLAUDE_PROJECT_DIR:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"
cat >/dev/null 2>&1 || true   # drenar stdin (contrato SessionStart)

# ¿repo brained? (sello del sync, o el hook repo-scoped clásico)
{ [ -f "$ROOT/.claude/hooks/.brain-version" ] || [ -f "$ROOT/.claude/hooks/dod-verificar.sh" ]; } || exit 0

# Fuente canónica LOCAL del cerebro = el clon de instalación (lo actualiza el one-liner/bootstrap).
BRAIN_DIR="${CLAUDE_BRAIN_DIR:-$HOME/.claude-brain}"
SYNC="$BRAIN_DIR/brain/sincronizar-cerebro.sh"
[ -f "$SYNC" ] || exit 0

# Throttle por repo (solo cachea chequeos LIMPIOS).
horas="${AVISO_DRIFT_HORAS:-6}"; case "$horas" in ''|*[!0-9]*) horas=6;; esac
stampdir="$HOME/.claude/memory/.drift-cerebro"; mkdir -p "$stampdir" 2>/dev/null || true
slug=$(printf '%s' "$ROOT" | cksum 2>/dev/null | awk '{print $1}')
stamp="$stampdir/${slug:-0}"
now=$(date +%s)
if [ -f "$stamp" ]; then
  last=$(cat "$stamp" 2>/dev/null || echo 0)
  case "$last" in ''|*[!0-9]*) last=0;; esac
  [ $(( now - last )) -lt $(( horas * 3600 )) ] && exit 0
fi

# DRY-RUN del sync (sin --apply: NO escribe). Error del sync → fail-open.
out=$(bash "$SYNC" "$ROOT" 2>/dev/null) || exit 0
resumen=$(printf '%s\n' "$out" | grep -E '==> resumen:' | tail -1)
[ -n "$resumen" ] || exit 0
nuevos=$(printf '%s' "$resumen" | grep -oE '[0-9]+ nuevos'       | grep -oE '[0-9]+' || echo 0)
act=$(printf '%s' "$resumen"    | grep -oE '[0-9]+ a actualizar' | grep -oE '[0-9]+' || echo 0)
total=$(( ${nuevos:-0} + ${act:-0} ))

if [ "$total" -eq 0 ]; then
  printf '%s' "$now" > "$stamp" 2>/dev/null || true
  exit 0
fi

detalle=$(printf '%s\n' "$out" | grep -E '(NUEVO|ACTUALIZA|RETIRARÍA)' | sed 's/^[[:space:]]*/    /' | head -12)
ctx="🧠⚠️ DRIFT DEL CEREBRO POR-REPO: la copia en .claude/hooks/ de ESTE repo está ATRÁS de la fuente única del cerebro ($total archivo(s)):
$detalle
Qué hacer: PROPÓN al usuario propagar por el flujo — worktree/ramita desde develop → \`bash $SYNC <worktree> --apply\` → commit → MR a develop. NO edites .claude/hooks/ directo en el árbol de trabajo (en repos compartidos viaja por git y se mezclaría a commits de feature). Nota: en ESTA máquina la copia GLOBAL ya manda (dedupe), pero el drift por-repo afecta a colegas y clones sin bootstrap."

if command -v jq >/dev/null 2>&1; then
  jq -n --arg c "$ctx" '{hookSpecificOutput:{hookEventName:"SessionStart",additionalContext:$c}}'
else
  printf '%s\n' "$ctx"
fi
exit 0
