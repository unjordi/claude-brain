#!/usr/bin/env bash
# install-brain.sh — instalador del CEREBRO GLOBAL compartible de Claude Code (cortex).
# "Corre una vez y tu máquina queda con los guardrails, la gobernanza de costo de delegación,
# la skill de cierre, el dashboard y las normas globales." Re-correrlo es SEGURO (idempotente).
#
# Instala GLOBAL (en ~/.claude, aplica a TODOS los repos de esta máquina):
#   (a) HOOKS de tier {global, both} en ~/.claude/hooks/ — la LISTA se DERIVA de brain/hooks/MANIFEST
#       (fuente única; ya no se cura a mano en paralelo con la copia por-repo). Incluye git-branch-guard,
#       merge-squash-guard, confirmar-merge-develop, recordar-dashboard, secret-scan, rama-vieja,
#       proteger-arbol (PreToolUse/Bash), delegacion-gate + limite-gasto (PreToolUse/Task),
#       delegacion-registrar/reporte (PostToolUse/Task), rehidratar-hilo + aviso-contexto (SessionStart/
#       PostToolUse) + libs `delegacion-comun.sh`, `analizar-comando-git.sh`, `detectar-secretos.sh`
#       + agentes-costo.json (config). La lista EXACTA se deriva de brain/hooks/MANIFEST.
#   (b) CABLEADO en ~/.claude/settings.json con "shell":"bash" (idempotente).
#   (c) SKILLS genéricas (cerrar-slice, orquestar-fanout, checkpoint, rehidratar-hilo, turno-nocturno,
#       diagramar, cosechar-sesion, unificar-cerebro, auditar-suficiencia-operativa,
#       desinflar-memorias) en ~/.claude/skills/. La copia GLOBBEA brain/skills/*/
#       → basta con crear la carpeta de la skill; esta lista es descriptiva.
#   (d) DASHBOARD del cerebro + entorno-esta-maquina.md + como-trabajar-con-<usuario>.md sembrados en la
#       memoria GLOBAL (slug del HOME) si faltan (esqueletos per-máquina que NO viajan por git).
#   (e) NORMAS globales inyectadas en ~/.claude/CLAUDE.md (bloque con marcador, solo si faltan).
#
# REGLA DE ENV VARS DEL BRAIN (norma dura del instalador): las env vars que configuran el
# comportamiento del cerebro se SIEMBRAN en `settings.json` (bloque `.env`) — que Claude Code exporta a
# TODA sesión —, NUNCA se dejan viviendo solo en el env de una sesión suelta. Motivo: ni el instalador
# ni el widget (las 3 GUIs) leen el env de una sesión; leen settings.json / archivos en disco. Una var
# seteada ad-hoc en UNA terminal se pierde al cerrarla y MIENTE al resto (drama real de
# CLAUDE_SESSIONS_DRIVE seteada en una sesión y ausente en las demás). Dos mecanismos, no confundir:
#   · set_env_default  → PLANTA un valor fijo SOLO si la clave falta (defaults portables: Opus 4.8, 70%).
#   · persist_env_active → CAPTURA el valor ACTIVO del entorno si la var está exportada al correr el
#                          bootstrap (para las tunables que el dev elige). Ambos idempotentes.
#
# confirmar-merge-develop AHORA es GLOBAL (candado de merges a develop/main con OK explícito): antes
# vivía solo por-repo y por eso faltaba donde el repo no lo traía (un caso real 2026-07-11) → promovido a
# global para que aplique en TODA sesión/clon. NO instala globales los hooks REPO-SCOPED restantes
# (sesion-inicio, dod-verificar): esos viven en brain/hooks/ como FUENTE para
# que cada repo los copie a su .claude/ y los cablee (se cargan solo si la sesión INICIA en el repo).
#
# OS-agnóstico: los hooks corren bajo bash en Mac/Linux/Windows(Git Bash). FAIL-SAFE sin jq (avisa;
# los hooks fallan ABIERTO — no bloquean — hasta que instales jq).
set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SRC_HOOKS="$SCRIPT_DIR/hooks"
SRC_SKILLS="$SCRIPT_DIR/skills"
SRC_NORMS="$SCRIPT_DIR/norms"
SRC_LIB="$SCRIPT_DIR/lib"

# Lib de INSTALACIÓN (no es un hook): detección cross-shell de aliases que muerden binarios reales, para
# el bloque detectado de entorno-esta-maquina.md y el artefacto LEAN ~/.claude/aliases-activos.md (@import).
# Fail-safe: si falta, se degrada (las funciones ds_* no existen → los usos van guardados con command -v).
# shellcheck source=lib/detectar-shells.sh
[ -f "$SRC_LIB/detectar-shells.sh" ] && . "$SRC_LIB/detectar-shells.sh"

CLAUDE_DIR="$HOME/.claude"
HOOKS_DIR="$CLAUDE_DIR/hooks"
SKILLS_DIR="$CLAUDE_DIR/skills"
GSET="$CLAUDE_DIR/settings.json"
GCLAUDE="$CLAUDE_DIR/CLAUDE.md"

