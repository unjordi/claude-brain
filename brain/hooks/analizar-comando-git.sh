# analizar-comando-git.sh — LIB compartida (NO es un hook; se hace `source`). Razona sobre un comando
# git/glab/gh para los git-guards (git-branch-guard · merge-squash-guard · confirmar-merge-develop) →
# UNA sola lógica, dejan de divergir (antídoto al drift H2/H13). bash-3.2-safe. El consumidor verifica
# jq/git si los necesita. Vive junto a los hooks (como delegacion-comun.sh) → viaja en el mismo copy.
# shellcheck shell=bash

# Quita literales entre comillas simples o dobles → un "git push a develop" dentro de un mensaje de
# commit / dato de un grep / doc NO dispara los guards. (Fix #2 · H13.)
acg_despoja_comillas() { printf '%s' "$1" | sed "s/'[^']*'//g; s/\"[^\"]*\"//g"; }

# Quita el VALOR de --repo/-R (p. ej. "-R org/develop") para que un repo cuyo nombre termine en
# /develop|/main NO genere un falso positivo de destino. (H11.)
acg_sin_flag_repo() { printf '%s' "$1" | sed -E 's/(--repo|-R)[[:space:]=]+[^[:space:]]+//g'; }

# Raíz y rama actual del repo del PROYECTO (CLAUDE_PROJECT_DIR), no del cwd del hook.
acg_rama_actual() { git -C "${CLAUDE_PROJECT_DIR:-.}" rev-parse --abbrev-ref HEAD 2>/dev/null; }

# ¿el comando contiene un `git push`?
acg_es_push() { printf '%s' "$1" | grep -qE 'git[[:space:]]+push([[:space:]]|$)'; }

# ¿nombra develop/main como DESTINO explícito del push, en el MISMO segmento (no cruza ; && ||),
# precedido por espacio/:/'/' (no matchea feat/develop-x)?
acg_push_destino_base() {
  printf '%s' "$1" | grep -qE 'git[[:space:]]+push[^;&|]*[[:space:]:/](main|develop)([[:space:]]|$)'
}

# ¿el push va SIN un refspec de rama explícito? (pelón, o solo remoto, o `HEAD` → empuja la RAMA
# ACTUAL). Heurística: tras `git push`, quitando opciones (-x/--x/--x=val) y `HEAD`, quedan ≤1
# posicionales (a lo más el remoto). (H1.)
acg_push_sin_refspec() {
  local seg rest tok posargs=0
  seg=$(printf '%s' "$1" | grep -oE 'git[[:space:]]+push[^;&|]*' | head -1)
  [ -n "$seg" ] || return 1
  rest=$(printf '%s' "$seg" | sed -E 's/^git[[:space:]]+push[[:space:]]*//; s/(-o|--push-option)[[:space:]=]+[^[:space:]]+//g')
  for tok in $rest; do
    case "$tok" in
      -*)   : ;;                       # opción → ignora
      HEAD) : ;;                       # HEAD = la rama actual, no un destino explícito
      *)    posargs=$((posargs+1)) ;;  # posicional (remoto o refspec de rama)
    esac
  done
  [ "$posargs" -le 1 ]
}

# ¿el comando EMPUJARÍA a develop/main? — explícito (nombra la rama) O pelón estando parado en
# develop/main. Opera sobre el cmd SIN comillas ni --repo. Cierra H1 (+ H11/H13). Requiere git para
# el caso pelón; sin git cae a fail-open en ese caso (backstop = ramas protegidas server-side).
acg_push_toca_base() {
  local u; u=$(acg_sin_flag_repo "$(acg_despoja_comillas "$1")")
  acg_es_push "$u" || return 1
  acg_push_destino_base "$u" && return 0
  if acg_push_sin_refspec "$u"; then
    case "$(acg_rama_actual)" in main|develop) return 0 ;; esac
  fi
  return 1
}

# ¿el comando mergea un MR/PR nombrando develop·main como destino? (para el bloqueo de release-a-main
# de git-branch-guard: mismo comportamiento de antes, pero sobre cmd sin comillas ni --repo → H11/H13).
acg_merge_menciona_base() {
  local u; u=$(acg_sin_flag_repo "$(acg_despoja_comillas "$1")")
  printf '%s' "$u" | grep -qE '(glab[[:space:]]+mr[[:space:]]+merge|gh[[:space:]]+pr[[:space:]]+merge)[^;&|]*[[:space:]:/](main|develop)([[:space:]]|$)'
}

