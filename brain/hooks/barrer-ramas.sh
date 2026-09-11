#!/usr/bin/env bash
# barrer-ramas.sh — hook (tier GLOBAL) que da TRIGGER al barrido de ramas locales ya integradas, por DOS
# vías complementarias que comparten el MISMO barredor (`limpiar-ramas.sh`) y la misma noción de "zombie":
#
#   (A) SessionStart 🔔  — OPORTUNISTA: al abrir/retomar sesión en un repo git, como mucho una vez por
#       BARRER_RAMAS_HORAS (default 24). Backstop del "volví al día siguiente".
#   (B) PostToolUse/Bash 🎯 — AL PUNTO DE MERGE: justo después de que Claude corre `glab mr merge|accept`
#       o `gh pr merge` (lo detecta la lib analizar-comando-git.sh → acg_es_merge_mr), lanza el barrido
#       DE INMEDIATO. Es el momento EXACTO en que nace un zombie: el MR se mergea con --squash, la remota
#       se borra (--delete-branch) y la rama LOCAL queda `: gone` sin que `git branch -d` la reconozca.
#       Con un debounce corto (BARRER_RAMAS_MERGE_DEBOUNCE, default 30s) para no lanzar N barridos en una
#       ráfaga de merges — cada barrido ya limpia TODOS los zombies de una pasada.
#
# En ambas vías el barrido es EN SEGUNDO PLANO (nohup, no bloquea): la detección de "remota borrada" hace
# un `ls-remote` POR rama candidata (red) y colgaría el arranque de sesión / el turno. Es SEGURO por
# construcción (solo borra zombies; CONSERVA ante cualquier duda) → no pide confirmación por corrida.
#
# Por qué EXISTE (unjordi, 2026-07-21): `limpiar-ramas` es kind=script en el MANIFEST → se INSTALA pero
# nadie lo DISPARA; las ramas squasheadas se acumulaban (un repo llegó a 60+). "Norma sin mecanismo = buen
# deseo": este hook es el mecanismo. La vía (B) se añadió (2026-08-07, #53) porque la (A) solo barría al
# ABRIR sesión y con throttle de 24h → tras mergear seguías viendo la rama muerta hasta la siguiente
# sesión; ahora se barre en el instante del merge, que es cuando el zombie aparece.
#
# INDEPENDENCIA de las dos vías (a propósito): NO comparten throttle. (B) NO toca el stamp de 24h de (A)
# → así (A) sigue siendo un backstop fiable aunque (B) haya corrido (p. ej. `--auto-merge` encola el
# merge pero no integra al instante → (B) barre y CONSERVA la rama aún viva; (A) la caza cuando de verdad
# quede integrada). Dos barridos concurrentes sobre el mismo repo son SEGUROS: el borrado es por-rama y
# atómico, `git branch -D` no toma `.git/index.lock`; una colisión sobre packed-refs.lock degrada sin
# corromper y se reintenta. (Misma lógica de independencia que con aviso-drift-cerebro, ver abajo.)
#
# CONCURRENCIA con aviso-drift-cerebro (el OTRO SessionStart que MUTA git): en el mismo SessionStart,
# aviso-drift puede hacer commit+push en la rama ACTUAL (una mini-develop Develop*), mientras este barrido
# detached hace `git branch -d/-D` de ramas ZOMBIE. Operan sobre refs DISJUNTOS: limpiar-ramas NUNCA toca
# actual/base/develop/main/Develop*/keep/* (justo las que aviso-drift commitea). Fail-open ambos → una
# colisión degrada sin corromper.
#
# ORDEN A-5 (auditoría 2026-09-11): las dos herramientas antes se lanzaban EN PARALELO (`&` cada una) —
# limpiar-ramas fotografía qué ramas siguen checked-out en un worktree AL ARRANCAR; si limpiar-worktrees
# libera un worktree zombie DESPUÉS de esa foto, la rama que retenía queda protegida un ciclo entero (con
# BARRER_RAMAS_HORAS=24, hasta 2 días para que una rama muera). El ciclo rama↔worktree solo converge en
# UNA pasada si primero se libera el worktree y LUEGO se barren las ramas — por eso `lanzar()` ahora los
# corre SECUENCIALES (mismo proceso en background, sin paralelismo entre ellos).
#
# Escape: CLAUDE_SKIP_BARRER_RAMAS=1. Fail-open SIEMPRE: no-git / sin remoto / sin limpiar-ramas / sin jq
# (vía B) / cualquier error → silencio, exit 0.
set -u

