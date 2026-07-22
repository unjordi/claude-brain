#!/usr/bin/env bash
# recordar-unificar-cerebro.sh — SessionStart hook (tier REPO). Gemelo HACIA ARRIBA de
# aviso-drift-cerebro: aquél avisa cuando la copia del cerebro por-repo quedó ATRÁS de la fuente
# (hay que BAJAR); éste avisa cuando TU mini acumuló aprendizajes+memorias sin UNIFICAR a develop
# (hay que SUBIR). Al iniciar sesión, cuenta el delta de `.claude/` (sobre todo aprendizajes.md) de la
# rama actual vs origin/develop y, si supera el umbral, inyecta un aviso PASIVO y NO bloqueante para
# correr `/unificar-cerebro` cuando quieras integrar.
#
# Diseño (unjordi, 2026-07-21): es la capa que cierra el ritual semanal — `cosechar-sesion` llena el
# inbox local, este hook recuerda subirlo, `unificar-cerebro` lo reconcilia. NO escribe NADA al árbol
# (integrar es deliberado, por MR con OK explícito): solo DETECTA y AVISA.
#
# Umbral (tunable por env, con defaults): avisa si el delta de `.claude/` vs origin/develop supera
#   ≥ RECORDAR_UNIFICAR_ARCHIVOS (default 5) archivos,  O
#   > RECORDAR_UNIFICAR_DIAS (default 7) días desde el commit más antiguo del delta (proxy de "hace
#     mucho que no unificas"). Cualquiera de las dos dispara.
#
# Throttle por repo: máx 1 aviso por DÍA por repo (stamp en ~/.claude/memory/.recordar-unificar/), para
# no re-avisar en cada sesión. Escape: CLAUDE_SKIP_RECORDAR_UNIFICAR=1.
# Fail-open SIEMPRE: no-git / sin origin/develop / sin jq / cualquier error → silencio, exit 0.
set -u

cat >/dev/null 2>&1 || true   # drenar stdin (contrato SessionStart)

[ "${CLAUDE_SKIP_RECORDAR_UNIFICAR:-0}" = 1 ] && exit 0

ROOT="${CLAUDE_PROJECT_DIR:-$(git rev-parse --show-toplevel 2>/dev/null || echo "")}"
[ -n "$ROOT" ] && git -C "$ROOT" rev-parse --is-inside-work-tree >/dev/null 2>&1 || exit 0

# Solo aplica a repos con el sistema de memoria.
[ -d "$ROOT/.claude/memory" ] || exit 0

# Necesitamos origin/develop como base de comparación.
git -C "$ROOT" rev-parse --verify --quiet origin/develop >/dev/null 2>&1 || exit 0

# No tiene sentido avisar si estás PARADO en develop/main (no es una mini que unificar).
cur=$(git -C "$ROOT" rev-parse --abbrev-ref HEAD 2>/dev/null || echo "")
case "$cur" in develop|main|HEAD|"") exit 0;; esac

# ── Throttle por repo: máx 1 aviso por día ──
stampdir="$HOME/.claude/memory/.recordar-unificar"; mkdir -p "$stampdir" 2>/dev/null || true
slug=$(printf '%s' "$ROOT" | cksum 2>/dev/null | awk '{print $1}')
stamp="$stampdir/${slug:-0}"
hoy=$(date +%Y-%m-%d 2>/dev/null || echo "")
[ -n "$hoy" ] || exit 0
if [ -f "$stamp" ]; then
  last=$(cat "$stamp" 2>/dev/null || echo "")
  [ "$last" = "$hoy" ] && exit 0
fi

# ── Delta de .claude/ de la rama actual vs origin/develop (three-dot: lo que la rama sumó) ──
n_files=$(git -C "$ROOT" diff --name-only origin/develop...HEAD -- .claude/ 2>/dev/null | grep -c . || echo 0)
case "$n_files" in ''|*[!0-9]*) n_files=0;; esac
[ "$n_files" -eq 0 ] && exit 0   # nada sin unificar → silencio

# ¿aprendizajes.md entre los cambios? (lo resaltamos porque es el corazón del inbox)
apr=""
git -C "$ROOT" diff --name-only origin/develop...HEAD -- .claude/ 2>/dev/null \
  | grep -q 'aprendizajes' && apr=" (incluye aprendizajes.md)"

# Antigüedad del delta: fecha del commit MÁS ANTIGUO que la rama sumó sobre develop (proxy de días).
dias=0
mb=$(git -C "$ROOT" merge-base origin/develop HEAD 2>/dev/null || echo "")
if [ -n "$mb" ]; then
  first_ts=$(git -C "$ROOT" log --reverse --format='%ct' "${mb}..HEAD" -- .claude/ 2>/dev/null | head -1)
  case "$first_ts" in ''|*[!0-9]*) first_ts="";; esac
  if [ -n "$first_ts" ]; then
    now=$(date +%s)
    dias=$(( ( now - first_ts ) / 86400 ))
    [ "$dias" -ge 0 ] || dias=0
  fi
fi

# ── Umbral: ≥N archivos O >D días ──
umbral_files="${RECORDAR_UNIFICAR_ARCHIVOS:-5}"; case "$umbral_files" in ''|*[!0-9]*) umbral_files=5;; esac
umbral_dias="${RECORDAR_UNIFICAR_DIAS:-7}";      case "$umbral_dias"  in ''|*[!0-9]*) umbral_dias=7;;  esac

dispara=0
[ "$n_files" -ge "$umbral_files" ] && dispara=1
[ "$dias" -gt "$umbral_dias" ] && dispara=1
[ "$dispara" -eq 1 ] || exit 0

# ── Avisar (pasivo, no bloqueante) y marcar el throttle del día ──
printf '%s' "$hoy" > "$stamp" 2>/dev/null || true

ctx="🧩 Tu cerebro tiene $n_files archivo(s) de \`.claude/\` sin unificar a develop$apr — la rama '$cur' lleva ~$dias día(s) acumulando. Cuando quieras integrarlos al cerebro del equipo, corre \`/unificar-cerebro\` (reconcilia por el carril de siempre: OK explícito de unjordi, sin --auto-merge, con --squash). Aviso pasivo, no bloquea; 1×/día por repo."
if command -v jq >/dev/null 2>&1; then
  jq -n --arg c "$ctx" '{hookSpecificOutput:{hookEventName:"SessionStart",additionalContext:$c}}'
else
  printf '%s\n' "$ctx"
fi
exit 0
