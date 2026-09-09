#!/usr/bin/env bash
# secret-scan.sh — PreToolUse/Bash guard DEFENSIVO: bloquea un `git commit`/`git push` cuando el
# contenido que entra al repo trae un SECRETO (llave de API, token, clave privada). Antídoto al
# clásico "se me fue una credencial al repo" — el peor error, porque una vez pusheada ya está
# comprometida aunque la borres después.
#
# Alcance quirúrgico (evita falsos positivos y ruido):
#   - Solo actúa si el comando es un `git commit` o `git push` (cualquier otro Bash → pasa al instante).
#   - En commit escanea SOLO lo AGREGADO en el staging (`git diff --cached`, líneas `+`); en push, lo
#     que sale respecto al upstream (`@{u}..HEAD`). No escanea el árbol entero ni lo que ya existía.
#   - Patrones de ALTA precisión (prefijos/formatos inconfundibles): AWS AKIA, claves privadas PEM,
#     tokens de Anthropic/OpenAI/GitHub/GitLab/Slack/Google. NO usa heurística de entropía genérica
#     (que dispara con hashes, UUIDs, minified JS…). Precisión > exhaustividad: mejor no molestar.
#
# Escapes legítimos (el humano manda): `git ... --no-verify` (convención de git para saltar hooks) o
# el entorno `CLAUDE_SKIP_SECRET_SCAN=1`. Fail-open: sin jq / sin git / sin poder determinar el rango,
# NO bloquea (nunca frena trabajo por una duda de parseo; es una red de seguridad, no una cárcel).
#
# Vive en brain/hooks/ (fuente), se instala GLOBAL en ~/.claude/hooks/ (aplica a todos los repos).
set -u

# dedupe doble-cableado: si soy la copia del REPO y la copia GLOBAL existe, cedo (evita doble escaneo
# en máquina con el cerebro global; en un clon SIN bootstrap la del repo sí corre). Necesario ahora que
# secret-scan es tier `both` (viaja per-repo Y global). NO-debilitante: sigue escaneando 1× y denegando.
case "$0" in "$HOME/.claude/hooks/"*) : ;; *) [ -f "$HOME/.claude/hooks/$(basename "$0")" ] && exit 0 ;; esac

input=$(cat 2>/dev/null || true)
# Sin jq no podemos parsear el comando ni EMITIR un deny ESTRUCTURADO (el deny sale como JSON vía jq).
# Pero un guard DEFENSIVO NO calla: que la red de seguridad esté APAGADA debe ENTERARSE el operador, no
# un fail-open silencioso (antes: `exit 0` mudo → un commit/push entraba sin escaneo y STRICT se ignoraba
# por completo). Sin jq: (a) STRICT hace fail-CLOSED por `exit 2` (bloqueo que NO necesita jq); (b) si no,
# avisa RUIDOSO por stderr y deja pasar (default fail-open). Honra los escapes explícitos aun sin jq.
if ! command -v jq >/dev/null 2>&1; then
  [ "${CLAUDE_SKIP_SECRET_SCAN:-}" = "1" ] && exit 0
  case "$input" in *--no-verify*) exit 0 ;; esac   # escape crudo (superset; coherente con el fail-open)
  case "$input" in
    *git*commit*|*git*push*)
      if [ "${CLAUDE_SECRET_SCAN_STRICT:-0}" = "1" ]; then
        printf '%s\n' "FRENO DE SEGURIDAD (secret-scan STRICT): 'jq' no está instalado; no puedo escanear en busca de secretos antes de dejar entrar código y CLAUDE_SECRET_SCAN_STRICT=1 exige poder verificar. Instala jq (brew install jq / winget install jqlang.jq), o salta conscientemente con 'git … --no-verify' o CLAUDE_SKIP_SECRET_SCAN=1." >&2
        exit 2
      fi
      printf '%s\n' "⚠️ secret-scan: 'jq' no está instalado → este git commit/push NO se escaneó en busca de secretos (la red de seguridad está APAGADA). Instala jq para reactivarla; CLAUDE_SECRET_SCAN_STRICT=1 la volvería obligatoria." >&2
      ;;
  esac
  exit 0
fi