input=$(cat 2>/dev/null || true)   # drenar+capturar stdin (SessionStart trae {source}; PostToolUse {tool_*})

[ "${CLAUDE_SKIP_BARRER_RAMAS:-0}" = 1 ] && exit 0

# jq es OPCIONAL para la vía (A) (fallback a texto plano), pero OBLIGATORIO para la (B) (hay que parsear el
# comando). ¿Qué evento nos disparó? El payload de PostToolUse/Bash trae `.tool_name`; el de SessionStart no.
have_jq=0; command -v jq >/dev/null 2>&1 && have_jq=1
tool_name=""; [ "$have_jq" = 1 ] && tool_name=$(printf '%s' "$input" | jq -r '.tool_name // empty' 2>/dev/null)

# ── Vía (B): gate de MERGE. Si nos disparó un Bash, solo seguimos si el comando fue un merge de MR/PR.
#    Cualquier otro Bash (la inmensa mayoría) → silencio inmediato, sin tocar red ni git.
es_merge=0
if [ "$tool_name" = "Bash" ]; then
  cmd=$(printf '%s' "$input" | jq -r '.tool_input.command // empty' 2>/dev/null)
  ACG="$(dirname "$0")/analizar-comando-git.sh"
  # shellcheck source=analizar-comando-git.sh
  { [ -n "$cmd" ] && [ -f "$ACG" ] && . "$ACG" && acg_es_merge_mr "$cmd"; } || exit 0
  es_merge=1
fi

# ── Comunes a ambas vías: repo git con remoto y el barredor instalado a un lado (kind=script → misma carpeta).
ROOT="${CLAUDE_PROJECT_DIR:-$(git rev-parse --show-toplevel 2>/dev/null || echo "")}"
{ [ -n "$ROOT" ] && git -C "$ROOT" rev-parse --is-inside-work-tree >/dev/null 2>&1; } || exit 0
git -C "$ROOT" remote | grep -q . 2>/dev/null || exit 0   # sin remoto no hay ramas squasheadas-y-borradas
LIMPIAR="$(dirname "$0")/limpiar-ramas.sh"
[ -f "$LIMPIAR" ] || exit 0
# 1b — al punto del merge nace TANTO un ramo local zombie COMO (tras un fan-out) un worktree zombie. Ambos
# barredores comparten la MISMA lib de "zombie" (ramas-zombie.sh) → misma decisión, sin divergencia. El de
# worktrees es OPCIONAL (un clon podría no traerlo): si está a un lado, se lanza junto al de ramas.
LIMPIAR_WT="$(dirname "$0")/limpiar-worktrees.sh"

stampdir="$HOME/.claude/memory/.barrer-ramas"; mkdir -p "$stampdir" 2>/dev/null || true
slug=$(printf '%s' "$ROOT" | cksum 2>/dev/null | awk '{print $1}'); slug="${slug:-0}"
now=$(date +%s)
log="$stampdir/${slug}.log"
logwt="$stampdir/${slug}.worktrees.log"
lanzar() {
  # A-5: SECUENCIAL, no paralelo — limpiar-worktrees PRIMERO (libera worktrees zombie, con eso las ramas
  # que retenían dejan de estar protegidas) y limpiar-ramas DESPUÉS, en la MISMA pasada. Sigue siendo
  # background (nohup … &): no bloquea el turno ni el arranque de sesión.
  if [ -f "$LIMPIAR_WT" ]; then
    ( cd "$ROOT" && nohup bash -c 'bash "$1" >"$2" 2>&1; bash "$3" >"$4" 2>&1' _ "$LIMPIAR_WT" "$logwt" "$LIMPIAR" "$log" & ) >/dev/null 2>&1 || true
  else
    ( cd "$ROOT" && nohup bash "$LIMPIAR" >"$log" 2>&1 & ) >/dev/null 2>&1 || true
  fi
}

