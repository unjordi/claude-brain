#!/usr/bin/env bash
# aviso-drift-cerebro.sh — SessionStart hook (tier GLOBAL). Al INICIAR sesión en un repo que tiene el
# cerebro POR-REPO instalado (sello .brain-version o el hook repo-scoped clásico), compara esa copia
# contra la FUENTE ÚNICA local (el clon de instalación ~/.cortex, o $CLAUDE_BRAIN_DIR) usando
# sincronizar-cerebro.sh en DRY-RUN (diff-aware por CONTENIDO — comparar versiones NO sirve: VERSION
# no se bumpea por cambio) y, si la copia quedó ATRÁS, INYECTA un aviso ruidoso vía additionalContext.
#
# REDISEÑO #46 (unjordi + gemelo cachy, 2026-08-05) — BIFURCA por la marca `.claude/repo-compartido`:
# - COMPARTIDO (tiene la marca): el brain por-repo es un CORREO que viaja por git a quien NO tiene brain
#   global (colegas/clones) → hay que mantenerlo fresco. Comportamiento de siempre: detecta drift, auto-
#   apply+commit+push en tu mini-develop con .claude/ limpio, o AVISA para propagar por el flujo.
# - PERSONAL (sin la marca, el DEFAULT): guards por-repo NUNCA (tu máquina los saca del install GLOBAL +
#   dedupe; una copia por-repo solo drifta/estorba). NO auto-commit/push; si el repo tiene guards del brain
#   que SOBRAN, los FLAGGEA para quitar (opción B; no los borra solos). La memoria/skills son suyos, no se tocan.
# Norma que nace con esto: "repo personal = memoria/skills, NUNCA guards por-repo" (en global-claude-md.md).
# Diseño completo: memoria [[diseno-rediseno-auto-sync-46]].
#
# Diseño de unjordi (2026-07-18): "es tan sencillo como poner un hook en el global para que en el
# inicio de sesión revise que el local y global sean el mismo y actualice el local si no" — con dos
# matices acordados en la misma conversación: (a) el comparador es el DIFF real, no la versión; (b) en
# repos COMPARTIDOS "actualizar el local" = commit por ramita→MR, así que este hook NO escribe NADA al
# árbol (un write silencioso ensuciaría el working tree y se mezclaría a commits de feature): DETECTA
# y AVISA para que Claude proponga la propagación por el flujo. Evidencia de necesidad: MegaFlux
# acumuló 9 archivos de drift porque nadie corría el sync (detectado 2026-07-18).
#
# Throttle: si el último chequeo de ESTE repo salió LIMPIO, no se re-chequea por AVISO_DRIFT_HORAS
# (default 6; stamp en ~/.claude/memory/.drift-cerebro/). Un chequeo CON drift no se cachea → avisa en
# cada inicio de sesión hasta que se propague (esa insistencia es el punto).
# Fail-open SIEMPRE: sin clon canónico / repo no-brained / cualquier error del sync → silencio.
#
# RECORDATORIO DE LA DUPLA (2026-07-31): cuando el cerebro de este repo CAMBIA (auto-sync) o está por
# hacerlo (drift), es el momento de "¿la realidad sigue cumpliendo la firma?" → el aviso añade un nudge a
# correr la DUPLA de auditores (suficiencia + coherencia, van juntas). Se cuelga de ESTE hook (que ya corre
# SessionStart + ya llama a sincronizar + ya sabe cuándo el cerebro se movió) en vez de un hook nuevo.
# BIFURCA por el esquema firma+detalle: si el repo tiene AGENTS.md instanciado → "audita CONTRA la firma";
# si NO → la dupla igual funciona (suficiencia deriva su lista; coherencia caza contradicciones) y se sugiere
# instanciar el esquema. NUNCA lo asume — la mayoría de los repos aún no tienen firma=TOC (hoy solo games-master).
#
# CUÁNDO CORRE (verificado 2026-07-31 vs doc oficial de hooks + evidencia real — NO re-investigar):
# SessionStart dispara con source ∈ {startup, resume, clear, compact, fork} — NO solo en arranque
# fresco. En particular `claude --resume`/`--continue` → source="resume", y cada `/compact` (auto o
# manual) → source="compact", LO DISPARAN. Este hook se cablea SIN matcher → corre en TODOS esos
# source (la doc no lo jura literal para el matcher omitido, pero el commit real que este hook genera
# — "chore(cerebro): auto-sync de la copia por-repo (aviso-drift, …)" — lo DEMUESTRA empíricamente).
# Importa porque el flujo real es casi todo --resume + sesiones largas que compactan: la auto-sync se
# re-chequea en cada resume Y en cada compactación, sin depender de abrir claudes frescos.
# Doc: code.claude.com/docs/en/hooks (tabla SessionStart + "Hooks can be re-run on resume with
# --continue or --resume (source = resume or fork)").
set -u