# DECISIÓN fail-open vs fail-closed (§D): por DEFAULT fail-OPEN ante fallo de INFRAESTRUCTURA (sin git, no
# es repo, no se puede determinar el rango del diff) — bloquear TODO commit por un problema de entorno es
# desproporcionado y este guard es "red de seguridad, no cárcel"; el backstop real es la rotación + gates
# server-side. Con CLAUDE_SECRET_SCAN_STRICT=1 el operador OPTA por fail-CLOSED: si no se puede escanear,
# se bloquea (postura conservadora para entornos sensibles). El default NO cambia el comportamiento previo.
STRICT="${CLAUDE_SECRET_SCAN_STRICT:-0}"
bail_open() {  # $1 = motivo. En strict → deny; si no → deja pasar (exit 0).
  if [ "$STRICT" = "1" ]; then
    jq -n --arg r "FRENO DE SEGURIDAD (secret-scan, modo STRICT): no pude escanear en busca de secretos ($1) y CLAUDE_SECRET_SCAN_STRICT=1 exige poder verificar antes de dejar entrar código. Resuelve la causa, o usa 'git … --no-verify' / CLAUDE_SKIP_SECRET_SCAN=1 para esta acción." \
      '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:"deny",permissionDecisionReason:$r}}'
  fi
  exit 0
}

cmd=$(printf '%s' "$input" | jq -r '.tool_input.command // empty' 2>/dev/null)
[ -z "$cmd" ] && exit 0

# PRE-FILTRO barato (superset conservador, mismo espíritu que proteger-arbol.sh): este guard solo actúa
# sobre `git commit`/`git push` → sin 'git' en el comando crudo, early-exit ANTES de cualquier
# normalización/despoja-comillas. Jamás salta un caso real.
case "$cmd" in *git*) : ;; *) exit 0 ;; esac

# Despoja literales entrecomillados ANTES de razonar sobre el comando: reusa acg_despoja_comillas de la
# lib compartida si está junto al hook, si no un sed equivalente. Así un token DENTRO de una comilla —el
# `--no-verify` citado en el MENSAJE del commit (A7), o un `git commit`/`git add`/`git push` mencionado en
# el texto— no altera la decisión del guard. bash-3.2-safe.
_ACGLIB="$(dirname "$0")/analizar-comando-git.sh"
# shellcheck source=analizar-comando-git.sh
[ -f "$_ACGLIB" ] && . "$_ACGLIB"
# A-03/A-R4-02 (FMEA): colapsa el prefijo de opciones globales de git (`-c k=v`, `-C dir`, `--no-pager`,
# `--work-tree`, …) para que `git <globales> commit` NO evada la adyacencia git+commit/push del gate (ese
# prefijo cegaba el escaneo). A-R5-02 (FMEA r5): se NORMALIZA SOBRE EL RAW (comillas intactas) ANTES de
# despojar — si se despoja primero, un value-eater con valor entrecomillado (`git -C "/ruta" commit`) queda
# vacío y el normalizador se come el subcomando `commit` → escaneo CIEGO. El normalizador es quote-aware
# (consume el valor entrecomillado con espacios como una unidad). Orden correcto: normaliza(raw) → despoja.
if command -v acg_normaliza_git_prefijo >/dev/null 2>&1; then
  cmd_norm=$(acg_normaliza_git_prefijo "$cmd")
else
  cmd_norm=$(printf '%s' "$cmd" | sed -E 's/(^|[^[:alnum:]._-])git\.exe([[:space:]])/\1git\2/g' | sed -E "s/git[[:space:]]+((((-c|-C|--exec-path|--git-dir|--work-tree|--namespace|--attr-source|--config-env|--super-prefix)([[:space:]]+|=)([^[:space:]\"']|\"[^\"]*\"|'[^']*'|\\\\.)+)|(--?[a-zA-Z][a-zA-Z-]*(=([^[:space:]\"']|\"[^\"]*\"|'[^']*'|\\\\.)+)?))[[:space:]]+)+/git /g")
fi
if command -v acg_despoja_comillas >/dev/null 2>&1; then
  cmd_uq=$(acg_despoja_comillas "$cmd_norm")
else
  cmd_uq=$(printf '%s' "$cmd_norm" | sed "s/'[^']*'//g; s/\"[^\"]*\"//g")
fi

# ¿Es un commit o un push? Si no, no es asunto de este guard (NO es "no poder escanear" → nunca strict-bloquea).
# LÍMITE CONOCIDO (A-07, FMEA): casa el subcomando LITERAL commit/push; un ALIAS de git del usuario (`git ci`,
# `git psh`) NO matchea → el guard queda inerte en ese caso. Cubrirlo genéricamente exigiría resolver los alias
# (`git config --get alias.*`) por-máquina; se documenta como límite aceptado (depende de config personal, no universal).
printf '%s' "$cmd_uq" | grep -qE 'git[[:space:]]+(commit|push)' || exit 0
# Escapes deliberados (el humano manda) — ganan incluso en strict.
[ "${CLAUDE_SKIP_SECRET_SCAN:-}" = "1" ] && exit 0
# --no-verify como BANDERA real (sobre el cmd despojado), no la palabra dentro del mensaje del commit (A7).
printf '%s' "$cmd_uq" | grep -qE '(^|[[:space:]])--no-verify([[:space:]]|$)' && exit 0

