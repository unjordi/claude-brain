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
# Sin jq NO podemos ni parsear el comando ni EMITIR un deny (el deny es JSON vía jq) → fail-open forzoso
# (no hay forma de bloquear limpio). Es una limitación real, no una elección; documentada.
command -v jq >/dev/null 2>&1 || exit 0

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

# ¿Es un commit o un push? Si no, no es asunto de este guard (NO es "no poder escanear" → nunca strict-bloquea).
printf '%s' "$cmd" | grep -qE 'git[[:space:]]+(commit|push)' || exit 0
# Escapes deliberados (el humano manda) — ganan incluso en strict.
[ "${CLAUDE_SKIP_SECRET_SCAN:-}" = "1" ] && exit 0
printf '%s' "$cmd" | grep -qE '(^|[[:space:]])--no-verify([[:space:]]|$)' && exit 0

command -v git >/dev/null 2>&1 || bail_open "git no está en el PATH"
dir="${CLAUDE_PROJECT_DIR:-.}"
git -C "$dir" rev-parse --is-inside-work-tree >/dev/null 2>&1 || bail_open "no es un repo git ($dir)"

# shellcheck source=detectar-secretos.sh
. "$(dirname "$0")/detectar-secretos.sh"   # patrones + ds_buscar (lógica; §D)

# ¿Estamos en commit o en push? Define de dónde sacar el diff de lo que ENTRA al repo.
mode="commit"
printf '%s' "$cmd" | grep -qE 'git[[:space:]]+push' && mode="push"

added_lines() {  # imprime SOLO las líneas agregadas de un archivo (sin la cabecera +++).
  local f="$1"
  if [ "$mode" = "commit" ]; then
    git -C "$dir" diff --cached -- "$f" 2>/dev/null
  else
    git -C "$dir" diff "$BASE..HEAD" -- "$f" 2>/dev/null
  fi | grep -E '^\+' | grep -vE '^\+\+\+'
}

# Lista de archivos que cambian.
if [ "$mode" = "commit" ]; then
  files=$(git -C "$dir" diff --cached --name-only --diff-filter=ACM 2>/dev/null)
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