echo "==> cortex: instalando cerebro global en $CLAUDE_DIR"
mkdir -p "$HOOKS_DIR" "$SKILLS_DIR"

# Dependencia de los hooks: jq. Sin jq, el git-branch-guard y el gate de delegación fallan ABIERTO.
if ! command -v jq >/dev/null 2>&1; then
  echo "ADVERTENCIA: 'jq' no está en el PATH. Los hooks del cerebro lo REQUIEREN (sin jq los guards"
  echo "  fallan abierto y no bloquean, y no puedo cablear el settings.json). Instálalo y re-corre:"
  echo "    macOS: brew install jq · Debian/Ubuntu: apt install jq · Windows: winget install jqlang.jq"
fi

# ── (a) Copiar hooks de tier global + la lib compartida ──
# Los de tier {global, both} salen del MANIFEST (fuente única) → esta lista ya NO se cura a mano en
# paralelo con la copia por-repo (antídoto a H2: dos listas divergían). El drift-check de test-brain
# verifica que install/uninstall/sincronizar coincidan con el manifiesto.
if [ -f "$SRC_HOOKS/MANIFEST" ]; then
  GLOBAL_HOOKS="$(awk '$1!~/^#/ && NF>=3 && ($2=="global"||$2=="both"){print $1".sh"}' "$SRC_HOOKS/MANIFEST")"
else
  echo "warn: falta $SRC_HOOKS/MANIFEST; no puedo derivar la lista de hooks globales"; GLOBAL_HOOKS=""
fi
# Instalación ATÓMICA: cp a un tmp en el MISMO dir + mv (rename atómico). El updater ⬆ puede reescribir
# ~/.claude/hooks con una sesión VIVA; un `cp -f` in-situ deja una ventana en la que un hook que hace
# `source` de una lib (p. ej. analizar-comando-git.sh) la leería a medio sobrescribir. El mv/rename es
# atómico en el mismo filesystem → el hook ve la versión vieja COMPLETA o la nueva COMPLETA, nunca media.
atomic_install() {  # <src> <dst> [exec]
  local src="$1" dst="$2" mode="${3:-}" tmp
  tmp="$(dirname "$dst")/.$(basename "$dst").tmp.$$"
  if cp -f "$src" "$tmp" 2>/dev/null; then
    [ "$mode" = exec ] && chmod +x "$tmp" 2>/dev/null
    mv -f "$tmp" "$dst" 2>/dev/null || { rm -f "$tmp"; return 1; }
  else
    rm -f "$tmp" 2>/dev/null; return 1
  fi
}
for h in $GLOBAL_HOOKS; do
  if [ -f "$SRC_HOOKS/$h" ]; then
    atomic_install "$SRC_HOOKS/$h" "$HOOKS_DIR/$h" exec || echo "warn: no pude instalar el hook $h"
  else
    echo "warn: falta el hook fuente $h"
  fi
done
# Config de clasificación de costo (la lee delegacion-comun.sh en $HOME/.claude/agentes-costo.json)
if [ -f "$SRC_HOOKS/agentes-costo.json" ]; then
  atomic_install "$SRC_HOOKS/agentes-costo.json" "$CLAUDE_DIR/agentes-costo.json" || echo "warn: no pude instalar agentes-costo.json"
fi
echo "ok: hooks globales + lib + config de costo copiados a $HOOKS_DIR"

