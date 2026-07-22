#!/usr/bin/env bash
# usar-pkexec-y-git-ssh.sh — nudge de saliencia para DOS reglas de ESTA máquina (CachyOS/KDE)
# que ya viven en CLAUDE.md/memoria pero se olvidan en el momento (falla de saliencia, no de memoria):
#
#  1. PreToolUse/Bash: si el comando invoca `sudo` → BLOQUEA y redirige a `pkexec` (en esta máquina
#     sudo sin TTY se cuelga; pkexec saca el diálogo KDE = confirmación del usuario). Memoria
#     `usar-pkexec-para-root`.
#  2. PostToolUse/Bash: si la SALIDA trae la firma de `ksshaskpass` / password de git por HTTPS →
#     recuerda cambiar el remote a SSH. Memoria `git-remoto-ssh-nunca-askpass`.
#
# Fuente única de estas reglas = las memorias globales; este hook solo las DISPARA en el instante.
# Fail-open ante cualquier ambigüedad (nunca estorba de más). Vive SOLO en ~/.claude (regla de máquina,
# no de template: pkexec/KDE es específico de esta compu; no aplica a compañeros en Windows/otros SO).

command -v jq >/dev/null 2>&1 || exit 0
input=$(cat)
event=$(printf '%s' "$input" | jq -r '.hook_event_name // empty' 2>/dev/null)

case "$event" in
  PreToolUse)
    cmd=$(printf '%s' "$input" | jq -r '.tool_input.command // empty' 2>/dev/null)
    [ -z "$cmd" ] && exit 0
    # `sudo` como INVOCACIÓN (inicio, o tras ; & | && || paréntesis), no dentro de comillas/como texto.
    if printf '%s' "$cmd" | grep -Eq '(^|[;&|(]|&&|\|\|)[[:space:]]*sudo[[:space:]]'; then
      jq -n '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:"deny",permissionDecisionReason:"REGLA DE ESTA MÁQUINA (CachyOS/KDE): no uses `sudo` — sin TTY se cuelga. Usa `pkexec <cmd>` TÚ MISMO (saca el diálogo gráfico de KDE que unjordi autoriza; ESA es la confirmación). NO se lo pases al usuario, NO trates \"necesito root\" como bloqueo. pkexec NO tiene --noconfirm. Ver memoria usar-pkexec-para-root."}}'
      exit 0
    fi
    exit 0
    ;;
  PostToolUse)
    # Solo aplica si el COMANDO fue una operación git/gh/glab (evita disparar sobre salidas que
    # solo MENCIONAN las cadenas —p. ej. un test de este mismo hook—; era el falso positivo).
    cmd=$(printf '%s' "$input" | jq -r '.tool_input.command // empty' 2>/dev/null)
    printf '%s' "$cmd" | grep -Eq '(^|[;&|(]|&&|\|\|)[[:space:]]*(git|gh|glab)[[:space:]]' || exit 0
    # La salida del Bash puede venir como string o como objeto {stdout,stderr}.
    out=$(printf '%s' "$input" | jq -r '[.tool_response, .tool_response.stdout?, .tool_response.stderr?, .tool_response.output?] | map(select(type=="string")) | join("\n")' 2>/dev/null)
    [ -z "$out" ] && exit 0
    if printf '%s' "$out" | grep -Eqi 'ksshaskpass|could not read (Password|Username)|read askpass response|terminal prompts disabled.*[Pp]assword|Authentication failed for .https'; then
      jq -n '{hookSpecificOutput:{hookEventName:"PostToolUse",additionalContext:"NUDGE (git en esta máquina): ese fallo es el diálogo ksshaskpass de un remote HTTPS, que NO sirve en sesiones de Claude. NO reintentes con askpass. Cambia el remote a SSH y reintenta:  git remote set-url origin git@github.com:<owner>/<repo>.git  (GitLab: git@gitlab.com:…). Ver memoria git-remoto-ssh-nunca-askpass."}}'
      exit 0
    fi
    exit 0
    ;;
  *)
    exit 0
    ;;
esac
