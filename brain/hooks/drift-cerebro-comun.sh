#!/usr/bin/env bash
# drift-cerebro-comun.sh — LIB (tier global). CUERPO PER-REPO compartido del chequeo de drift del cerebro.
#
# POR QUÉ EXISTE: la lógica "¿la copia por-repo del cerebro de ESTE repo está al día vs la fuente única, y
# si estoy en mi mini-develop con .claude/ limpio, la sincronizo sola?" la necesitan DOS consumidores:
#   1. aviso-drift-cerebro.sh  — SessionStart hook, INTERACTIVO, 1 repo (el de arranque). Fast-path.
#   2. barrer-flotilla-cerebro.sh — SWEEPER batch, N repos de la flotilla (cron/LaunchAgent).
# Antes vivía SOLO en el hook → el sweeper la habría re-implementado y las dos copias driftarían (justo el
# mal que este cerebro combate). Se extrae AQUÍ para que ambos compartan UNA sola implementación (cero drift).
#
# CONTRATO de la función `drift_chequea_repo <ROOT> [DRY_RUN]`:
#   - Hace el chequeo per-repo de ROOT (mismo comportamiento de siempre) y, si procede, el auto-apply
#     +commit+push en la mini-develop (idempotente, fail-safe). NO hace throttle, NO inyecta identidad
#     (conocimiento-propio), NO emite additionalContext — eso es responsabilidad del hook interactivo.
#   - DRY_RUN=1 (o 2º arg "dry-run"): calcula la DECISIÓN pero NO escribe/commitea/pushea nada (para el
#     modo --dry-run del sweeper y para los tests deterministas sin red). En ese modo, el caso que SÍ
#     habría auto-sincronizado devuelve STATUS=would-sync (no synced).
#   - Imprime en stdout:
#         línea 1:  STATUS=<código>
#         resto:    mensaje humano (el mismo texto que el hook usaba como additionalContext), puede ir vacío
#   - Devuelve 0 SIEMPRE (fail-open — un error del sync/git nunca debe romper el arranque de sesión).
#
# Códigos de STATUS:
#   not-brained    ROOT no tiene cerebro por-repo (ni sello .brain-version ni el hook repo-scoped clásico).
#   no-source      no hay clon canónico local del cerebro (sincronizar-cerebro.sh no existe) → fail-open.
#   unknown        el sync falló / no dio resumen → no se pudo determinar drift → fail-open (no cachear).
#   personal-clean repo PERSONAL (sin marca .claude/repo-compartido) sano: cero guards del brain sobrando.
#   personal-flag  repo PERSONAL con guards del brain que SOBRAN → mensaje = flag "quítalos" (no auto-git).
#   clean          repo COMPARTIDO al día (0 drift).
#   synced         repo COMPARTIDO: auto-sincronizado (apply+commit+push OK) en la mini-develop. mensaje = ctx.
#   synced-push-failed  COMPARTIDO: apply+commit local OK pero el PUSH falló (red/auth) → commit en la rama
#                  LOCAL, aún no en el remoto. NO se cachea (no es clean): avisa re-pushear a mano. Antídoto al
#                  falso "synced" que ocultaba un remoto stale (el commit local hacía desaparecer el drift).
#   would-sync     (solo DRY_RUN) habría auto-sincronizado, pero en dry-run NO se tocó nada.
#   drift          repo COMPARTIDO con drift que NO se auto-aplicó (ramita/.claude sucio/fuente stale/etc).
#
# La FUENTE canónica y toda la semántica (C2 anti-regresión, patrón Develop<Usuario>, staging de .claude/
# completo, etc.) son idénticas a las que vivían en aviso-drift-cerebro.sh — ver ahí el detalle histórico.
# Guardado bash-3.2-safe (sin arrays asociativos ni ${x^^}).

