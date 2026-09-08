#!/usr/bin/env bash
# barrer-flotilla-cerebro.sh — SWEEPER de la FLOTILLA de cerebros (tier global, kind script; NO se cablea
# a ningún evento). Corre STANDALONE, en batch (cron/LaunchAgent 1×/día), sobre TODOS los repos brained de
# ~/code — no solo el de arranque de una sesión.
#
# POR QUÉ EXISTE (el punto ciego de COBERTURA de aviso-drift-cerebro): aviso-drift es un SessionStart hook
# → solo ve el repo donde ARRANCÓ la sesión. La flotilla de otros repos brained (MegaFlux, cps, …) se queda
# a la deriva hasta que abras sesión en cada uno. Evidencia real: MegaFlux acumuló ~9 archivos de drift
# porque nadie corría el sync ahí. Un hook de evento NO puede resolver esto (ningún evento ve N repos) → un
# barredor independiente que recorre la flotilla y aplica la MISMA lógica per-repo.
#
# CERO DRIFT con el hook interactivo: NO re-implementa la decisión — comparte drift_chequea_repo() con
# aviso-drift-cerebro.sh vía la lib drift-cerebro-comun.sh (fuente única del cuerpo per-repo). Aquí solo se
# agrega lo que el batch necesita: descubrimiento de la flotilla, lock por-repo y un REPORTE (no hay turno
# del modelo → nada de additionalContext).
#
# QUÉ HACE por cada repo (idéntico al hook): #46 personal/compartido; en un repo COMPARTIDO parado en su
# mini-develop (Develop<Usuario>) con .claude/ limpio y la fuente NO stale (guard C2) → auto-apply+commit
# +push SOLO; en cualquier otro caso → acumula en el REPORTE para propagación/limpieza manual. Fail-safe
# SIEMPRE: nunca muta un .claude/ sucio; el push es `|| true`.
#
# Uso:
#   bash barrer-flotilla-cerebro.sh [--dry-run] [--code-dir <dir>] [--roots-file <f>] [--report <path>] [--quiet]
#     --dry-run       : calcula la decisión de cada repo pero NO escribe/commitea/pushea nada (preview).
#     --code-dir <d>  : raíz del descubrimiento (default $HOME/code).
#     --roots-file <f>: en vez de descubrir, lee las rutas de repos (una por línea) de <f> (para tests).
#     --report <p>    : archivo de reporte (default $STATEDIR/flotilla-ultimo-reporte.md).
#     --quiet         : no imprime el reporte a stdout (útil bajo LaunchAgent con StandardOutPath).
# Programación (NO se instala vivo aquí — es config de máquina, la decide unjordi):
#   macOS  : LaunchAgent de ejemplo en macos/launchd/com.local.drift-flotilla.plist (ver ese archivo).
#   general: la skill `schedule` (routines cron del CLI) o `loop`.
# bash-3.2-safe.
set -u

SELFDIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=drift-cerebro-comun.sh
. "$SELFDIR/drift-cerebro-comun.sh"

DRY_RUN=0; QUIET=0
CODE_DIR="${CLAUDE_CODE_DIR:-$HOME/code}"
ROOTS_FILE=""
STATEDIR="${CLAUDE_DRIFT_STATEDIR:-$HOME/.claude/memory/.drift-cerebro}"
REPORT=""
DASHBOARD="${CLAUDE_DASHBOARD:-$HOME/.claude/projects/-Users-$(id -un 2>/dev/null || echo user)/memory/dashboard_cerebro.md}"

while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run) DRY_RUN=1 ;;
    --quiet)   QUIET=1 ;;
    --code-dir) shift; CODE_DIR="${1:-}" ;;
    --code-dir=*) CODE_DIR="${1#--code-dir=}" ;;
    --roots-file) shift; ROOTS_FILE="${1:-}" ;;
    --roots-file=*) ROOTS_FILE="${1#--roots-file=}" ;;
    --report) shift; REPORT="${1:-}" ;;
    --report=*) REPORT="${1#--report=}" ;;
    --no-dashboard) DASHBOARD="" ;;
    -*) echo "ERROR: flag desconocido: $1" >&2; exit 2 ;;
    *)  echo "ERROR: argumento inesperado: $1" >&2; exit 2 ;;
  esac
  shift