# ── (b) Cablear en settings.json (idempotente) ──
# register_hook <event> <matcher> <comando> <patrón-dedupe>
register_hook() {
  local ev="$1" m="$2" cmd="$3" pat="$4" tmp
  command -v jq >/dev/null 2>&1 || { echo "warn: jq no está; agrega el hook '$pat' a $GSET a mano"; return; }
  [ -f "$GSET" ] || echo '{}' > "$GSET"
  tmp="$(mktemp)" || return
  if jq --arg ev "$ev" --arg m "$m" --arg cmd "$cmd" --arg pat "$pat" '
      .hooks = (.hooks // {}) |
      .hooks[$ev] = (.hooks[$ev] // []) |
      if any(.hooks[$ev][]?; ([.hooks[]?.command] | join(" ")) | test($pat))
      then .hooks[$ev] = [ .hooks[$ev][] | if (([.hooks[]?.command] | join(" ")) | test($pat)) then (if $m=="" then del(.matcher) else .matcher=$m end) else . end ]
      else .hooks[$ev] += [ (if $m=="" then {} else {"matcher":$m} end) + {"hooks":[{"type":"command","command":$cmd,"shell":"bash"}]} ] end
    ' "$GSET" > "$tmp" 2>/dev/null && [ -s "$tmp" ]; then mv "$tmp" "$GSET"; else rm -f "$tmp"; echo "warn: no pude fusionar hook ($pat)"; fi
}

# Evento+matcher de cada hook GLOBAL a cablear. El MANIFEST declara tier/kind pero NO el evento →
# esta tabla lo mapea (misma forma que ev_de() en sincronizar-cerebro.sh, que cubre los {repo,both}).
# Matcher vacío ⇒ se omite la clave ⇒ casa TODAS las fuentes (SessionStart: startup/resume/compact/clear;
# PostToolUse: toda tool). Al AGREGAR un hook global nuevo al MANIFEST: añádelo aquí — si falta, el loop
# de abajo AVISA y el drift-check de test-brain (e2) FALLA (no se cablea en silencio).
ev_de() {
  case "$1" in
    git-branch-guard|merge-squash-guard|confirmar-merge-develop|recordar-dashboard|secret-scan|entorno-maquina-guard|no-bypass-deploy|rama-vieja|proteger-arbol) echo "PreToolUse|Bash" ;;
    proteger-fuente-cerebro) echo "PreToolUse|Edit|Write|MultiEdit" ;;
    limite-gasto|delegacion-gate) echo "PreToolUse|Task|Agent" ;;   # Task|Agent: el tool se renombró Agent (antes Task); casar AMBOS o el gate nunca dispara
    delegacion-registrar|delegacion-reporte) echo "PostToolUse|Task|Agent" ;;
    rehidratar-hilo|aviso-drift-cerebro) echo "SessionStart|" ;;
    aviso-contexto|recordar-orquestar) echo "PostToolUse|" ;;   # casan TODA tool (sin matcher): aviso-contexto mide el ctx; recordar-orquestar cuenta mutaciones/resets p/ el nudge de fan-out
    # hud-stale: DOBLE trigger — SessionStart (capta el cambio de rama/cwd ENTRE sesiones, al retomar) +
    # PostToolUse/Bash (capta el cambio a MEDIA sesión, justo tras un `git checkout`/`cd`).
    hud-stale) echo "SessionStart| PostToolUse|Bash" ;;
    # barrer-ramas: DOBLE trigger del barrido — SessionStart (oportunista, throttled) + PostToolUse/Bash
    # (al punto de merge, detecta glab/gh merge vía acg_es_merge_mr). Multi-evento como exportar-sesion-master.
    barrer-ramas) echo "SessionStart| PostToolUse|Bash" ;;
    # Multi-evento: ev_de puede devolver VARIOS pares "Event|Matcher" separados por espacio; el loop de
    # cablear registra cada uno. exportar-sesion-master necesita los 3 (Stop=backbone con debounce,
    # SessionEnd=estado final, PreCompact=bonus) — ver su encabezado.
    exportar-sesion-master) echo "Stop| SessionEnd| PreCompact|" ;;
    *) echo "" ;;
  esac
}

# ── Cablear DERIVANDO del MANIFEST (fuente única), no una lista paralela hardcodeada (antídoto al drift
# latente: antes la COPIA se derivaba del MANIFEST pero el CABLEADO eran 16 register_hook a mano → un
# hook global nuevo se copiaba pero no se cableaba). Los mismos hooks/eventos que antes; el evento sale
# de ev_de(). El command conserva el literal `$HOME` (se expande al correr el hook, no aquí). ──
WIRE_HOOKS="$(awk '$1!~/^#/ && NF>=3 && ($2=="global"||$2=="both") && $3=="hook"{print $1}' "$SRC_HOOKS/MANIFEST" 2>/dev/null)"
wired_names=""
for h in $WIRE_HOOKS; do
  evm="$(ev_de "$h")"
  if [ -z "$evm" ]; then
    echo "warn: no tengo evento para cablear el hook global '$h' (agrégalo a ev_de en install-brain.sh) — NO cableado"
    continue
  fi
  # evm puede traer VARIOS pares "Event|Matcher" (space-separated) → cablear cada uno (multi-evento).
  # register_hook dedupe POR-evento con el patrón $h, así que re-correr no duplica.
  for pair in $evm; do
    register_hook "${pair%%|*}" "${pair#*|}" "bash \"\$HOME/.claude/hooks/$h.sh\"" "$h"
  done
  wired_names="$wired_names $h"
done
echo "ok: hooks cableados en $GSET (derivados del MANIFEST):$wired_names"

# ── (c) Skills genéricas del cerebro (cerrar-slice, orquestar-fanout, …) — tier {global,both} del
# brain/skills/MANIFEST (fuente única de tiers; hoy TODAS son `global`). Copia el ÁRBOL COMPLETO de cada
# skill (no solo SKILL.md — algunas traen reference/ o bootstrap-claude.sh; el `cp -f SKILL.md` anterior los
# DEJABA FUERA → aparecían como "falta"/drift eterno en verificar-cerebro y en el nuevo drift de skills).
SKILLS_MANIFEST="$SRC_SKILLS/MANIFEST"
if [ -d "$SRC_SKILLS" ]; then
  # Nombres a instalar: del MANIFEST {global,both}; si no hay manifiesto, fallback = todas las carpetas.
  if [ -f "$SKILLS_MANIFEST" ]; then
    _sk_names="$(awk '$1!~/^#/ && NF>=2 && ($2=="global"||$2=="both"){print $1}' "$SKILLS_MANIFEST")"
  else
    _sk_names="$(for d in "$SRC_SKILLS"/*/; do [ -d "$d" ] && basename "$d"; done)"
  fi
  for name in $_sk_names; do
    sk="$SRC_SKILLS/$name"
    [ -f "$sk/SKILL.md" ] || { echo "warn: skill '$name' en el manifiesto pero falta $sk/SKILL.md"; continue; }
    mkdir -p "$SKILLS_DIR/$name"
    cp -Rf "$sk"/. "$SKILLS_DIR/$name"/    # árbol COMPLETO (SKILL.md + subdirs como reference/)
    echo "ok: skill $name instalada (árbol completo) en $SKILLS_DIR/$name"
  done