# CUERPO PER-REPO compartido con el SWEEPER de flotilla (barrer-flotilla-cerebro.sh): la decisión de
# drift + el auto-apply viven en la lib drift_chequea_repo → UNA sola implementación (cero drift entre
# el fast-path interactivo de aquí y el batch del sweeper). Ver drift-cerebro-comun.sh.
# shellcheck source=drift-cerebro-comun.sh
. "$(dirname "$0")/drift-cerebro-comun.sh"

ROOT="${CLAUDE_PROJECT_DIR:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"
cat >/dev/null 2>&1 || true   # drenar stdin (contrato SessionStart)

# ── CONOCIMIENTO PROPIO (per-repo, imborrable) ──────────────────────────────────────────────────────
# Si el repo tiene .claude/memory/conocimiento-propio.md, se RE-INYECTA en CADA SessionStart
# (fresh/resume/compact) — ANTES del throttle y del drift, para que la identidad del proyecto vuelva
# SIEMPRE (no dependa de que haya drift ni del cache de 6h). Es PER-REPO: cada repo tiene el suyo (o
# ninguno) → "cada sesión con una personalidad ligeramente distinta"; este hook es GLOBAL y solo lo
# SURFACE si el archivo existe (no lo propaga ni lo asume universal). Diseño de unjordi (2026-07-31):
# "asienta ese conocimiento propio amarrado al mismo hook" — el que ya dispara fiable en resume/compact,
# para que "el conocimiento más básico que tienes sobre ti mismo no se te pueda borrar".
SELF=""
# Prefiere la variante PERSONAL/LOCAL (.local.md → gitignored: no viaja al repo público ni al de un
# colega); cae a la .md por si un repo quiere una identidad COMPARTIDA versionada. Primero que exista gana.
for _self_file in "$ROOT/.claude/memory/conocimiento-propio.local.md" "$ROOT/.claude/memory/conocimiento-propio.md"; do
  [ -f "$_self_file" ] && { SELF="$(cat "$_self_file" 2>/dev/null || true)"; break; }
done

# emit_and_exit [contexto-de-drift] — emite additionalContext UNA sola vez, anteponiendo el conocimiento
# propio (si existe) al contexto de drift/auto-sync (si lo hay). Sin ninguno de los dos → silencio.
emit_and_exit() {
  local extra="${1:-}" out="" part sep=""
  # Une (en orden, saltando vacíos): SELF (identidad) · $extra (drift/auto-sync per-repo) · GLOBAL_SK_WARN
  # (drift de la copia GLOBAL de skills) · GLOBAL_HOOK_WARN (drift de la copia GLOBAL de hooks/libs) ·
  # MIGRACION_WARN (huella local de clon sin migrar). Los tres últimos viajan en TODOS los exit paths
  # (incluso el throttle per-repo fresco): son concerns per-MÁQUINA con su PROPIO throttle, no dependen
  # del drift del repo actual.
  for part in "$SELF" "$extra" "${GLOBAL_SK_WARN:-}" "${GLOBAL_HOOK_WARN:-}" "${MIGRACION_WARN:-}"; do
    [ -z "$part" ] && continue
    if [ -z "$out" ]; then out="$part"; else
      out="$out

$sep

$part"
    fi
    sep="────────────────────────────────────────────────────────────────────────────────"
  done
  [ -z "$out" ] && exit 0
  if command -v jq >/dev/null 2>&1; then
    jq -n --arg c "$out" '{hookSpecificOutput:{hookEventName:"SessionStart",additionalContext:$c}}'
  else
    printf '%s\n' "$out"
  fi
  exit 0
}

