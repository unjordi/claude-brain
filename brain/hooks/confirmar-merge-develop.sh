#!/usr/bin/env bash
# confirmar-merge-develop.sh — PreToolUse/Bash: EXIGE confirmación EXPRESA del usuario antes de
# INTEGRAR a develop/main por MR. Hace cumplir, en el punto exacto del merge, la definición de LISTO.
#
# Modelo "MINI-DEVELOP-por-dev" (acordado con el usuario):
#   - Cada dev trabaja en su rama personal de integración `Develop<Usuario>` (p. ej.
#     `DevelopAna`, `DevelopBeto`, `carlos`…): sus ramitas de feature se mergean AHÍ de forma CONTINUA y sin
#     drama — este candado NO las intercepta. Igual las ramas `epic/*`, `integracion/*` y demás.
#   - El ÚNICO cruce que pasa por este candado es integrar al `develop` COMPARTIDO (o promover a
#     `main`) vía MR (`glab mr merge|accept` / `gh pr merge`, incluido armar `--auto-merge`):
#     BLOQUEA salvo que en el contexto reciente haya una MARCA de confirmación/autorización expresa
#     del usuario para ESE cierre.
#
# ALCANCE: SOLO repos COMPARTIDOS (marca `.claude/repo-compartido`, viaja por git). En repos
# personales/solo (sin la marca) NO gatea nada → cero fricción ahí; ese caso lo cuidan git-branch-guard
# (no push directo a develop/main) + merge-squash-guard. `git merge` LOCAL a cualquier rama tampoco se
# intercepta. Complementa a git-branch-guard y merge-squash-guard (exige --squash a develop). Fail-open sin jq.
set -u
# dedupe doble-cableado: si soy la copia del REPO y la copia GLOBAL existe, cedo (la global maneja
# esta invocación) → evita disparo doble (y doble llamada de red) en máquina con el cerebro global;
# en un clon SIN bootstrap la del repo sí corre. NO-debilitante: sigue exigiendo el OK igual.
case "$0" in "$HOME/.claude/hooks/"*) : ;; *) [ -f "$HOME/.claude/hooks/$(basename "$0")" ] && exit 0 ;; esac
input=$(cat 2>/dev/null || true)
command -v jq >/dev/null 2>&1 || exit 0
cmd=$(printf '%s' "$input" | jq -r '.tool_input.command // empty' 2>/dev/null)
[ -z "$cmd" ] && exit 0

# shellcheck source=analizar-comando-git.sh
. "$(dirname "$0")/analizar-comando-git.sh"

# ¿Es una INTEGRACIÓN server-side de MR/PR REAL? (git merge local NO cuenta → iterar en integración es
# libre; ayuda/inspección tampoco). La lib ancla el reconocimiento al subcomando real → un token suelto
# de OTRO comando encadenado (`glab mr merge 5 --yes && git status`) YA NO evade el gate (H3).
acg_es_merge_mr "$cmd" || exit 0

# ALCANCE: solo repos COMPARTIDOS. Sin la marca `.claude/repo-compartido` (que viaja por git en los
# repos de equipo), este candado no aplica → repos personales/solo mergean a su develop sin pedir OK.
[ -f "${CLAUDE_PROJECT_DIR:-.}/.claude/repo-compartido" ] || exit 0

# DESTINO del merge: main = RELEASE (autorización SUPER explícita); develop/otro = confirmación normal.
# Lo resuelve la lib (acg_destino_de_mr): caché por MR-id COMPARTIDA con merge-squash-guard (típicamente
# 1 llamada de red, no 2; no es lock) + timeout interno para no fallar-abierto por muerte del proceso (H5).
# FAIL-SAFE: si no podemos determinar el destino (vacío por timeout/error), se trata como develop (conservador → pide OK).
destino=$(acg_destino_de_mr "$cmd")

# Ramas personales de integración (Develop<Usuario>, epic/*, integracion/*, feat/*, fix/*…) reciben
# merge CONTINUO sin gate: ahí vive el día a día del modelo MINI-DEVELOP-por-dev. SOLO el `develop`
# COMPARTIDO y `main` piden confirmación. destino vacío/desconocido → conservador (se trata como develop).
if [ -n "$destino" ] && [ "$destino" != "develop" ] && [ "$destino" != "main" ]; then
  exit 0