# resolve_brain_dir — resuelve el clon de instalación del cerebro, con el MISMO orden/fallback que ya
# tienen los 3 widgets (#322): $CLAUDE_BRAIN_DIR → ~/.cortex → ~/.claude-brain (nombre PRE-rename),
# prefiriendo el primero que EXISTA (test -d). Fail-open: si ninguno existe, cae al default histórico
# ~/.cortex (mismo comportamiento de siempre) — NUNCA bloquea ni falla.
# Por qué: antes de esto, todo el tooling bash (este archivo, verificar-cerebro.sh,
# proteger-fuente-cerebro.sh, exportar-sesion-master.sh, sesiones-master/install-hook.sh) resolvía con
# `${CLAUDE_BRAIN_DIR:-$HOME/.cortex}` a secas — SIN el fallback a `~/.claude-brain`. En una máquina cuyo
# clon quedó bajo el nombre VIEJO (rename #312 sin migrar), `~/.cortex` no existe → autosync/verificación/
# protección de fuente quedaban CIEGOS (fail-open silencioso), asimetría con los widgets que sí migraron
# (auditoría 2026-08-29, §4 C2 / hallazgo AUTOSYNC). Única implementación — todo lo demás la llama, no la
# reimplementa. Imprime la ruta por stdout, sin trailing slash.
resolve_brain_dir() {
  if [ -n "${CLAUDE_BRAIN_DIR:-}" ] && [ -d "${CLAUDE_BRAIN_DIR:-}" ]; then
    printf '%s\n' "$CLAUDE_BRAIN_DIR"; return 0
  fi
  [ -d "$HOME/.cortex" ] && { printf '%s\n' "$HOME/.cortex"; return 0; }
  [ -d "$HOME/.claude-brain" ] && { printf '%s\n' "$HOME/.claude-brain"; return 0; }
  printf '%s\n' "$HOME/.cortex"
}

# drift_chequea_repo <ROOT> [DRY_RUN]
drift_chequea_repo() {
  local ROOT="$1" DRY_RUN=0
  case "${2:-}" in 1|dry-run|dryrun) DRY_RUN=1 ;; esac
  [ -n "$ROOT" ] || { printf 'STATUS=%s\n' "no-source"; return 0; }

  # ¿repo brained? (sello del sync, o el hook repo-scoped clásico).
  if ! { [ -f "$ROOT/.claude/hooks/.brain-version" ] || [ -f "$ROOT/.claude/hooks/dod-verificar.sh" ]; }; then
    printf 'STATUS=%s\n' "not-brained"; return 0
  fi

  # Fuente canónica LOCAL del cerebro = el clon de instalación (lo actualiza el one-liner/bootstrap).
  local BRAIN_DIR SYNC
  BRAIN_DIR="$(resolve_brain_dir)"
  SYNC="$BRAIN_DIR/brain/sincronizar-cerebro.sh"
  if [ ! -f "$SYNC" ]; then printf 'STATUS=%s\n' "no-source"; return 0; fi

  # ── #46: DISCRIMINAR repo COMPARTIDO vs PERSONAL por la marca .claude/repo-compartido ────────────────
  # (semántica idéntica a la que vivía en el hook; ver diseño [[diseno-rediseno-auto-sync-46]])
  if [ ! -f "$ROOT/.claude/repo-compartido" ]; then
    # ── PERSONAL: guards por-repo NUNCA → NO commit/push; si SOBRAN, FLAG a quitar. La memoria/skills del
    # repo son SUYOS (no del brain) → no son "drift". "Sobran" = .sh en .claude/hooks que TAMBIÉN existen
    # en la fuente del brain (BRAIN_DIR/brain/hooks); los hooks PROPIOS del repo NO se flaggean.
    local sobran="" _h _b
    if [ -d "$ROOT/.claude/hooks" ] && [ -d "$BRAIN_DIR/brain/hooks" ]; then
      for _h in "$ROOT/.claude/hooks/"*.sh; do
        [ -e "$_h" ] || continue
        _b=$(basename "$_h")
        [ -f "$BRAIN_DIR/brain/hooks/$_b" ] && sobran="$sobran $_b"
      done
    fi
    if [ -n "$sobran" ]; then
      printf 'STATUS=%s\n' "personal-flag"
      printf '%s\n' "🧹 REPO PERSONAL con guards del cerebro que SOBRAN:${sobran}