# Throttle por repo (solo cachea chequeos LIMPIOS). Es un concern INTERACTIVO — el sweeper batch de
# flotilla NO usa este throttle (corre 1×/día con su propio lock por-repo). Va ANTES de delegar: un
# chequeo limpio reciente evita re-correr el sync, pero la IDENTIDAD (conocimiento-propio) SIGUE
# surface-ándose (emit_and_exit "" abajo la incluye si existe) — la identidad es imborrable, no depende
# del drift ni del cache.
horas="${AVISO_DRIFT_HORAS:-6}"; case "$horas" in ''|*[!0-9]*) horas=6;; esac
stampdir="$HOME/.claude/memory/.drift-cerebro"; mkdir -p "$stampdir" 2>/dev/null || true
slug=$(printf '%s' "$ROOT" | cksum 2>/dev/null | awk '{print $1}')
stamp="$stampdir/${slug:-0}"
now=$(date +%s)

# ── DRIFT DE SKILLS GLOBAL (per-máquina) — con su PROPIO throttle (independiente del per-repo). Warn-only.
# Se computa ANTES del throttle per-repo para que viaje aunque ese throttle corte temprano (emit_and_exit lo
# incluye en TODOS los exit paths). Solo re-chequea cada AVISO_DRIFT_HORAS; un resultado CON drift NO se
# cachea (insiste hasta que se porte a la fuente). Es el equivalente AUTOMÁTICO del doctor verificar-cerebro.
GLOBAL_SK_WARN=""
sk_stamp="$stampdir/.skills-global"
sk_skip=0
if [ -f "$sk_stamp" ]; then
  sk_last=$(cat "$sk_stamp" 2>/dev/null || echo 0); case "$sk_last" in ''|*[!0-9]*) sk_last=0;; esac
  [ $(( now - sk_last )) -lt $(( horas * 3600 )) ] && sk_skip=1
fi
if [ "$sk_skip" = 0 ]; then
  GLOBAL_SK_WARN="$(drift_skills_global 2>/dev/null)"
  _rc=$?
  if [ "$_rc" = 0 ] && [ -z "$GLOBAL_SK_WARN" ]; then
    printf '%s' "$now" > "$sk_stamp" 2>/dev/null || true
  fi
fi

# ── DRIFT DE HOOKS GLOBAL (per-máquina) — con su PROPIO throttle (independiente del per-repo y del de skills).
# Warn-only. Equivalente de drift_skills_global pero para ~/.claude/hooks vs brain/hooks: cubre TODO archivo
# de tier {global,both} que install-brain copia ahí (hooks + libs + scripts). Antídoto a "el global está
# congelado": un guard/lib editado a mano o desactualizado en la copia global no se detectaba. Solo re-chequea
# cada AVISO_DRIFT_HORAS; un resultado CON drift NO se cachea (insiste hasta que se porte a la fuente).
GLOBAL_HOOK_WARN=""
hk_stamp="$stampdir/.hooks-global"
hk_skip=0
if [ -f "$hk_stamp" ]; then
  hk_last=$(cat "$hk_stamp" 2>/dev/null || echo 0); case "$hk_last" in ''|*[!0-9]*) hk_last=0;; esac
  [ $(( now - hk_last )) -lt $(( horas * 3600 )) ] && hk_skip=1
fi
if [ "$hk_skip" = 0 ]; then
  GLOBAL_HOOK_WARN="$(drift_hooks_global 2>/dev/null)"
  _rc=$?
  if [ "$_rc" = 0 ] && [ -z "$GLOBAL_HOOK_WARN" ]; then
    printf '%s' "$now" > "$hk_stamp" 2>/dev/null || true
  fi
fi