fi

# ── (c1b) Opción de modelo Opus 4.8 en el picker + autocompact 70% (bloque `env` de settings.json) ──
# Cosechado del global de Cachy (2026-07-31). Es config de Claude Code PORTABLE (no de máquina), por eso va
# en el brain. Idempotente y NO destructivo: setea CADA clave SOLO si falta → un dev que ya eligió otra cosa
# (o que no quiere Opus 4.8) la conserva; una máquina fresca la recibe. NO toca `.model` (el default del dev).
set_env_default() {  # <clave> <valor>
  local k="$1" v="$2" tmp
  command -v jq >/dev/null 2>&1 || return
  [ -f "$GSET" ] || echo '{}' > "$GSET"
  tmp="$(mktemp)" || return
  if jq --arg k "$k" --arg v "$v" '.env = (.env // {}) | (if .env[$k]==null then .env[$k]=$v else . end)' "$GSET" > "$tmp" 2>/dev/null && [ -s "$tmp" ]; then
    mv "$tmp" "$GSET"
  else rm -f "$tmp"; fi
}
set_env_default ANTHROPIC_CUSTOM_MODEL_OPTION "claude-opus-4-8"
set_env_default ANTHROPIC_CUSTOM_MODEL_OPTION_NAME "Opus 4.8"
set_env_default ANTHROPIC_CUSTOM_MODEL_OPTION_DESCRIPTION "Modelo previo - oculto del picker desde Opus 5"
set_env_default CLAUDE_AUTOCOMPACT_PCT_OVERRIDE "70"
echo "ok: Opus 4.8 en el picker + autocompact 70% asegurados en $GSET (env; no pisa tu elección ni tu .model)"

# ── (c1c) Persistir env vars ACTIVAS del brain (su valor REAL del entorno, NO un default) en settings.json
# .env, para que TODA sesión las herede sin setearlas a mano en cada arranque. A diferencia de
# set_env_default (planta un valor fijo si falta), esto CAPTURA lo que ya está activo. Antídoto al drama
# de CLAUDE_SESSIONS_DRIVE seteada ad-hoc en UNA sesión (en vez de asentada por el instalador): si la
# tienes exportada al correr el bootstrap, se persiste sola. SET/UPDATE si la var está activa y no vacía;
# si NO está activa, no toca lo que ya hubiera en settings. Idempotente. ──
persist_env_active() {  # <clave>
  local k="$1" v tmp
  command -v jq >/dev/null 2>&1 || return
  v="${!k:-}"                    # expansión indirecta (bash); "" si no está activa
  [ -n "$v" ] || return          # no activa → no tocamos settings
  [ -f "$GSET" ] || echo '{}' > "$GSET"
  tmp="$(mktemp)" || return
  if jq --arg k "$k" --arg v "$v" '.env = (.env // {}) | .env[$k]=$v' "$GSET" > "$tmp" 2>/dev/null && [ -s "$tmp" ]; then
    mv "$tmp" "$GSET"; echo "ok: env $k persistida en settings.json (.env) = '$v' (valor ACTIVO del entorno)"
  else rm -f "$tmp"; fi
}
# El SET COMPLETO de env vars del brain que se CAPTURAN-si-activas (revisado 2026-08-07). Solo van aquí
# las tunables DURABLES, GLOBAL-seguras y elegidas por el dev. Deliberadamente EXCLUIDAS:
#   · rutas que fija el harness/bootstrap (CLAUDE_PROJECT_DIR, CLAUDE_BRAIN_DIR, CLAUDE_DIR, XDG_CACHE_HOME);
#   · mocks/live de test (CLAUDE_*_JUEZ_MOCK|LIVE|MODEL|TIMEOUT…) — de prueba, jamás persistidas;
#   · escapes por-invocación (CLAUDE_SKIP_*) — deben morir con el comando, no quedar globales;
#   · overrides per-repo autodetectados (CLAUDE_INTEGRACION_BASE) — persistirlos GLOBAL mentiría al
#     siguiente repo (su valor correcto lo autodetecta cada guard). Hoy el brain no expone otra tunable
#     global-segura → el set son las 2 del export de sesiones-master. Al AGREGAR una tunable así, añádela aquí.
for _bv in CLAUDE_SESSIONS_DRIVE CLAUDE_SESSIONS_DEBOUNCE_MIN; do persist_env_active "$_bv"; done