# ── Vía (B): TRIGGER AL PUNTO DE MERGE (inmediato; debounce corto anti-estampida de ráfaga de merges). ──
if [ "$es_merge" = 1 ]; then
  deb="${BARRER_RAMAS_MERGE_DEBOUNCE:-30}"; case "$deb" in ''|*[!0-9]*) deb=30;; esac
  mstamp="$stampdir/${slug}.merge"
  if [ -f "$mstamp" ]; then
    mlast=$(cat "$mstamp" 2>/dev/null || echo 0); case "$mlast" in ''|*[!0-9]*) mlast=0;; esac
    [ $(( now - mlast )) -lt "$deb" ] && exit 0    # otro barrido de merge acabó de lanzarse → ya cubre este
  fi
  printf '%s' "$now" > "$mstamp" 2>/dev/null || true
  lanzar
  ctx="🧹 Merge de MR/PR detectado → barriendo en segundo plano las ramas locales Y los worktrees que quedaron integrados (zombies squash-safe: MR mergeado / remota borrada / equivalencia de parche; también borra la rama REMOTA huérfana si el merge no la limpió; conserva trabajo sin integrar y nunca toca actual/base/develop/main/Develop*/keep/*). Detalle: ${log} · ${logwt}. Para verlo sin borrar: \`limpiar-ramas.sh --dry-run\` / \`limpiar-worktrees.sh --dry-run\`."
  if [ "$have_jq" = 1 ]; then
    jq -n --arg c "$ctx" '{hookSpecificOutput:{hookEventName:"PostToolUse",additionalContext:$c}}'
  else
    printf '%s\n' "$ctx"
  fi
  exit 0
fi

# ── Vía (A): TRIGGER OPORTUNISTA AL ABRIR SESIÓN (throttle por repo, BARRER_RAMAS_HORAS). ──
# Marca el throttle ANTES de lanzar (evita relanzar mientras corre) y dispara el barrido detached.
horas="${BARRER_RAMAS_HORAS:-24}"; case "$horas" in ''|*[!0-9]*) horas=24;; esac
stamp="$stampdir/${slug}"
if [ -f "$stamp" ]; then
  last=$(cat "$stamp" 2>/dev/null || echo 0); case "$last" in ''|*[!0-9]*) last=0;; esac
  [ $(( now - last )) -lt $(( horas * 3600 )) ] && exit 0
fi
printf '%s' "$now" > "$stamp" 2>/dev/null || true
lanzar

ctx="🧹 Barriendo ramas locales Y worktrees YA integrados de este repo en segundo plano (zombies squash-safe: MR mergeado / remota borrada / equivalencia de parche; también borra la rama REMOTA huérfana si el merge no la limpió; conserva trabajo sin integrar y nunca toca actual/base/develop/main/Develop*/keep/*). Throttle ${horas}h. Detalle del último barrido: ${log} · ${logwt}. Para verlo sin borrar: \`limpiar-ramas.sh --dry-run\` / \`limpiar-worktrees.sh --dry-run\`."
if [ "$have_jq" = 1 ]; then
  jq -n --arg c "$ctx" '{hookSpecificOutput:{hookEventName:"SessionStart",additionalContext:$c}}'
else
  printf '%s\n' "$ctx"
fi
exit 0
