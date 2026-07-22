#!/usr/bin/env bash
# test del hook usar-pkexec-y-git-ssh.sh — corre casos y verifica deny/nudge/silencio.
set -u
H="$(dirname "$0")/usar-pkexec-y-git-ssh.sh"
pass=0; fail=0

# $1 desc · $2 json de entrada · $3 = deny|nudge|silent (lo esperado)
check() {
  local desc="$1" in_json="$2" want="$3" out got
  out=$(printf '%s' "$in_json" | bash "$H" 2>/dev/null)
  if   printf '%s' "$out" | grep -Eq '"permissionDecision":[[:space:]]*"deny"'; then got=deny
  elif printf '%s' "$out" | grep -q 'additionalContext'; then got=nudge
  elif [ -z "$out" ]; then got=silent
  else got="otro:$out"; fi
  if [ "$got" = "$want" ]; then pass=$((pass+1)); printf '  ✔ %s\n' "$desc"
  else fail=$((fail+1)); printf '  ✘ %s  (esperado %s, obtuve %s)\n' "$desc" "$want" "$got"; fi
}

pre(){ printf '{"hook_event_name":"PreToolUse","tool_input":{"command":%s}}' "$(jq -Rn --arg c "$1" '$c')"; }
# post <salida> <comando> : el nudge ahora exige que el comando sea git/gh/glab
post(){ printf '{"hook_event_name":"PostToolUse","tool_input":{"command":%s},"tool_response":%s}' "$(jq -Rn --arg c "${2:-git push}" '$c')" "$(jq -Rn --arg c "$1" '$c')"; }

echo "PreToolUse (sudo → deny; pkexec/otros → silent):"
check "sudo al inicio"                "$(pre 'sudo ufw allow 8007/tcp')"            deny
check "sudo tras &&"                  "$(pre 'cd /x && sudo systemctl restart x')"  deny
check "sudo tras ;"                   "$(pre 'echo hi; sudo rm -rf /x')"            deny
check "pkexec NO bloquea"             "$(pre 'pkexec ufw allow 8007/tcp')"          silent
check "mención de sudo entre comillas" "$(pre 'echo "antes usabas sudo aquí"')"     silent
check "comando normal"                "$(pre 'git status')"                         silent

echo "PostToolUse (firma askpass/https EN comando git → nudge; si no es git o es benigno → silent):"
check "git + ksshaskpass"       "$(post 'error: unable to read askpass response from /usr/bin/ksshaskpass' 'git push -u origin x')" nudge
check "git + could not read Password" "$(post "fatal: could not read Password for 'https://x@github.com'" 'git pull')" nudge
check "firma PERO comando NO-git (test que la menciona)" "$(post 'error ... ksshaskpass ...' 'bash test-usar-pkexec-y-git-ssh.sh')" silent
check "git con salida benigna"  "$(post 'develop al dia; nada que reportar' 'git status')"            silent

echo "---"
echo "PASS=$pass FAIL=$fail"
[ "$fail" -eq 0 ]