# ── (c2) Sello de VERSIÓN del cerebro instalado ──
# El widget (tab Cerebro de las 3 GUIs) lee ~/.claude/.brain-version — NO el repo — para mostrar
# qué versión del brain quedó instalada en ESTA máquina. Contrato de DOS LÍNEAS:
#   línea 1 = versión = "<PREFIJO>.<commit-count>"  (PREFIJO = brain/VERSION, ej. 0.1 · count = git rev-list)
#   línea 2 = fecha de instalación "YYYY-MM-DD"
# La versión AUTO-INCREMENTA con cada commit (el count crece). C3 (auditoría 2026-08-29): cuando este
# script corre EMPAQUETADO (p.ej. dentro del .app de un widget, vía el botón "Curar cerebro global"),
# $SCRIPT_DIR NO es un repo git → `git rev-list` fallaba silenciosamente a COUNT=0 y REGRESABA el sello
# real a una versión falsa (p.ej. "0.2.0"), haciendo que el widget MINTIERA sobre qué cerebro hay
# instalado. Fix: si SCRIPT_DIR no es git, intenta resolver el CLON REAL de instalación (misma lógica
# resolve_brain_dir() que usan los 3 widgets — $CLAUDE_BRAIN_DIR → ~/.cortex → ~/.claude-brain) y estampa
# desde AHÍ; si tampoco ese es un repo git, NO TOCA el .brain-version existente (mejor un sello viejo que
# uno falso). Idempotente: re-correr re-estampa la versión y fecha actuales cuando sí puede resolver el count.
GIT_SRC=""
if git -C "$SCRIPT_DIR" rev-parse --git-dir >/dev/null 2>&1; then
  GIT_SRC="$SCRIPT_DIR"
else
  DCC="$SCRIPT_DIR/hooks/drift-cerebro-comun.sh"
  if [ -f "$DCC" ]; then
    # shellcheck disable=SC1090
    . "$DCC"
    CAND="$(resolve_brain_dir 2>/dev/null)"
    if [ -n "$CAND" ] && git -C "$CAND" rev-parse --git-dir >/dev/null 2>&1; then
      GIT_SRC="$CAND"
    fi
  fi
fi

if [ -n "$GIT_SRC" ] && [ -f "$SCRIPT_DIR/VERSION" ]; then
  PREFIJO="$(head -1 "$SCRIPT_DIR/VERSION" | tr -d '[:space:]')"
  COUNT="$(git -C "$GIT_SRC" rev-list --count HEAD 2>/dev/null || echo 0)"
  { echo "$PREFIJO.$COUNT"; date +%Y-%m-%d; } > "$CLAUDE_DIR/.brain-version"
  echo "ok: versión del cerebro estampada en $CLAUDE_DIR/.brain-version (v$PREFIJO.$COUNT · $(date +%Y-%m-%d))"
elif [ ! -f "$SCRIPT_DIR/VERSION" ]; then
  echo "warn: falta $SCRIPT_DIR/VERSION; no estampé .brain-version"
else
  echo "warn: $SCRIPT_DIR no es un repo git (ni pude resolver el clon real) — conservo .brain-version existente sin regresarlo a un count falso"
fi

# ── (d) Dashboard del cerebro en la memoria GLOBAL (slug del HOME) si falta ──
HOME_SLUG="$(printf '%s' "$HOME" | sed 's/[^a-zA-Z0-9]/-/g')"
DASH="$CLAUDE_DIR/projects/$HOME_SLUG/memory/dashboard_cerebro.md"
if [ ! -f "$DASH" ]; then
  mkdir -p "$(dirname "$DASH")"
  if [ -f "$SRC_HOOKS/dashboard_cerebro.template.md" ]; then
    cp "$SRC_HOOKS/dashboard_cerebro.template.md" "$DASH"
  else
    printf '# Dashboard del cerebro (memoria GLOBAL de esta compu)\n\n## Mapa\n## Infra clave\n## Cabos sueltos\n## Bitacora (mas reciente ABAJO — appendea con >>, append-safe entre sesiones)\n' > "$DASH"
  fi
  echo "ok: dashboard sembrado en $DASH"
else
  echo "ok: dashboard ya existe ($DASH)"
fi

# ── (d2) Entorno de ESTA máquina en la memoria GLOBAL per-máquina (lo detecta y lo siembra) ──
# Norma dura "el entorno de MÁQUINA vive GLOBAL, jamás en un repo": OS/shell/aliases/rutas/runtime son
# de UNA instancia; en un repo mentirían al clonar en otra compu/OS. Por eso viven AQUÍ (memoria global,
# NO viaja por git). El bootstrap lo SIEMBRA con lo que cada quien tenga configurado; Claude lo MANTIENE
# después. IDEMPOTENTE y no-destructivo: si el archivo no existe → lo crea (encabezado curado + bloque
# detectado); si existe CON el bloque marcado <!-- detectado-por-bootstrap --> → refresca SOLO ese bloque;
# si existe SIN marcadores (curado 100% a mano) → NO lo toca (respeta el trabajo del humano/Claude).
ENTORNO="$CLAUDE_DIR/projects/$HOME_SLUG/memory/entorno-esta-maquina.md"