fi

# Autorización reciente del usuario. Buscamos en los ÚLTIMOS ~10 MENSAJES DE USUARIO — NO en las
# últimas N líneas CRUDAS del transcript. Por qué: los recordatorios inyectados gigantes (additionalContext)
# y las salidas de tool NO son role=user, pero SÍ inflan el conteo de líneas → con una ventana de líneas
# crudas, un "mergea 222" real queda ENTERRADO fuera de la ventana y el guard da runaround (falso negativo,
# no que "no puedas"). Filtrar a mensajes de usuario y tomar los últimos 10 es inmune a ese ruido y sigue
# acotado por recencia (un OK de hace 20 turnos NO cuenta). tail -4000 solo acota el costo de leer.
recent=""
tpath=$(printf '%s' "$input" | jq -r '.transcript_path // empty' 2>/dev/null)
if [ -n "$tpath" ] && [ -f "$tpath" ]; then
  recent=$(tail -n 4000 "$tpath" 2>/dev/null | jq -rs '
    [ .[] | select((.message.role // .type)=="user")
          | ((.message.content // [.message])
             | if type=="array"
               then (map(if type=="string" then . elif (.type? == "text") then .text else "" end) | join(" "))
               else (. // "") end)
          | select(. != "") ]                 # descarta tool_result (mapea a "") → solo texto real del usuario
    | .[-10:] | join("  ")' 2>/dev/null)
fi

if [ "$destino" = "main" ]; then
  # RELEASE a main: exige autorización SUPER explícita de release. Un 'mergea' genérico (que vale
  # para develop) NO autoriza un release a main.
  RELEASE_RE='hasta main|\brelease\b|(a|hacia|hast[ao]) main|liber(a|ar|alo|é)|promue?v(e|er)[a-zé ]*main|merge[a-zé ]* a? *main'
  printf '%s' "$recent" | grep -qiE "$RELEASE_RE" && exit 0
  jq -n --arg r "FRENO (RELEASE a main): promover develop→main es una decisión de RELEASE que exige autorización SUPER explícita del usuario para ESTE release (p. ej. 'release a main', 'hasta main', 'libera'), y no la encuentro en el contexto reciente.
  (a) Si ya la dio, CÍTALA y reintenta.
  (b) main es release-only: un 'mergea' genérico (que vale para develop) NO autoriza un release a main. Los releases van SIN squash (conservan historia)." \
    '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:"deny",permissionDecisionReason:$r}}'
  exit 0
fi

# Destino develop (o desconocido → conservador): confirmación normal. "sigue/avanza" NO cuenta.
CONF_RE='merg[eé]a|mérga(lo|los)?|dale( el)? merge|haz(lo|le)?( el)? *merge|merge a develop|integra[a-zé ]*a? *develop|s[ií],? merge|ci[eé]rra(lo)?|cierra el slice|ll[eé]valo a develop|ya (puedes|podés|puedo) mergear|adelante[a-zé ]*(el )?merge|autoriz|luz verde (para|de|expresa)|visto bueno|aprob(ado|é|ó)?|va! *(merge|mr|develop|cierra)'
printf '%s' "$recent" | grep -qiE "$CONF_RE" && exit 0

jq -n --arg r "FRENO (definición de LISTO): integrar a develop por MR exige la confirmación EXPRESA del usuario para ESTE cierre, y no la encuentro en el contexto reciente.
  (a) Si ya te dio el OK explícito, CÍTALO y reintenta.
  (b) Para seguir iterando SIN fricción: trabaja en una rama de INTEGRACIÓN (integracion/<sprint> o epic/<tema>) y mergea las ramitas ahí con 'git merge' LOCAL (libre, no pasa por este candado); solo el MR de esa rama de integración → develop pasa por aquí.
Recuerda: verde técnico != LISTO; 'sigue/avanza' NO autoriza el merge a develop." \
  '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:"deny",permissionDecisionReason:$r}}'
exit 0
