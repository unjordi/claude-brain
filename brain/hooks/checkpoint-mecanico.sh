#!/usr/bin/env bash
# checkpoint-mecanico.sh — hook de PreCompact (tier GLOBAL). Dispara el andamio MECÁNICO del checkpoint
# (M2/X2, auditoría "mudanza de master · checkpoint/compactación", 2026-09-11).
#
# EL HALLAZGO (X2): PreCompact YA es un hook VIVO y cableado (lo prueba `exportar-sesion-master.sh`, que
# corre en el MISMO evento con el MISMO transcript_path) — y hoy en ese evento el cerebro guarda los
# BYTES del transcript (gzip) y tira el SIGNIFICADO. Este hook usa el MISMO patrón ya probado (detached
# con `nohup … &`, lock por-sid, escritura atómica) para sacar, ADEMÁS, el andamio del checkpoint: el
# 🗂️ árbol de archivos tocados, los mensajes de `git commit`, las citas textuales del usuario y las
# métricas de sesión — TODO mecánico, CERO tokens de modelo (`bin/checkpoint-mecanico.js`).
#
# Por qué PreCompact y no otro evento: es el ÚNICO punto donde el cerebro sabe, con certeza, que la
# ventana se está por perder AHORA — el momento exacto en que el andamio deja de ser "por si acaso" y
# pasa a ser "single origen de qué había en el transcript justo antes del corte".
#
# LO QUE ESTE HOOK *NO* HACE (decisión explícita, no olvido): NO invoca `claude -p --resume` ni ningún
# otro modelo. Eso es la vía-1 del dictamen (viable pero cuesta dinero y pasa por `delegacion-gate`) —
# fuera de alcance aquí. Este hook solo corre el extractor MECÁNICO (vía-3): el juicio (en qué estamos,
# decisión abierta, siguiente paso) lo sigue poniendo el modelo vivo, ahora con el andamio ya escrito.
#
# ANTI-RECURSIÓN: este hook NUNCA invoca `claude` (no hay cadena de hooks que pueda re-disparar), pero
# igual se guarda con un centinela de env (`_CORTEX_CKPT_MECANICO_RUNNING`) por si PreCompact llegara a
# anidarse (p. ej. una futura vía-1 que sí invoque un `claude` que a su vez compacte).
#
# CONTRATO: SILENCIOSO y FAIL-OPEN. Nunca bloquea el compact ni el turno; si falta node/jq, si no hay
# `.claude/memory`, o si el debounce/lock ya está tomado → no hace nada. Detached (nohup … &): un
# transcript grande podría exceder el timeout del hook, igual que `exportar-sesion-master.sh` (mismo
# `transcript_path`, mismo riesgo medido: "Hook cancelled" con cps-master 456 MB).
set -u

[ "${_CORTEX_CKPT_MECANICO_RUNNING:-0}" = "1" ] && exit 0   # anti-recursión (centinela por env)

command -v node >/dev/null 2>&1 || exit 0
command -v jq   >/dev/null 2>&1 || exit 0

input=$(cat 2>/dev/null || true)
sid=$(printf '%s' "$input" | jq -r '.session_id // empty' 2>/dev/null)
tpath=$(printf '%s' "$input" | jq -r '.transcript_path // empty' 2>/dev/null)
cwd=$(printf '%s' "$input" | jq -r '.cwd // empty' 2>/dev/null)
[ -n "$sid" ] || exit 0
[ -n "$tpath" ] && [ -f "$tpath" ] || exit 0

ROOT="${CLAUDE_PROJECT_DIR:-${cwd:-$(pwd)}}"
MEM="$ROOT/.claude/memory"
[ -d "$MEM" ] || exit 0   # repo sin el sistema de memoria → no incumbe (mismo criterio que aviso-contexto)

# ── localizar el extractor (mismo patrón de 2 rutas que exportar-sesion-master.sh) ─────────────────
_selfdir="$(dirname "$0")"
if [ -f "$_selfdir/drift-cerebro-comun.sh" ]; then
  # shellcheck source=drift-cerebro-comun.sh
  . "$_selfdir/drift-cerebro-comun.sh"
  BRAIN_DIR="$(resolve_brain_dir)"
else
  BRAIN_DIR="${CLAUDE_BRAIN_DIR:-$HOME/.cortex}"
fi
EXP=""
for c in "$HOME/.local/bin/checkpoint-mecanico.js" "$BRAIN_DIR/bin/checkpoint-mecanico.js"; do
  [ -f "$c" ] && EXP="$c" && break
done
[ -n "$EXP" ] || exit 0

# ── lock por-sid (evita solapar dos PreCompact seguidos de la misma sesión; huérfano >10 min se recicla)
lock="$MEM/.checkpoint-mecanico-$sid.lock"
if [ -f "$lock" ]; then
  lnow=$(date +%s 2>/dev/null || echo 0)
  lmt=$(stat -c %Y "$lock" 2>/dev/null || stat -f %m "$lock" 2>/dev/null || echo 0)
  case "$lnow" in ''|*[!0-9]*) lnow=0 ;; esac
  case "$lmt"  in ''|*[!0-9]*) lmt=0 ;; esac
  [ "$lmt" -gt 0 ] && [ $(( lnow - lmt )) -lt 600 ] && exit 0
fi
: > "$lock" 2>/dev/null || true

OUT="$MEM/hilo-mental-actual.andamio.md"
LOG="$MEM/.checkpoint-mecanico.log"

# ── DETACHED: el extractor corre en streaming con memoria acotada (medido: ~130-190 MB de pico sobre un
# transcript de 756 MB), pero igual se lanza fuera del turno del hook — el mismo motivo que
# exportar-sesion-master.sh (un PreCompact real no puede esperar a que termine un proceso externo).
# Escritura ATÓMICA (tmp+rename, dentro de checkpoint-mecanico.js): el andamio nunca queda a medias si el
# auto-compact gana la carrera y el proceso muere a mitad de escritura — o queda el andamio VIEJO completo,
# o queda el NUEVO completo; nunca una mezcla.
nohup env _CORTEX_CKPT_MECANICO_RUNNING=1 bash -c '
  EXP="$1"; T="$2"; OUT="$3"; ROOT="$4"; lock="$5"
  node "$EXP" "$T" --out "$OUT" --repo-root "$ROOT" >/dev/null 2>>"$6"
  rm -f "$lock" 2>/dev/null
' _ "$EXP" "$tpath" "$OUT" "$ROOT" "$lock" "$LOG" >/dev/null 2>&1 &

exit 0