# ¿el comando EJECUTA una integración REAL de MR/PR (server-side), no ayuda/inspección? Reconoce el
# subcomando REAL `glab mr (merge|accept)` / `gh pr merge`. Antídoto a H3: el viejo escape de
# confirmar-merge-develop casaba `status|list|view` como TOKEN SUELTO en CUALQUIER parte del comando,
# así que `glab mr merge 5 --yes && git status` evadía el gate (el `status` del OTRO comando encadenado
# disparaba el escape). Aquí solo `--help`/`-h`/`--dry-run` (inspección genuina) NO cuentan como merge;
# `glab mr list|view`/`gh pr view` tampoco disparan porque no matchean merge|accept. Sobre cmd sin
# comillas ni --repo (H11/H13). Un `git merge` LOCAL no matchea → sigue libre.
acg_es_merge_mr() {
  local u; u=$(acg_sin_flag_repo "$(acg_despoja_comillas "$1")")
  printf '%s' "$u" | grep -qE '(glab[[:space:]]+mr[[:space:]]+(merge|accept)|gh[[:space:]]+pr[[:space:]]+merge)([[:space:]]|$)' || return 1
  printf '%s' "$u" | grep -qE '(^|[[:space:]])(--help|-h|--dry-run)([[:space:]]|$)' && return 1
  return 0
}

# Corre un comando acotado por TIMEOUT (segundos). Usa timeout/gtimeout si existen (Linux, Git Bash,
# macOS con coreutils); si no, un fallback bash puro (corre en bg, un watcher lo mata si excede). Meta:
# que la consulta de red NUNCA cuelgue al hook hasta que el CLI lo mate → evita el fail-open por MUERTE
# del proceso (H5). El watcher redirige su stdout a /dev/null para no retener el pipe hacia jq.
acg__run_timeout() {
  local secs="$1"; shift
  if command -v timeout  >/dev/null 2>&1; then timeout  "$secs" "$@"; return $?; fi
  if command -v gtimeout >/dev/null 2>&1; then gtimeout "$secs" "$@"; return $?; fi
  local pid w rc
  "$@" & pid=$!
  ( sleep "$secs"; kill -TERM "$pid" 2>/dev/null ) >/dev/null 2>&1 & w=$!
  wait "$pid" 2>/dev/null; rc=$?
  kill -TERM "$w" 2>/dev/null; wait "$w" 2>/dev/null
  return "$rc"
}

# Resuelve el target_branch de un MR/PR (glab/gh) para decidir el destino del merge, con:
#  - CACHÉ por (repo,herramienta,mr-id) en TMPDIR → COMPARTIDA entre merge-squash-guard y
#    confirmar-merge-develop: el MISMO `glab mr merge` los dispara a AMBOS ⇒ misma clave ⇒ una sola
#    llamada de red en lugar de dos idénticas (H5). Solo cachea un resultado NO vacío (un vacío por
#    timeout/error se reintenta la próxima).
#  - TIMEOUT interno corto (ACG_MR_TIMEOUT, default 6s < el timeout del hook en settings.json: 10s/15s)
#    para que el proceso SIEMPRE termine y EMITA su decisión, en vez de que el CLI lo mate por colgarse
#    y trate el merge como "sin deny" (fail-open por muerte del proceso, H5).
# Devuelve el destino por stdout (vacío si no se pudo resolver → el consumidor aplica SU fail-policy:
# confirmar trata vacío como develop = pide OK; squash trata !develop = no fuerza, para no aplastar un
# release por no resolver). Requiere jq (sin jq devuelve vacío).
ACG_MR_TIMEOUT="${ACG_MR_TIMEOUT:-6}"
acg_destino_de_mr() {
  command -v jq >/dev/null 2>&1 || return 0
  local raw="$1" u tool repo mrid key cache dest
  u=$(acg_despoja_comillas "$raw")
  if printf '%s' "$u" | grep -qE 'glab[[:space:]]+mr'; then tool=glab; else tool=gh; fi
  repo=$(printf '%s' "$raw" | grep -oE '(--repo|-R)[[:space:]=]+[^[:space:]]+' | grep -oE '[^[:space:]=]+$')
  [ -z "$repo" ] && repo=$(git -C "${CLAUDE_PROJECT_DIR:-.}" remote get-url origin 2>/dev/null | sed -E 's#^(git@[^:]+:|https?://[^/]+/)##; s#\.git$##')
  mrid=$(printf '%s' "$u" | grep -oE '(mr[[:space:]]+(merge|accept)|pr[[:space:]]+merge)[[:space:]]+#?[0-9]+' | grep -oE '[0-9]+$')
  [ -n "$mrid" ] || return 0
  key=$(printf '%s' "${repo}|${tool}|${mrid}" | sed 's/[^A-Za-z0-9]/_/g')
  cache="${TMPDIR:-/tmp}/acg-mrdest-${key}"
  if [ -f "$cache" ]; then cat "$cache"; return 0; fi
  if [ "$tool" = glab ]; then
    dest=$(acg__run_timeout "$ACG_MR_TIMEOUT" glab api "projects/:id/merge_requests/$mrid" ${repo:+-R "$repo"} 2>/dev/null | jq -r '.target_branch // empty' 2>/dev/null)
  else
    dest=$(acg__run_timeout "$ACG_MR_TIMEOUT" gh pr view "$mrid" ${repo:+-R "$repo"} --json baseRefName -q .baseRefName 2>/dev/null)
  fi
  if [ -n "$dest" ]; then
    printf '%s' "$dest" > "$cache" 2>/dev/null
    printf '%s' "$dest"
  fi
  return 0
}
