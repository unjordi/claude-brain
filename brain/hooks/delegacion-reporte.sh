#!/usr/bin/env bash
# delegacion-reporte.sh — PostToolUse/Task: cierra el loop de la delegación SIN NIÑERA. Cuando un
# subagente (Task) termina, RECUERDA al orquestador registrar su avance y limpiar su rastro — para
# que el estado del proyecto no dependa de que el humano lo pida (hueco real: los agentes hacían el
# trabajo pero no reportaban; el humano tenía que monitorear a mano).
#
# NO bloquea (PostToolUse); solo inyecta contexto. Idempotente. Fail-open sin jq.
#
# Contrato (lo documenta la skill orquestar-fanout): el agente DEVUELVE {qué hizo · línea-de-bitácora
# curada · pendiente-para-otro · worktree limpio|dejado-con-<nota>}. El orquestador, al recibirlo:
#   (1) APPENDA una línea a .claude/memory/bitacora.md (append-only, merge=union → parallel-safe);
#   (2) actualiza/cierra el ítem en estado-proyecto.md (el BACKLOG VIVO = fuente de verdad);
#   (3) limpia el worktree del agente (rama mergeada) o anota su pendiente en la bitácora.
# DOS archivos, roles claros (sin redundancia de 3): estado-proyecto.md = presente+backlog vivo
# (curado, "aquí empiezas siempre"); bitacora.md = pasado append-only (aquí appendan los agentes).
# La lista de TodoWrite es SCRATCH de sesión — el backlog DURABLE es estado-proyecto.md.
set -u
command -v jq >/dev/null 2>&1 || exit 0
input=$(cat 2>/dev/null || true)
[ "$(printf '%s' "$input" | jq -r '.tool_name // empty' 2>/dev/null)" = "Task" ] || exit 0

msg="Un subagente (Task) TERMINÓ — punto de reporte, NO lo monitorees a mano. Antes de seguir:
1) BITÁCORA: appenda UNA línea a .claude/memory/bitacora.md (append-only) con qué cambió + su pendiente si dejó algo.
2) BACKLOG VIVO: actualiza/cierra en .claude/memory/estado-proyecto.md el ítem que le asignaste (esa es la fuente de verdad: dónde estamos + backlog + prioridad). NO dupliques el mismo dato en 3 lados: bitácora=qué pasó, estado-proyecto=qué sigue.
3) WORKTREE: si dejó uno de una rama YA mergeada, límpialo (corre 'limpiar-worktrees.sh'); si la rama sigue viva o quedó algo a medias, deja el pendiente anotado en la bitácora para quien lo retome."

jq -n --arg m "$msg" '{hookSpecificOutput:{hookEventName:"PostToolUse",additionalContext:$m}}'
exit 0