# --- detección (best-effort; todo fail-safe a "?") ---
det_os="$(uname -srm 2>/dev/null || echo '?')"
det_shell_path="${SHELL:-}"; det_shell="$(basename "${det_shell_path:-sh}")"
# Aliases que MUERDEN: detección CROSS-SHELL (zsh/bash/fish INSTALADOS) vía la lib detectar-shells.sh,
# filtrando a los que SOMBREAN un binario real (no una lista fija). Antes: solo login shell + lista fija
# de 5 (ls/rm/cp/mv/grep) → se le escapaban `mkdir -p`, `vi`→nvim, y todo lo de fish/otro shell. Fail-safe:
# si la lib no cargó, cae a una nota mínima. La MISMA detección alimenta el artefacto LEAN (abajo, d3).
if command -v ds_render_posix_bullets >/dev/null 2>&1; then
  alias_block="$(ds_render_posix_bullets 2>/dev/null || true)"
else
  alias_block="Muerden: (no pude detectar — falta la lib detectar-shells.sh; salta cualquier alias con \`command <cmd>\`)"
fi
tool_bullets=""
for t in eza trash rg fd bat docker colima; do
  if p="$(command -v "$t" 2>/dev/null)" && [ -n "$p" ]; then tool_bullets="${tool_bullets}  - \`$t\` ✓ (\`$p\`)\n"
  else tool_bullets="${tool_bullets}  - \`$t\` ✗ (no está)\n"; fi
done

# El bloque DETECTADO (con sus marcadores) — se regenera en cada corrida.
blk="$(mktemp)" || blk=""
if [ -n "$blk" ]; then
  {
    printf '<!-- detectado-por-bootstrap:INICIO — install-brain REFRESCA esto en cada corrida; edita FUERA de estos marcadores -->\n'
    printf '## Detectado por el bootstrap (%s)\n' "$(date +%Y-%m-%d 2>/dev/null || echo '?')"
    printf -- '- **OS / arch:** `%s`\n' "$det_os"
    printf -- '- **Shell de login:** `%s` (`%s`)\n' "$det_shell" "${det_shell_path:-?}"
    printf -- '- **Aliases que muerden comandos** (salta con `command <cmd>` — NUNCA `/bin/<cmd>`: la ruta varía por OS y `rg`/`eza`/etc. no están en `/bin`; en fish `\\<cmd>` tampoco salta una función). Vista LEAN siempre-en-contexto: `~/.claude/aliases-activos.md` (@import):\n'
    printf '%s\n' "$alias_block" | sed 's/^/  /'
    printf -- '- **Tools clave (presencia):**\n'
    printf '%b' "$tool_bullets"
    printf '<!-- detectado-por-bootstrap:FIN -->\n'
  } > "$blk"
fi

if [ -z "$blk" ]; then
  echo "warn: no pude crear el bloque detectado (mktemp); omito el sembrado de entorno-esta-maquina.md"
elif [ ! -f "$ENTORNO" ]; then
  mkdir -p "$(dirname "$ENTORNO")"
  {
    printf -- '---\nname: entorno-esta-maquina\ndescription: Entorno de ESTA máquina (shell/aliases, OS/arch, runtime local). Es PER-MÁQUINA: vive SOLO en la memoria global, NUNCA en un repo (viajaría por git y mentiría en otra compu/OS). Lo siembra el bootstrap del cerebro y Claude lo va actualizando.\nmetadata:\n  node_type: memory\n  type: reference\n---\n\n'
    printf '# Entorno de ESTA máquina — sembrado por cortex\n\n'
    printf '> **REGLA DURA — por qué este archivo es GLOBAL y no de repo:** el entorno de MÁQUINA (OS,\n'
    printf '> shell, aliases, rutas de tu `$HOME`, runtime local: Docker/BD/certs) es de **esta** compu;\n'
    printf '> en un repo viajaría por git y **mentiría** al clonar en otra máquina/OS. Por eso vive AQUÍ\n'
    printf '> (memoria global per-máquina, NO viaja por git). El bootstrap lo **sembró** detectando la\n'
    printf '> config real; **Claude lo MANTIENE** después: agrega tus mañas (BD, certs, despliegue, cachés\n'
    printf '> del navegador) en la sección de abajo, **FUERA** del bloque `detectado-por-bootstrap` (ese\n'
    printf '> lo REFRESCA `install-brain` en cada corrida — no lo edites a mano).\n\n'
    cat "$blk"
    printf '\n## Notas que Claude va agregando\n(Aún vacío. Aquí van las mañas de esta máquina que no detecta el bootstrap: runtime Docker/BD, certs de dev, despliegue local, cachés, etc.)\n'
  } > "$ENTORNO"
  echo "ok: entorno-esta-maquina.md sembrado en $ENTORNO"