Quítalos — en un repo PERSONAL el brain GLOBAL + el dedupe ya te cubren, así que una copia por-repo solo puede DRIFTAR y estorbar (una pre-dedupe hasta rompió un merge: caso powerscripts). Los guards por-repo son SOLO para repos COMPARTIDOS (marca \`.claude/repo-compartido\`, que viajan por git a quien no tiene brain global). Tu MEMORIA/SKILLS NO se tocan — son tuyos.
Cómo: borra esos .sh de .claude/hooks/ + sus entradas en .claude/settings.json. NO commiteo ni pusheo nada por ti (personal = sin auto-git). Si en realidad este repo es COMPARTIDO, decláralo con \`touch .claude/repo-compartido\` y re-abre sesión."
      return 0
    fi
    printf 'STATUS=%s\n' "personal-clean"; return 0
  fi

  # ── COMPARTIDO (tiene la marca): el brain por-repo es el CORREO → mantenerlo fresco ──
  # DRY-RUN del sync (sin --apply: NO escribe). Un ERROR del sync (no-cero) o un resumen ausente → NO se
  # pudo determinar el drift → STATUS=unknown: fail-open (el caller surface la identidad pero NO cachea,
  # para reintentar el chequeo en la próxima sesión en vez de sellar un error transitorio como "al día").
  local out resumen resumen_sk nuevos act ret falta total sk_nue sk_act sk_orph
  out=$(bash "$SYNC" "$ROOT" 2>/dev/null) || { printf 'STATUS=%s\n' "unknown"; return 0; }
  resumen=$(printf '%s\n' "$out" | grep -E '==> resumen:' | tail -1)
  [ -n "$resumen" ] || { printf 'STATUS=%s\n' "unknown"; return 0; }
  nuevos=$(printf '%s' "$resumen" | grep -oE '[0-9]+ nuevos'       | grep -oE '[0-9]+' || echo 0)
  act=$(printf '%s' "$resumen"    | grep -oE '[0-9]+ a actualizar' | grep -oE '[0-9]+' || echo 0)
  ret=$(printf '%s' "$resumen"    | grep -oE '[0-9]+ retirado'     | grep -oE '[0-9]+' || echo 0)
  falta=$(printf '%s' "$resumen"  | grep -oE '[0-9]+ cableado faltante' | grep -oE '[0-9]+' || echo 0)
  # SKILLS por-repo: la línea "==> resumen skills:" (SEPARADA de la de hooks; grep '==> resumen:' NO la
  # captura porque tras "resumen" va " skills" antes del ':'). Drift de skills = nuevas + a actualizar +
  # huérfanas. Si el sync no emite esa línea (stub viejo / brain sin skills-manifest) → 0, no cambia nada.
  resumen_sk=$(printf '%s\n' "$out" | grep -E '==> resumen skills:' | tail -1)
  sk_nue=$(printf '%s' "$resumen_sk"  | grep -oE '[0-9]+ nuevas'       | grep -oE '[0-9]+' || echo 0)
  sk_act=$(printf '%s' "$resumen_sk"  | grep -oE '[0-9]+ a actualizar' | grep -oE '[0-9]+' || echo 0)
  sk_orph=$(printf '%s' "$resumen_sk" | grep -oE '[0-9]+ huérfana'     | grep -oE '[0-9]+' || echo 0)
  total=$(( ${nuevos:-0} + ${act:-0} + ${ret:-0} + ${falta:-0} + ${sk_nue:-0} + ${sk_act:-0} + ${sk_orph:-0} ))

  if [ "$total" -eq 0 ]; then printf 'STATUS=%s\n' "clean"; return 0; fi

  local detalle
  detalle=$(printf '%s\n' "$out" | grep -E '(NUEVO|NUEVA|ACTUALIZA|RETIRAR|HUÉRFAN)' | sed 's/^[[:space:]]*/    /' | head -14)

  # ── Nudge de la DUPLA (suficiencia + coherencia): BIFURCA según AGENTS.md esté instanciado. ──
  local dupla_nota
  if [ -f "$ROOT/AGENTS.md" ]; then
    dupla_nota="
🔎 DUPLA: el cerebro del repo se movió → corre la dupla de auditores (suficiencia + coherencia, van juntas) CONTRA la firma/\`AGENTS.md\` — «¿la realidad sigue cumpliendo la firma?» — antes de integrar/release."
  else
    dupla_nota="
🔎 DUPLA: el cerebro del repo se movió → corre la dupla de auditores (suficiencia + coherencia) para verificar que no rompió nada. (Este repo NO tiene instanciado el esquema firma(\`CLAUDE.md\`)+detalle(\`AGENTS.md\`); la dupla funciona igual — considera instanciarlo para auditar «contra la firma».)"
  fi

  # C2 (FMEA) — GUARD ANTI-REGRESIÓN del auto-sync: si la FUENTE está DETRÁS de su origin/main, aplicarla
  # REGRESARÍA el cerebro y el push lo propagaría → NO auto-aplicar. Guard POSITIVO (tightening puro):
  # fuente_stale=1 SOLO cuando CONFIRMO behind>0; si no hay cómo medir, conserva el comportamiento previo.
  local fuente_stale=0 behind
  if behind=$(git -C "$BRAIN_DIR" rev-list --count HEAD..origin/main 2>/dev/null); then
    case "$behind" in ''|*[!0-9]*) : ;; 0) : ;; *) fuente_stale=1;; esac
  fi

  local cur
  cur=$(git -C "$ROOT" rev-parse --abbrev-ref HEAD 2>/dev/null || echo "")
  # sA3 (FMEA) — mini-develop = `Develop<Usuario>` en PascalCase: Develop + una MAYÚSCULA (clase POSIX
  # [[:upper:]], no rango [A-Z] que en locales UTF-8 puede casar minúsculas).
  case "$cur" in
    Develop[[:upper:]]*)
      if [ "$fuente_stale" = 0 ] && [ -z "$(git -C "$ROOT" status --porcelain -- .claude/ 2>/dev/null)" ]; then
        if [ "$DRY_RUN" = 1 ]; then
          printf 'STATUS=%s\n' "would-sync"
          printf '%s\n' "(dry-run) habría AUTO-SINCRONIZADO la copia por-repo en la mini-develop ($cur): $total archivo(s) atrás. Sin tocar nada (dry-run). Qué cambiaría:
$detalle"
          return 0
        fi
        if bash "$SYNC" "$ROOT" --apply >/dev/null 2>&1 \
           && git -C "$ROOT" add -A .claude/ >/dev/null 2>&1; then
          # V1 (auditoría 2026-08-06): este auto-commit BYPASSEABA secret-scan — ocurre DENTRO de este
          # subproceso, NO vía una tool Bash, así que el guard PreToolUse/Bash secret-scan NO lo intercepta.
          # Un `.claude/` drifteado con un secreto se auto-pusheaba a la mini saltándose el guard defensivo.
          # Escaneo lo AGREGADO (git diff --cached de .claude/, líneas '+') con la MISMA lib que usa
          # secret-scan (detectar-secretos.sh → ds_buscar). Si hay match → ABORTA el auto-sync (des-estagea,
          # NO commitea/pushea) y avisa. Fail-OPEN si falta la lib (no rompe el arranque de sesión).
          local _sec_lib _added _red
          _sec_lib="$(dirname "${BASH_SOURCE[0]}")/detectar-secretos.sh"
          _red=""
          if [ -f "$_sec_lib" ]; then
            # shellcheck source=detectar-secretos.sh
            . "$_sec_lib"
            _added=$(git -C "$ROOT" diff --cached -- .claude/ 2>/dev/null | grep -E '^\+' | grep -vE '^\+\+\+')
            _red=$(ds_buscar "$_added" 2>/dev/null | tr '\n' ' ')
          fi
          if [ -n "$_red" ]; then
            git -C "$ROOT" reset -q -- .claude/ >/dev/null 2>&1 || true
            printf 'STATUS=%s\n' "drift"
            printf '%s\n' "🚨 AUTO-SYNC DEL CEREBRO ABORTADO — secret-scan detectó lo que parece un SECRETO en el .claude/ que se iba a commitear (redactado):$_red
NO commiteé ni pusheé nada (des-estageé el cambio; el working tree quedó con la copia aplicada, SIN commitear). Saca el secreto de esa copia por-repo antes de propagar el cerebro; si es un placeholder/falso positivo, sincroniza a mano por el flujo (worktree→ramita→MR). Es la MISMA detección que el guard secret-scan, aplicada al commit que este hook hace por su cuenta."
            return 0
          fi
          if git -C "$ROOT" commit -q -o -m "chore(cerebro): auto-sync de la copia por-repo (aviso-drift, $total archivo(s) al día)" -- .claude/ >/dev/null 2>&1; then
            local sha
            sha=$(git -C "$ROOT" rev-parse --short HEAD 2>/dev/null || echo "?")
            # El push puede fallar (red/auth/rate-limit) DESPUÉS del commit local. NO lo tragues con `|| true`
            # + STATUS=synced: eso reporta éxito falso, y como el commit local YA pone la copia al día vs la
            # fuente, la próxima sesión ve 0 drift → clean → NUNCA reintenta el push → el colega/clon queda
            # stale para siempre sin que nada lo detecte. Reporta el fallo de push HONESTO.
            if git -C "$ROOT" push -q origin "$cur" >/dev/null 2>&1; then
              printf 'STATUS=%s\n' "synced"
              printf '%s\n' "🧬✅ CEREBRO AUTO-SINCRONIZADO en tu mini-develop ($cur, commit $sha): la copia por-repo estaba $total archivo(s) atrás y se puso al día SOLA (apply+commit+push). Llegará al develop compartido con tu próxima integración coordinada. Qué cambió:
$detalle$dupla_nota"
            else
              printf 'STATUS=%s\n' "synced-push-failed"
              printf '%s\n' "🧬⚠️ CEREBRO auto-sincronizado LOCALMENTE (commit $sha en $cur, $total archivo(s)) pero el PUSH FALLÓ (red/auth/rate-limit). El commit está en tu rama LOCAL; re-pushéalo cuando tengas red: \`git -C $ROOT push origin $cur\` — si no, tu copia local se ve al día pero el develop compartido (y los colegas/clones) siguen con la copia STALE. Qué cambió:
$detalle$dupla_nota"
            fi
            return 0
          fi
        fi
      fi
      ;;
  esac

  # Si la fuente está STALE (C2), avisarlo: propagar desde una fuente vieja regresaría el brain.
  local stale_nota=""
  [ "$fuente_stale" = 1 ] && stale_nota="
⚠️ OJO (anti-regresión C2): tu FUENTE del cerebro ($BRAIN_DIR) parece DETRÁS de su origin/main — NO auto-sincronicé para no regresar el brain. Actualiza la fuente primero (\`git -C $BRAIN_DIR pull --ff-only\` o abre el widget) y reabre sesión."
  printf 'STATUS=%s\n' "drift"
  printf '%s\n' "🧠⚠️ DRIFT DEL CEREBRO POR-REPO: la copia en .claude/hooks/ de ESTE repo está ATRÁS de la fuente única del cerebro ($total archivo(s)):
$detalle$stale_nota
Qué hacer: PROPÓN al usuario propagar por el flujo — worktree/ramita desde develop → \`bash $SYNC <worktree> --apply\` → commit → MR a develop. NO edites .claude/hooks/ directo en el árbol de trabajo (en repos compartidos viaja por git y se mezclaría a commits de feature). Nota: en ESTA máquina la copia GLOBAL ya manda (dedupe), pero el drift por-repo afecta a colegas y clones sin bootstrap.$dupla_nota"
  return 0
}

# ── drift_skills_global — drift de la copia GLOBAL de skills (~/.claude/skills) vs la FUENTE única
#    (brain/skills), para las skills de tier {global,both} del SKILLS-MANIFEST. Es el equivalente
#    AUTOMÁTICO del `drift_scan skills` del doctor verificar-cerebro (manual): antídoto al síntoma real
#    (~/.claude/skills/to-do se editó a mano en dev → la copia viva DRIFTÓ de la fuente y NADA lo detectaba).
#    WARN-ONLY (nunca reescribe la copia global: la dirección puede ser "edit en vivo sin portar" = mejora
#    que se PERDERÍA con un overwrite ciego; el remedio es editar la FUENTE + re-correr install-brain).
#    Imprime el mensaje humano si hay drift; NADA si está limpia. Devuelve 0 SIEMPRE (fail-open).
#    PRECISIÓN: solo skills del manifiesto {global,both}; solo compara archivos PRESENTES en la fuente
#    (una skill/archivo puramente local en ~/.claude/skills, sin contraparte fuente, NO es este drift → se
#    ignora, cero falso positivo). bash-3.2-safe.
drift_skills_global() {
  local BRAIN_DIR SRC_SKILLS INST_SKILLS MAN
  BRAIN_DIR="$(resolve_brain_dir)"
  SRC_SKILLS="$BRAIN_DIR/brain/skills"
  INST_SKILLS="$HOME/.claude/skills"
  MAN="$SRC_SKILLS/MANIFEST"
  [ -d "$SRC_SKILLS" ] || return 0          # sin fuente → fail-open
  [ -d "$INST_SKILLS" ] || return 0         # sin copia instalada → nada que comparar
  [ -f "$MAN" ] || return 0                 # sin manifiesto de skills → no sé qué es del brain → fail-open

  local names editadas stale n_ed n_st sk src inst rel
  names=$(awk '$1!~/^#/ && NF>=2 && ($2=="global"||$2=="both"){print $1}' "$MAN")
  editadas=""; stale=""; n_ed=0; n_st=0
  while IFS= read -r sk; do
    [ -z "$sk" ] && continue
    [ -d "$SRC_SKILLS/$sk" ] || continue
    while IFS= read -r src; do
      [ -z "$src" ] && continue
      rel="${src#"$SRC_SKILLS/$sk"/}"
      inst="$INST_SKILLS/$sk/$rel"
      [ -f "$inst" ] || { n_st=$((n_st+1)); stale="$stale skills/$sk/$rel(falta)"; continue; }
      cmp -s "$src" "$inst" && continue
      if [ "$inst" -nt "$src" ]; then n_ed=$((n_ed+1)); editadas="$editadas skills/$sk/$rel"
      else n_st=$((n_st+1)); stale="$stale skills/$sk/$rel"; fi
    done < <(find "$SRC_SKILLS/$sk" -type f 2>/dev/null)
  done <<EOF
$names
EOF

  [ "$n_ed" = 0 ] && [ "$n_st" = 0 ] && return 0   # limpia → silencio
  local msg="🧠⚠️ DRIFT DE SKILLS (copia GLOBAL ~/.claude/skills vs la fuente única del cerebro):"
  if [ "$n_ed" -gt 0 ]; then
    msg="$msg
  · $n_ed archivo(s) EDITADOS EN VIVO (la copia instalada es MÁS NUEVA que la fuente → tu edición se PERDERÍA en el próximo install-brain). PÓRTALOS a la fuente $SRC_SKILLS y re-corre install-brain:$editadas"
  fi
  if [ "$n_st" -gt 0 ]; then
    msg="$msg
  · $n_st archivo(s) DESACTUALIZADOS/ausentes en la copia instalada (la fuente cambió y no se re-desplegó). Remedio: re-corre el bootstrap/install-brain (o \`bash $BRAIN_DIR/brain/install-brain.sh\`):$stale"
  fi
  printf '%s\n' "$msg"
  return 0
}

# ── drift_hooks_global — drift de la copia GLOBAL de hooks (~/.claude/hooks) vs la FUENTE única
#    (brain/hooks), para TODO archivo de tier {global,both} del HOOKS-MANIFEST. Es el equivalente
#    AUTOMÁTICO del `drift_scan hooks` del doctor verificar-cerebro (manual): antídoto al síntoma real
#    (~/.claude/hooks/*.sh se editó a mano en dev → la copia viva DRIFTÓ de la fuente y NADA lo detectaba;
#    "el global está congelado" con FPs vivos).
#    ALCANCE = EXACTAMENTE lo que install-brain COPIA a ~/.claude/hooks (install-brain.sh, awk de la etapa (a)):
#    todo {global,both} SIN filtrar kind → hooks + LIBS (analizar-comando-git, drift-cerebro-comun, juez-comun…)
#    + scripts. NO se limita a kind=hook: una lib compartida driftada (p.ej. la lógica git de los guards) es
#    justo el drift silencioso que este chequeo debe cazar. (El cableado sí filtra kind=hook, pero eso es OTRA
#    etapa; el DRIFT de la copia espeja la COPIA, no el cableado.)
#    WARN-ONLY (nunca reescribe la copia global: la dirección puede ser "edit en vivo sin portar" = mejora
#    que se PERDERÍA con un overwrite ciego; el remedio es editar la FUENTE + re-correr install-brain).
#    Imprime el mensaje humano si hay drift; NADA si está limpia. Devuelve 0 SIEMPRE (fail-open).
#    PRECISIÓN: solo archivos del manifiesto {global,both}; solo compara los PRESENTES en la fuente (un hook
#    puramente local en ~/.claude/hooks, sin contraparte fuente, NO es este drift → se ignora, cero FP).
#    bash-3.2-safe.
drift_hooks_global() {
  local BRAIN_DIR SRC_HOOKS INST_HOOKS MAN
  BRAIN_DIR="$(resolve_brain_dir)"
  SRC_HOOKS="$BRAIN_DIR/brain/hooks"
  INST_HOOKS="$HOME/.claude/hooks"
  MAN="$SRC_HOOKS/MANIFEST"
  [ -d "$SRC_HOOKS" ] || return 0          # sin fuente → fail-open
  [ -d "$INST_HOOKS" ] || return 0         # sin copia instalada → nada que comparar
  [ -f "$MAN" ] || return 0                # sin manifiesto de hooks → no sé qué es del brain → fail-open

  local names editadas stale n_ed n_st h src inst
  names=$(awk '$1!~/^#/ && NF>=3 && ($2=="global"||$2=="both"){print $1".sh"}' "$MAN")
  editadas=""; stale=""; n_ed=0; n_st=0
  while IFS= read -r h; do
    [ -z "$h" ] && continue
    src="$SRC_HOOKS/$h"
    [ -f "$src" ] || continue
    inst="$INST_HOOKS/$h"
    [ -f "$inst" ] || { n_st=$((n_st+1)); stale="$stale hooks/$h(falta)"; continue; }
    cmp -s "$src" "$inst" && continue
    if [ "$inst" -nt "$src" ]; then n_ed=$((n_ed+1)); editadas="$editadas hooks/$h"
    else n_st=$((n_st+1)); stale="$stale hooks/$h"; fi
  done <<EOF
$names
EOF

  [ "$n_ed" = 0 ] && [ "$n_st" = 0 ] && return 0   # limpia → silencio
  local msg="🧠⚠️ DRIFT DE HOOKS (copia GLOBAL ~/.claude/hooks vs la fuente única del cerebro):"
  if [ "$n_ed" -gt 0 ]; then
    msg="$msg
  · $n_ed archivo(s) EDITADOS EN VIVO (la copia instalada es MÁS NUEVA que la fuente → tu edición se PERDERÍA en el próximo install-brain). PÓRTALOS a la fuente $SRC_HOOKS y re-corre install-brain:$editadas"
  fi
  if [ "$n_st" -gt 0 ]; then
    msg="$msg
  · $n_st archivo(s) DESACTUALIZADOS/ausentes en la copia instalada (la fuente cambió y no se re-desplegó). Remedio: re-corre el bootstrap/install-brain (o \`bash $BRAIN_DIR/brain/install-brain.sh\`):$stale"
  fi
  printf '%s\n' "$msg"
  return 0
}