# ── HUELLA LOCAL DE MÁQUINA SIN MIGRAR (rename #312 claude-brain→cortex) — SOLO test -d LOCAL, JAMÁS red
# (nunca `git fetch`/llamada de red: esto es un nudge advisory, no un chequeo de versión). Si el clon de
# instalación sigue bajo el nombre VIEJO (~/.claude-brain con su .git) y el nuevo (~/.cortex) NO existe,
# esta máquina es la población en limbo del rename (auditoría 2026-08-29, C1/AUTOSYNC): el resolver bash
# YA tiene el fallback (resolve_brain_dir, C2) así que autosync/verificación/protección de fuente siguen
# vivos aquí, pero el WIDGET viejo puede seguir atascado sin self-update (build vieja sin #322) → sugiere
# re-instalar con el one-liner del bootstrap para cerrar el loop de una vez. Throttle propio ~1×/día
# (independiente de AVISO_DRIFT_HORAS: esto no cambia con el drift del repo). Fail-open, nunca bloquea.
MIGRACION_WARN=""
mig_stamp="$stampdir/.migracion-limbo"
mig_skip=0
if [ -f "$mig_stamp" ]; then
  mig_last=$(cat "$mig_stamp" 2>/dev/null || echo 0); case "$mig_last" in ''|*[!0-9]*) mig_last=0;; esac
  [ $(( now - mig_last )) -lt 86400 ] && mig_skip=1
fi
if [ "$mig_skip" = 0 ]; then
  if [ -d "$HOME/.claude-brain/.git" ] && [ ! -d "$HOME/.cortex" ]; then
    MIGRACION_WARN="🧠➡️ TU CLON DEL CEREBRO sigue con el nombre VIEJO (~/.claude-brain) — el rename a cortex (~/.cortex) nunca migró en esta máquina. El tooling bash ya te sigue viendo (fallback), pero el widget puede seguir atascado sin poder auto-actualizarse. Re-instala con:
curl -fsSL https://raw.githubusercontent.com/unjordi/cortex/main/bootstrap.sh | bash"
  fi
  printf '%s' "$now" > "$mig_stamp" 2>/dev/null || true
fi

if [ -f "$stamp" ]; then
  last=$(cat "$stamp" 2>/dev/null || echo 0)
  case "$last" in ''|*[!0-9]*) last=0;; esac
  [ $(( now - last )) -lt $(( horas * 3600 )) ] && emit_and_exit ""
fi

# ── Delegación al CUERPO PER-REPO COMPARTIDO (drift-cerebro-comun.sh). Hace TODO el chequeo per-repo
# (brained? · fuente? · #46 personal/compartido · drift · C2 anti-regresión · auto-apply+commit+push en la
# mini-develop) y devuelve STATUS + mensaje. El THROTTLE (arriba) y la IDENTIDAD (conocimiento-propio) son
# responsabilidad de ESTE hook interactivo — el cuerpo compartido no las conoce (el sweeper batch no las usa).
# Auto-apply REAL (no dry-run): en la mini-develop, si procede, sincroniza solo. Ver la lib para el detalle.
_res=$(drift_chequea_repo "$ROOT")
_status=$(printf '%s\n' "$_res" | head -1 | sed -n 's/^STATUS=//p')
_msg=$(printf '%s\n' "$_res" | sed '1d')

# Cachea SOLO los chequeos genuinamente LIMPIOS (personal sano o compartido al día). El flag de guards
# sobrantes, el drift y el auto-sync NO se cachean (insisten / ya mutaron); "unknown" (sync sin resumen)
# tampoco → reintenta la próxima sesión en vez de sellar un error transitorio como "al día".
case "$_status" in
  clean|personal-clean) printf '%s' "$now" > "$stamp" 2>/dev/null || true ;;
esac

# Emite: los estados silenciosos solo surface-an la IDENTIDAD (si existe); los ruidosos, identidad + msg.
case "$_status" in
  not-brained|no-source|unknown|clean|personal-clean) emit_and_exit "" ;;
  *) emit_and_exit "$_msg" ;;
esac