done

mkdir -p "$STATEDIR" 2>/dev/null || true
[ -n "$REPORT" ] || REPORT="$STATEDIR/flotilla-ultimo-reporte.md"

# ── Descubrimiento de la flotilla ────────────────────────────────────────────────────────────────────
# Autodescubrimiento por el SELLO que planta el sync (.claude/hooks/.brain-version) → robusto a repos
# NUEVOS sin tocar config. El sello vive en <repo>/.claude/hooks/.brain-version = profundidad 4 bajo
# CODE_DIR (por eso -maxdepth 5: cubre el layout plano <code>/<repo>/… y uno agrupado <code>/<grupo>/<repo>/…;
# el `-maxdepth 3` del boceto original NO encontraba nada — el sello está más hondo). El Mapa de repos del
# dashboard es la fuente CURADA de referencia, pero el sello es estrictamente más completo (caza repos que
# el dashboard aún no lista) → se usa como primaria; se puede añadir el dashboard como cross-check opcional.
descubrir_flotilla() {
  if [ -n "$ROOTS_FILE" ]; then
    [ -f "$ROOTS_FILE" ] && grep -v '^[[:space:]]*$' "$ROOTS_FILE"
    return 0
  fi
  [ -d "$CODE_DIR" ] || return 0
  find "$CODE_DIR" -maxdepth 5 -type f -path '*/.claude/hooks/.brain-version' 2>/dev/null \
    | sed 's#/\.claude/hooks/\.brain-version$##' \
    | sort -u
}

# ── Barrido ────────────────────────────────────────────────────────────────────────────────────────
ts="$(date '+%Y-%m-%d %H:%M:%S')"
n_total=0; n_synced=0; n_wouldsync=0; n_drift=0; n_flag=0; n_clean=0; n_locked=0; n_skip=0; n_syncfail=0
BODY_SYNCED=""; BODY_ATT=""; BODY_LOCKED=""

