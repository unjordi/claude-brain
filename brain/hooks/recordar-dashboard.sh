#!/usr/bin/env bash
# PreToolUse (matcher Bash): antes de un `git push`, recuerda (NO bloquea) actualizar
# el Dashboard del cerebro (memoria GLOBAL de esta maquina). Si no es git push, silencio.
cmd=$(jq -r '.tool_input.command // ""' 2>/dev/null)
# Ignora un 'git push' que aparezca como DATO entre comillas (un grep, la descripción de
# un MR, una cadena de prueba): quita los tramos entrecomillados antes de decidir, para
# reaccionar solo a un push REAL (sin comillas). Evita el falso positivo de meta-comandos.
unquoted=$(printf '%s' "$cmd" | sed "s/'[^']*'//g; s/\"[^\"]*\"//g")
if printf '%s' "$unquoted" | grep -qE 'git[[:space:]]+push'; then
  printf '%s' '{"hookSpecificOutput":{"hookEventName":"PreToolUse","additionalContext":"RECORDATORIO (cerebro autocontenido): antes de completar este push, revisa/actualiza el Dashboard del cerebro (dashboard_cerebro.md en la memoria GLOBAL de esta maquina: ~/.claude/projects/<slug-del-HOME>/memory/) — anade una linea a la Bitacora y ajusta Mapa/Infra/Cabos sueltos si cambio el layout de memoria, repos o proyectos de Claude. La memoria GLOBAL es solo config de ESTA maquina; lo de un proyecto vive en su .claude/."}}'
fi
exit 0
