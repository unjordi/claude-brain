#!/usr/bin/env bash
# recordar-cosechar.sh — Stop hook (tier REPO). Nudge GENTIL y NO bloqueante de "trabajaste y no
# cosechaste aprendizajes". Al terminar un turno, si en ESTE repo hubo trabajo sustantivo reciente
# PERO .claude/memory/aprendizajes.md NO fue tocado recientemente, inyecta un recordatorio suave para
# correr `/cosechar-sesion` antes de cerrar (si aprendiste algo durable). NUNCA bloquea.
#
# Por qué EXISTE (pedido explícito de unjordi, 2026-07-21): la cosecha LOCAL alimenta el inbox de
# aprendizajes del equipo; sin un empujón se olvida al cerrar el día. "Norma sin mecanismo = buen
# deseo" → este hook es el mecanismo. Es la mitad "recuérdame" del par con la skill `cosechar-sesion`
# (la mitad "hazlo").
#
# HEURÍSTICO de "hubo trabajo sustantivo" (simple y robusto, elegido a propósito):
#   trabajo = (A) hubo commits en las últimas RECORDAR_COSECHAR_HORAS_TRABAJO (default 6), O
#             (B) el working tree tiene cambios en archivos de CÓDIGO (*.cs/*.razor/*.ts/*.js/*.sh/
#                 *.py/*.sql/*.css/*.html). Cualquiera de las dos basta.
#   "no cosechado" = aprendizajes.md NO cambió en git en esa ventana Y no está modificado sin commitear.
#   Si hubo trabajo Y no se cosechó → avisa (1×/día/repo). Si no hubo trabajo, o ya se cosechó → silencio.
# Es un PROXY: no distingue "trabajo que dejó aprendizaje" de "trabajo trivial" — por eso el aviso es
# suave y condicional ("...si aprendiste algo durable"), y el throttle fuerte evita que sea naggy.
#
# Throttle FUERTE: máx 1 aviso por DÍA por repo (stamp por-repo en ~/.claude/memory/.recordar-cosechar/).
# Escape: CLAUDE_SKIP_RECORDAR_COSECHAR=1.
# Fail-open SIEMPRE: no-git / sin jq / cualquier error → silencio, exit 0. NUNCA bloquea.
set -u

cat >/dev/null 2>&1 || true   # drenar stdin (contrato Stop)

[ "${CLAUDE_SKIP_RECORDAR_COSECHAR:-0}" = 1 ] && exit 0

ROOT="${CLAUDE_PROJECT_DIR:-$(git rev-parse --show-toplevel 2>/dev/null || echo "")}"
[ -n "$ROOT" ] && git -C "$ROOT" rev-parse --is-inside-work-tree >/dev/null 2>&1 || exit 0

# Solo aplica a repos con el sistema de memoria (donde vive el inbox de aprendizajes).
MEM="$ROOT/.claude/memory"
[ -d "$MEM" ] || exit 0
LOG_REL=".claude/memory/aprendizajes.md"

# ── Throttle por repo: máx 1 aviso por día ──
stampdir="$HOME/.claude/memory/.recordar-cosechar"; mkdir -p "$stampdir" 2>/dev/null || true
slug=$(printf '%s' "$ROOT" | cksum 2>/dev/null | awk '{print $1}')
stamp="$stampdir/${slug:-0}"
hoy=$(date +%Y-%m-%d 2>/dev/null || echo "")
[ -n "$hoy" ] || exit 0
if [ -f "$stamp" ]; then
  last=$(cat "$stamp" 2>/dev/null || echo "")
  [ "$last" = "$hoy" ] && exit 0   # ya avisamos hoy en este repo
fi

# ── ¿Hubo trabajo sustantivo reciente? ──
horas="${RECORDAR_COSECHAR_HORAS_TRABAJO:-6}"; case "$horas" in ''|*[!0-9]*) horas=6;; esac
trabajo=0
# (A) commits recientes
n_commits=$(git -C "$ROOT" log --oneline --since="$horas hours ago" 2>/dev/null | grep -c . || echo 0)
case "$n_commits" in ''|*[!0-9]*) n_commits=0;; esac
[ "$n_commits" -gt 0 ] && trabajo=1
# (B) cambios de código sin commitear en el working tree
if [ "$trabajo" -eq 0 ]; then
  if git -C "$ROOT" status --porcelain 2>/dev/null \
     | grep -qE '\.(cs|razor|ts|js|sh|py|sql|css|html)[[:space:]]*$'; then
    trabajo=1
  fi
fi
[ "$trabajo" -eq 0 ] && exit 0   # nada sustantivo → no molestamos

# ── ¿Se cosechó (se tocó aprendizajes.md)? ──
cosechado=0
# (i) commits recientes que tocaron el log
if git -C "$ROOT" log --oneline --since="$horas hours ago" -- "$LOG_REL" 2>/dev/null | grep -q .; then
  cosechado=1
fi
# (ii) el log está modificado sin commitear (cosecha en curso)
if [ "$cosechado" -eq 0 ] \
   && git -C "$ROOT" status --porcelain -- "$LOG_REL" 2>/dev/null | grep -q .; then
  cosechado=1
fi
[ "$cosechado" -eq 1 ] && exit 0   # ya cosechaste → silencio

# ── Avisar (gentil, no bloqueante) y marcar el throttle del día ──
printf '%s' "$hoy" > "$stamp" 2>/dev/null || true

ctx="🌾 Parece que trabajaste en este repo y no cosechaste aprendizajes hoy. Si aprendiste algo DURABLE (feedback del usuario, una lección de proceso, un gotcha no-obvio), corre \`/cosechar-sesion\` antes de cerrar para appendearlo al inbox del equipo (\`$LOG_REL\`). Si no hubo nada durable, ignórame. (Aviso suave, 1×/día por repo.)"
if command -v jq >/dev/null 2>&1; then
  jq -n --arg c "$ctx" '{hookSpecificOutput:{hookEventName:"Stop",additionalContext:$c}}'
else
  printf '%s\n' "$ctx"
fi
exit 0