command -v git >/dev/null 2>&1 || bail_open "git no está en el PATH"
dir="${CLAUDE_PROJECT_DIR:-.}"
git -C "$dir" rev-parse --is-inside-work-tree >/dev/null 2>&1 || bail_open "no es un repo git ($dir)"

# shellcheck source=detectar-secretos.sh
. "$(dirname "$0")/detectar-secretos.sh"   # patrones + ds_buscar (lógica; §D)

# ¿El comando crea un commit? (sobre el cmd despojado). Si no, por el gate de arriba es un push puro.
has_commit=0; printf '%s' "$cmd_uq" | grep -qE 'git[[:space:]]+commit([[:space:]]|$)' && has_commit=1

# A1 · idiom `git add … && git commit` (o `;`, o …`&& git push`) en UN solo comando: en PreToolUse el
# `git add` AÚN NO corrió, así que el staging (`git diff --cached`) está VACÍO → el escaneo de commit
# sería CIEGO, y si además encadena un `&& git push` el bypass es TOTAL (ni commit ni push ven el
# secreto). Cuando el comando CREA un commit y encadena un `git add`, le preguntamos a git QUÉ estagearía
# ese add con `git add --dry-run` (NO muta el índice; resuelve -A/./-u/pathspecs por nosotros) y sumamos
# ESE contenido del working tree al escaneo.
addfiles=""
if [ "$has_commit" = 1 ] && printf '%s' "$cmd_uq" | grep -qE 'git[[:space:]]+add([[:space:]]|$)'; then
  # TODOS los segmentos `git add` del comando, NO solo el 1º: `git add safe && git add secret && git commit`
  # (un solo comando) estagearía AMBOS, pero el `head -1` anterior solo escaneaba `safe` → el secreto de
  # `secret` entraba (hueco real del audit-07, OK de unjordi). Iteramos cada `git add` y sumamos su dry-run.
  while IFS= read -r _addseg; do
    [ -n "$_addseg" ] || continue
    _aargs=$(printf '%s' "$_addseg" | sed -E 's/^git[[:space:]]+add[[:space:]]*//')
    _more=$(git -C "$dir" add --dry-run $_aargs 2>/dev/null | grep "^add '" | sed -E "s/^add '(.*)'\$/\1/")
    addfiles=$(printf '%s\n%s' "$addfiles" "$_more")
  done <<EOF
$(printf '%s' "$cmd_uq" | grep -oE 'git[[:space:]]+add[^;&|]*')
EOF
  addfiles=$(printf '%s\n' "$addfiles" | grep -vE '^[[:space:]]*$' | sort -u)
fi
# A1 (residuo `commit -a`/`-am`/`--all`): la bandera -a AUTO-ESTAGEA los tracked MODIFICADOS al crear el
# commit; en PreToolUse aún no corrió, así que --cached está VACÍO para ellos → el escaneo de commit sería
# CIEGO (mismo hueco que el `git add` encadenado, pero sin `git add` explícito). Detectamos -a/--all en el
# SEGMENTO del commit (cmd_uq ya despojó el mensaje entrecomillado, así que un "-a" en el texto no dispara)
# y sumamos los tracked modificados a addfiles → added_lines los lee con `git diff HEAD -- f` (rama tracked,
# sin re-escanear lo ya versionado). --diff-filter=ACMR: contenido que entra; D (borrados) no aporta secreto.
if [ "$has_commit" = 1 ]; then
  commit_seg=$(printf '%s' "$cmd_uq" | grep -oE 'git[[:space:]]+commit[^;&|]*' | head -1)
  if printf '%s' "$commit_seg" | grep -qE '(^|[[:space:]])(--all|-[a-z]*a[a-z]*)([[:space:]]|$)'; then
    tracked_mod=$(git -C "$dir" diff HEAD --name-only --diff-filter=ACMR 2>/dev/null)
    addfiles=$(printf '%s\n%s\n' "$addfiles" "$tracked_mod" | grep -vE '^$' | sort -u)
  fi
fi