elif grep -q 'detectado-por-bootstrap:INICIO' "$ENTORNO"; then
  tmp="$(mktemp)" || tmp=""
  if [ -n "$tmp" ] && awk -v b="$blk" '
      /<!-- detectado-por-bootstrap:INICIO/ { while ((getline l < b) > 0) print l; close(b); skip=1; next }
      /<!-- detectado-por-bootstrap:FIN/    { skip=0; next }
      skip==0 { print }
    ' "$ENTORNO" > "$tmp" && [ -s "$tmp" ]; then
    mv "$tmp" "$ENTORNO"
    echo "ok: entorno-esta-maquina.md — bloque detectado REFRESCADO ($ENTORNO)"
  else
    rm -f "$tmp"; echo "warn: no pude refrescar el bloque detectado en $ENTORNO (lo dejo intacto)"
  fi
else
  echo "ok: entorno-esta-maquina.md ya existe y está CURADO a mano (sin bloque detectado) — no lo toco ($ENTORNO)"
fi
rm -f "$blk" 2>/dev/null || true

# ── (d2b) "Cómo trabajar con <usuario>" en la memoria GLOBAL per-máquina si falta ──
# Manual de TRATO de la PERSONA (cómo le gusta que le comuniquen/decidan/trabajen). Misma norma dura que
# el entorno y el dashboard: es de UNA persona-instancia, no de un proyecto → en un repo viajaría por git
# y sería ruido para otro dev que clone. Por eso vive AQUÍ (memoria global per-máquina, NO viaja por git).
# El bootstrap SIEMBRA el esqueleto (barebones de la raíz del brain) con el nombre del usuario real;
# después ‹usuario›/Claude lo llenan con lo REAL. IDEMPOTENTE y no-destructivo: si ya existe, no lo toca.
USUARIO="$(id -un 2>/dev/null || echo "${USER:-usuario}")"
COMOTRAB="$CLAUDE_DIR/projects/$HOME_SLUG/memory/como-trabajar-con-$USUARIO.md"
BAREBONES_CT="$SCRIPT_DIR/../como-trabajar-con-usuario.example-barebones.md"
if [ ! -f "$COMOTRAB" ]; then
  mkdir -p "$(dirname "$COMOTRAB")"
  if [ -f "$BAREBONES_CT" ]; then
    cp "$BAREBONES_CT" "$COMOTRAB"
  else
    printf -- '---\nname: como-trabajar-con-%s\ndescription: Cómo le gusta a %s que Claude le comunique, decida y trabaje — TRATO personal, no normas del brain. Per-máquina, NO viaja por git.\nmetadata:\n  node_type: memory\n  type: feedback\n---\n\n# Cómo trabajar con %s\n\n> TRATO de esta PERSONA (comunicación, decisiones, proceso, git, preferencias). NO dupliques las normas\n> UNIVERSALES del brain (viven en ~/.claude/CLAUDE.md) — aquí SOLO lo personal. Per-máquina, NO viaja por git.\n\n## 🗣️ Comunicación y trato\n## ✅ Decisiones y autorización\n## 🛠️ Proceso de trabajo\n## 🌿 Git / repos\n## 🎯 Preferencias concretas\n' "$USUARIO" "$USUARIO" "$USUARIO" > "$COMOTRAB"
  fi
  echo "ok: como-trabajar-con-$USUARIO.md sembrado en $COMOTRAB (esqueleto; ‹usuario›/Claude lo llenan)"
else
  echo "ok: como-trabajar-con-$USUARIO.md ya existe ($COMOTRAB)"
fi

# ── (e) Normas globales en ~/.claude/CLAUDE.md (bloque con marcador; REFRESCA, no solo siembra) ──
# Idempotente Y actualizable: si el bloque BEGIN/END ya existe, se REEMPLAZA EN SU LUGAR con la versión
# actual (así las normas nuevas SÍ llegan a instalaciones existentes al re-correr); si no existe, se
# agrega al final. Conserva intacto todo lo que el usuario tenga fuera del bloque. RED DE SEGURIDAD (la
# sección personal del usuario NO vive en git): respalda a CLAUDE.md.bak antes del mv, y si hay BEGIN sin
# END NO toca el archivo (ese caso borraría todo lo posterior al BEGIN).
if [ ! -f "$SRC_NORMS/global-claude-md.md" ]; then
  echo "warn: no encuentro $SRC_NORMS/global-claude-md.md; no inyecté normas"