# lock por-repo (mkdir es atómico) en STATEDIR con sufijo .lock — no colisiona con los stamps del throttle
# interactivo (archivos nombrados por el mismo slug SIN sufijo). Evita que dos corridas del sweeper (o una
# corrida solapada) procesen el mismo repo a la vez. Backstop contra el auto-apply de una sesión interactiva
# concurrente: el precheck "nunca muta un .claude/ sucio" + el index.lock de git serializan el commit real
# (mismo razonamiento que el comentario de concurrencia con barrer-ramas en el hook) → degrada sin corromper.
while IFS= read -r repo; do
  [ -n "$repo" ] || continue
  [ -d "$repo" ] || continue
  n_total=$((n_total+1))
  slug=$(printf '%s' "$repo" | cksum 2>/dev/null | awk '{print $1}')
  lock="$STATEDIR/${slug:-0}.lock"
  if ! mkdir "$lock" 2>/dev/null; then
    n_locked=$((n_locked+1))
    BODY_LOCKED="$BODY_LOCKED
  - $repo (lock ocupado — sesión interactiva u otra corrida del sweeper; se reintenta a la próxima)"
    continue
  fi
  res=$(drift_chequea_repo "$repo" "$DRY_RUN")
  rmdir "$lock" 2>/dev/null || true
  status=$(printf '%s\n' "$res" | head -1 | sed -n 's/^STATUS=//p')
  msg=$(printf '%s\n' "$res" | sed '1d')
  case "$status" in
    synced)
      n_synced=$((n_synced+1))
      BODY_SYNCED="$BODY_SYNCED
  - ✅ $repo — auto-sincronizado (apply+commit+push en su mini-develop)"
      ;;
    synced-push-failed)
      n_syncfail=$((n_syncfail+1))
      BODY_ATT="$BODY_ATT
  - 🧬⚠️ $repo — apply+commit LOCAL OK pero el PUSH FALLÓ (red/auth) → el commit está en su mini-develop local, NO en el remoto. Re-pushea a mano cuando haya red, o el develop compartido queda stale."
      ;;
    would-sync)
      n_wouldsync=$((n_wouldsync+1))
      BODY_SYNCED="$BODY_SYNCED
  - ⧗ $repo — (dry-run) SE auto-sincronizaría (mini-develop limpia, fuente no stale)"
      ;;
    drift)
      n_drift=$((n_drift+1))
      BODY_ATT="$BODY_ATT
  - ⚠️ $repo — DRIFT sin auto-aplicar (ramita / .claude sucio / fuente stale) → propaga por el flujo (worktree→ramita→MR a develop)"
      ;;
    personal-flag)
      n_flag=$((n_flag+1))
      BODY_ATT="$BODY_ATT
  - 🧹 $repo — repo PERSONAL con guards del cerebro que SOBRAN → quítalos (.claude/hooks/*.sh del brain + su cableado)"
      ;;
    clean|personal-clean)
      n_clean=$((n_clean+1))
      ;;
    *)  # not-brained / no-source / unknown → no accionable (fail-open silencioso)
      n_skip=$((n_skip+1))
      ;;
  esac
done <<EOF
$(descubrir_flotilla)
EOF

# ── Reporte ──────────────────────────────────────────────────────────────────────────────────────────
modo="APLICA"; [ "$DRY_RUN" = 1 ] && modo="DRY-RUN (no escribió nada)"
resumen_linea="barrer-flotilla-cerebro [$modo] $ts — $n_total repo(s): $n_synced sync · $n_syncfail push-fallido · $n_wouldsync would-sync · $n_drift drift · $n_flag personal-flag · $n_clean al día · $n_locked lock · $n_skip n/a"

{
  echo "# Reporte del sweeper de flotilla — $ts"
  echo ""
  echo "Modo: **$modo** · raíz de descubrimiento: \`$CODE_DIR\`"
  echo ""
  echo "$resumen_linea" | sed 's/^barrer-flotilla-cerebro //'
  if [ -n "$BODY_SYNCED" ]; then echo ""; echo "## Sincronizados / sincronizables$BODY_SYNCED"; fi
  if [ -n "$BODY_ATT" ]; then echo ""; echo "## Necesitan atención manual$BODY_ATT"; fi
  if [ -n "$BODY_LOCKED" ]; then echo ""; echo "## Saltados por lock$BODY_LOCKED"; fi
  [ "$n_total" -eq 0 ] && { echo ""; echo "_(no se descubrió ningún repo brained bajo \`$CODE_DIR\`)_"; }
} > "$REPORT" 2>/dev/null || true

# Append de UNA línea (append-only con `>>`, la norma para docs que varias sesiones tocan a la vez → no
# choca) a la Bitácora del dashboard GLOBAL, SOLO si hubo algo accionable (sync/would/drift/flag) para no
# ensuciar la bitácora con corridas 100% limpias. El detalle completo vive en $REPORT.
if [ -n "$DASHBOARD" ] && [ -f "$DASHBOARD" ] && [ $(( n_synced + n_syncfail + n_wouldsync + n_drift + n_flag )) -gt 0 ]; then
  printf '\n- **[%s] barrer-flotilla-cerebro:** %s (detalle: `%s`)\n' \
    "$(date '+%Y-%m-%d')" "${resumen_linea#barrer-flotilla-cerebro }" "$REPORT" >> "$DASHBOARD" 2>/dev/null || true
fi

if [ "$QUIET" != 1 ]; then
  cat "$REPORT" 2>/dev/null || true
fi
exit 0