# Modo del escaneo primario: si el comando crea un commit, escaneamos lo que ENTRARÁ con ese commit
# (staging + lo que el add encadenado agregaría) — el commit MANDA aunque también haya un push encadenado
# (así el `git add && git commit && git push` de un tirón no se cuela por la puerta del push, que en
# PreToolUse tampoco vería el commit nuevo). Solo un push PURO (sin commit) usa el rango @{u}..HEAD.
if [ "$has_commit" = 1 ]; then mode="commit"; else mode="push"; fi

added_lines() {  # imprime SOLO las líneas agregadas de un archivo (sin la cabecera +++).
  local f="$1"
  # Escaneo primario según el modo.
  if [ "$mode" = "commit" ]; then
    git -C "$dir" diff --cached -- "$f" 2>/dev/null | grep -E '^\+' | grep -vE '^\+\+\+'
  else
    git -C "$dir" diff "$BASE..HEAD" -- "$f" 2>/dev/null | grep -E '^\+' | grep -vE '^\+\+\+'
  fi
  # A1: + lo que el `git add` encadenado ESTAGEARÍA, si este archivo es uno de ellos.
  if printf '%s\n' "$addfiles" | grep -qxF "$f"; then
    if git -C "$dir" ls-files --error-unmatch -- "$f" >/dev/null 2>&1; then
      # tracked-modificado: solo lo AGREGADO vs HEAD (no re-escanear lo YA versionado → sin falso positivo).
      git -C "$dir" diff HEAD -- "$f" 2>/dev/null | grep -E '^\+' | grep -vE '^\+\+\+'
    else
      # NUEVO/untracked: TODO el archivo es contenido que entra al repo.
      git -C "$dir" diff --no-index -- /dev/null "$dir/$f" 2>/dev/null | grep -E '^\+' | grep -vE '^\+\+\+'
    fi
  fi
}

# Lista de archivos que cambian.
if [ "$mode" = "commit" ]; then
  # staged (--cached) ∪ lo que el `git add` encadenado agregaría (A1): un secreto en un archivo AÚN NO
  # staged (untracked/nuevo) no aparece en --cached, lo aporta addfiles.
  files=$(printf '%s\n%s\n' "$(git -C "$dir" diff --cached --name-only --diff-filter=ACM 2>/dev/null)" "$addfiles" | grep -vE '^$' | sort -u)
else
  BASE=$(git -C "$dir" rev-parse --abbrev-ref --symbolic-full-name '@{u}' 2>/dev/null)
  if [ -z "$BASE" ]; then
    # G5: rama NUEVA sin upstream (el 1er push — donde más se cuela un secreto, porque toda la historia
    # de la rama es nueva). Antes: sin upstream → fail-open (no escaneaba nada). Ahora escanea lo que la
    # rama AGREGA sobre la base de integración: el merge-base con develop/main (remotas primero, luego
    # locales). Así el primer push SÍ se revisa.
    for ref in origin/develop origin/main develop main; do
      git -C "$dir" rev-parse --verify --quiet "$ref" >/dev/null 2>&1 || continue
      BASE=$(git -C "$dir" merge-base HEAD "$ref" 2>/dev/null)
      [ -n "$BASE" ] && break
    done
    [ -z "$BASE" ] && bail_open "sin upstream ni base develop/main para acotar el rango del push"
  fi
  files=$(git -C "$dir" diff "$BASE..HEAD" --name-only --diff-filter=ACM 2>/dev/null)
fi
[ -z "$files" ] && exit 0

hits=""
while IFS= read -r f; do
  [ -z "$f" ] && continue
  red=$(ds_buscar "$(added_lines "$f")" | tr '\n' ' ')   # ds_buscar ya redacta y excluye placeholders (lib)
  if [ -n "$red" ]; then
    hits="${hits}
  • ${f}: ${red}"
  fi
done <<EOF
$files
EOF

[ -z "$hits" ] && exit 0

reason="FRENO DE SEGURIDAD (secret-scan): detecté lo que parece un SECRETO en lo que va a entrar al repo (${mode}). NO lo subas: una credencial pusheada queda comprometida aunque la borres.
Coincidencias (redactadas):${hits}
Qué hacer:
  1) Saca el secreto del código → muévelo a una variable de entorno / gestor de secretos / archivo *.local ignorado por git.
  2) Si ya estaba commiteado antes, ROTA la credencial (dala por comprometida).
  3) Si es un FALSO POSITIVO (placeholder/ejemplo), reintenta con 'git ... --no-verify' o exporta CLAUDE_SKIP_SECRET_SCAN=1 para esta acción."

jq -n --arg r "$reason" '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:"deny",permissionDecisionReason:$r}}'
exit 0