elif [ -f "$GCLAUDE" ] && grep -q 'BEGIN cortex' "$GCLAUDE"; then
  # Guarda anti-truncado: con BEGIN pero SIN END, el awk deja skip=1 para siempre → BORRARÍA todo lo que
  # venga tras el BEGIN (incluida la sección PERSONAL del usuario). Si falta el END, NO tocamos el archivo.
  if ! grep -q 'END cortex' "$GCLAUDE"; then
    echo "warn: $GCLAUDE tiene 'BEGIN cortex' SIN su 'END' — NO lo toco (evito borrar tu sección personal). Ciérralo a mano y re-corre."
  else
    tmp="$(mktemp)" || tmp=""
    if [ -n "$tmp" ] && awk -v src="$SRC_NORMS/global-claude-md.md" '
        /<!-- BEGIN cortex/ { skip=1; while ((getline l < src) > 0) print l; close(src) }
        skip==0 { print }
        /<!-- END cortex -->/ { skip=0 }
      ' "$GCLAUDE" > "$tmp" && [ -s "$tmp" ]; then
      # Red de seguridad: CLAUDE.md trae la sección PERSONAL del usuario, que NO vive en git → backup antes del mv.
      cp "$GCLAUDE" "$GCLAUDE.bak" 2>/dev/null || true
      mv "$tmp" "$GCLAUDE"
      echo "ok: normas globales del cerebro REFRESCADAS en $GCLAUDE (bloque reemplazado en su lugar; respaldo en $GCLAUDE.bak)"
    else
      rm -f "$tmp"; echo "warn: no pude refrescar el bloque de normas en $GCLAUDE"
    fi
  fi
else
  { [ -f "$GCLAUDE" ] && printf '\n'; cat "$SRC_NORMS/global-claude-md.md"; } >> "$GCLAUDE"
  echo "ok: normas globales del cerebro agregadas a $GCLAUDE"
fi

# ── (d3) Artefacto LEAN de aliases + @import en el CLAUDE.md global ──
# El detalle CURADO/verboso vive en entorno-esta-maquina.md (arriba). Este es la VISTA DERIVADA LEAN,
# answer-first (el ESCAPE primero), pensada para estar SIEMPRE en contexto vía `@import` recursivo del
# CLAUDE.md — sin costarle líneas al propio CLAUDE.md. Es GENERADO per-máquina → NO viaja por git.
# En Windows el .ps1 ya escribió el bloque `<!-- shells:powershell -->` ANTES de delegar aquí; esta lib
# sólo (re)escribe el bloque `<!-- shells:posix -->` → ambos coexisten sin pisarse. Fail-safe: sin la lib,
# se omite (no rompe la instalación).
ART="$CLAUDE_DIR/aliases-activos.md"
if command -v ds_render_posix >/dev/null 2>&1; then
  ds_ensure_artifact_header "$ART"
  if ds_render_posix 2>/dev/null | ds_upsert_block "$ART" posix; then
    echo "ok: artefacto LEAN de aliases (re)generado en $ART (bloque posix)"
  else
    echo "warn: no pude generar el bloque posix de $ART"
  fi
  # Cablear el @import idempotente, FUERA del bloque BEGIN/END cortex (que se regenera): su propio
  # marcador. Claude Code procesa @imports recursivos → el artefacto queda siempre en contexto.
  # GUARDA anti-truncado (misma que el bloque de normas): un CLAUDE.md con BEGIN sin END está en estado
  # PELIGROSO → NO lo tocamos (ni para appendear el @import), para no arriesgar la sección personal.
  if [ -f "$GCLAUDE" ] && grep -q 'BEGIN cortex' "$GCLAUDE" 2>/dev/null && ! grep -q 'END cortex' "$GCLAUDE" 2>/dev/null; then
    echo "warn: $GCLAUDE tiene BEGIN sin END — NO cablo el @import (no toco un archivo en estado peligroso). Ciérralo y re-corre."
  elif [ -f "$GCLAUDE" ] && grep -q 'brain:import-aliases' "$GCLAUDE" 2>/dev/null; then
    echo "ok: @import de aliases-activos.md ya cableado en $GCLAUDE (idempotente)"
  else
    {
      [ -f "$GCLAUDE" ] && printf '\n'
      printf '<!-- brain:import-aliases — VISTA per-máquina de aliases que muerden; GENERADA, NO viaja por git -->\n'
      printf '@aliases-activos.md\n'
    } >> "$GCLAUDE"
    echo "ok: @import de aliases-activos.md cableado en $GCLAUDE (siempre en contexto)"
  fi
else
  echo "warn: lib detectar-shells.sh no disponible; omito el artefacto LEAN de aliases y su @import"
fi

# fetch.prune global: que `git fetch` borre solos los refs remotos ya eliminados (surface de las ramas
# `: gone`). Es lo que mantiene fresco el marcador que usa limpiar-ramas.sh. Idempotente y no destructivo.
if [ "$(git config --global --get fetch.prune 2>/dev/null)" != "true" ]; then
  git config --global fetch.prune true 2>/dev/null && echo "ok: git config --global fetch.prune=true (ramas remotas borradas se limpian solas al hacer fetch)"
fi

echo "listo: cerebro global instalado (hooks + cableado + skill + sello de versión + dashboard + entorno + como-trabajar + normas + aliases-activos)."
echo "       Los hooks repo-scoped (sesion-inicio, dod-verificar) viven en"
echo "       brain/hooks/ como fuente: cópialos al .claude/ de cada repo (se cargan al INICIAR ahí)."
