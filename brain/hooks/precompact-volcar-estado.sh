#!/usr/bin/env bash
# precompact-volcar-estado.sh — PreCompact hook. Se dispara JUSTO antes de compactar el
# contexto (trigger=auto cuando se llena; trigger=manual con /compact). La compactación
# borra el detalle del chat: este hook inyecta la orden de VOLCAR a la memoria cualquier
# avance/decisión/pendiente que aún no esté escrito, y le pide al resumen preservar el
# estado de la tarea. Junto con sesion-inicio.sh (que rehidrata en source=compact) cierra
# el hueco del "sprint demasiado largo". NO bloquea. Fail-open.
set -u
input=$(cat 2>/dev/null || true)
trigger=$(printf '%s' "$input" | { jq -r '.trigger // "auto"' 2>/dev/null || echo auto; })

ctx="⏳ COMPACTACIÓN DE CONTEXTO (${trigger}) — se va a perder el detalle del chat. ANTES de continuar, VUELCA a .claude/memory/estado-proyecto.md todo lo que aún no esté escrito de este sprint: qué quedó HECHO (con commit+fecha), qué está PENDIENTE (con punto de entrada al código) y qué está FUERA POR DECISIÓN (no es regresión). Si es migración, actualiza también docs/inventario-paridad.md (migrados/total). No confíes en recordarlo: escríbelo ahora. Al resumen: preserva la rama actual, la tarea en curso, el orden de capas pendiente y los archivos tocados."

if command -v jq >/dev/null 2>&1; then
  jq -n --arg c "$ctx" '{hookSpecificOutput:{hookEventName:"PreCompact",additionalContext:$c}}'
else
  printf '%s\n' "$ctx"
fi
exit 0
