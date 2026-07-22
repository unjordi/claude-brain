#!/usr/bin/env bash
# barrer-ramas.sh — SessionStart hook (tier GLOBAL). Da TRIGGER al barrido de ramas locales ya
# integradas: al abrir sesión en un repo git, y como mucho una vez por BARRER_RAMAS_HORAS (default 24),
# lanza `limpiar-ramas.sh` EN SEGUNDO PLANO para borrar las ramas zombie (MR mergeado con --squash → la
# remota se borró → localmente `: gone`, o commits ya en la base por equivalencia de parche). CONSERVA
# toda rama con trabajo sin integrar, y NUNCA toca la actual/base/develop/main/Develop*/keep/*.
#
# Por qué EXISTE (unjordi, 2026-07-21): `limpiar-ramas` es kind=script en el MANIFEST → se INSTALA pero
# nadie lo DISPARA; las ramas squasheadas se acumulaban (un repo llegó a 60+). "Norma sin mecanismo = buen
# deseo": este hook es el mecanismo. Decisión del usuario: auto-barrer throttled (no solo recordar).
#
# Por qué en SEGUNDO PLANO: la detección de "remota borrada" hace un `ls-remote` POR rama candidata (red);
# con decenas de ramas colgaría el arranque de sesión. Se lanza detached (nohup) y NO bloquea; el borrado
# de cada rama es atómico, así que si la sesión termina a media pasada no hay daño (reintenta al vencer el
# throttle). El barrido es SEGURO por construcción (solo zombies) → no necesita confirmación por corrida.
#
# Throttle por repo (stamp en ~/.claude/memory/.barrer-ramas/); el stamp se escribe ANTES de lanzar para
# no relanzar en cada sesión mientras corre. Escape: CLAUDE_SKIP_BARRER_RAMAS=1.
# Fail-open SIEMPRE: no-git / sin remoto / sin limpiar-ramas / cualquier error → silencio, exit 0.
set -u

cat >/dev/null 2>&1 || true   # drenar stdin (contrato SessionStart)

[ "${CLAUDE_SKIP_BARRER_RAMAS:-0}" = 1 ] && exit 0

ROOT="${CLAUDE_PROJECT_DIR:-$(git rev-parse --show-toplevel 2>/dev/null || echo "")}"
[ -n "$ROOT" ] && git -C "$ROOT" rev-parse --is-inside-work-tree >/dev/null 2>&1 || exit 0
# Sin remoto no hay ramas squasheadas-y-borradas que barrer (y el ls-remote no aplica).
git -C "$ROOT" remote | grep -q . 2>/dev/null || exit 0

# El barredor real, instalado junto a este hook (kind=script → misma carpeta global).
LIMPIAR="$(dirname "$0")/limpiar-ramas.sh"
[ -f "$LIMPIAR" ] || exit 0

# Throttle por repo (solo lanza cada N horas).
horas="${BARRER_RAMAS_HORAS:-24}"; case "$horas" in ''|*[!0-9]*) horas=24;; esac
stampdir="$HOME/.claude/memory/.barrer-ramas"; mkdir -p "$stampdir" 2>/dev/null || true
slug=$(printf '%s' "$ROOT" | cksum 2>/dev/null | awk '{print $1}')
stamp="$stampdir/${slug:-0}"
now=$(date +%s)
if [ -f "$stamp" ]; then
  last=$(cat "$stamp" 2>/dev/null || echo 0)
  case "$last" in ''|*[!0-9]*) last=0;; esac
  [ $(( now - last )) -lt $(( horas * 3600 )) ] && exit 0
fi

# Marca el throttle ANTES de lanzar (evita relanzar mientras corre) y dispara el barrido detached.
printf '%s' "$now" > "$stamp" 2>/dev/null || true
log="$stampdir/${slug:-0}.log"
( cd "$ROOT" && nohup bash "$LIMPIAR" >"$log" 2>&1 & ) >/dev/null 2>&1 || exit 0

ctx="🧹 Barriendo ramas locales YA integradas de este repo en segundo plano (zombies squash-safe: MR mergeado / remota borrada / equivalencia de parche; conserva trabajo sin integrar y nunca toca actual/base/develop/main/Develop*/keep/*). Throttle ${horas}h. Detalle del último barrido: ${log}. Para verlo sin borrar: \`limpiar-ramas.sh --dry-run\`."
if command -v jq >/dev/null 2>&1; then
  jq -n --arg c "$ctx" '{hookSpecificOutput:{hookEventName:"SessionStart",additionalContext:$c}}'
else
  printf '%s\n' "$ctx"
fi
exit 0
