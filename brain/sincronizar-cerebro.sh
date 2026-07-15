#!/usr/bin/env bash
# sincronizar-cerebro.sh — despliega/actualiza la copia POR-REPO del cerebro (claude-brain) en un repo
# consumidor (p. ej. un repo .NET), desde brain/ como FUENTE ÚNICA. Antídoto al drift: la copia
# por-repo deja de curarse a mano y se DERIVA del MANIFEST (tier {repo, both}).
#
# Qué copia a <repo>/.claude/hooks/: los archivos de tier {repo, both} (hooks + libs que sourcean),
# NO los global-only (esos los pone el bootstrap en ~/.claude). Además:
#   - estampa la VERSIÓN del cerebro en <repo>/.claude/hooks/.brain-version (drift por versión detectable),
#   - CABLEA en <repo>/.claude/settings.json (idempotente, "shell":"bash", ruta ${CLAUDE_PROJECT_DIR}/...)
#     los hooks de kind=hook de tier {repo, both} (evento por el mapa de abajo),
#   - REPORTA huérfanos: .sh en el destino que NO están en el manifiesto (candidatos a retiro; NO los
#     borra — podrían estar cableados; el retiro es una decisión deliberada).
#
# SEGURO por default: DRY-RUN (muestra qué cambiaría, no escribe). Con --apply copia y cablea.
# NO es `cp -f` ciego: diffea archivo por archivo y solo toca los que cambian. Requiere jq para cablear.
#
# --only <csv>: restringe la sincronización a esos nombres (sin .sh), útil para propagar un slice
#   acotado (p. ej. solo la lib + los wrappers que cambiaron) sin arrastrar drift de otros archivos
#   que se reconcilian en otro momento. Siempre respeta el tier del manifiesto (solo {repo,both}).
#
# --prune-orphans: RETIRA (de-wire del settings.json + borra el .sh) los huérfanos = archivos en el
#   destino que ya NO están en el manifiesto (el cerebro los retiró). Es DESTRUCTIVO → solo con --apply
#   borra; en dry-run los lista como "RETIRARÍA". Antídoto a un hook retirado que quedó cableado y
#   rompe (caso real: el viejo precompact-volcar-estado intentaba inyectar y el CLI lo rechazaba).
#
# Uso:  bash sincronizar-cerebro.sh <ruta-repo-destino> [--apply] [--only a,b,c] [--prune-orphans]
set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SRC_HOOKS="$SCRIPT_DIR/hooks"
MANIFEST="$SRC_HOOKS/MANIFEST"
VERSION_FILE="$SCRIPT_DIR/VERSION"

DEST=""; APPLY=0; ONLY=""; PRUNE=0; PRUNEONLY=0
while [ $# -gt 0 ]; do
  case "$1" in
    --apply) APPLY=1 ;;
    --only)  shift; ONLY="${1:-}" ;;
    --only=*) ONLY="${1#--only=}" ;;
    --prune-orphans) PRUNE=1 ;;
    --prune-only) PRUNE=1; PRUNEONLY=1 ;;   # SOLO retira huérfanos; NO sincroniza nada más (fix quirúrgico)
    -*) echo "ERROR: flag desconocido: $1"; exit 2 ;;
    *) [ -z "$DEST" ] && DEST="$1" || { echo "ERROR: argumento inesperado: $1"; exit 2; } ;;
  esac
  shift
done

if [ -z "$DEST" ] || [ ! -d "$DEST" ]; then
  echo "Uso: bash sincronizar-cerebro.sh <ruta-repo-destino> [--apply] [--only a,b,c]"
  echo "  (sin --apply = DRY-RUN: muestra qué cambiaría, no escribe)"
  exit 2
fi
# ¿el nombre está en el filtro --only? (sin filtro → todo pasa). CSV a espacios, match exacto.
only_ok() { [ -z "$ONLY" ] && return 0; printf '%s' "$ONLY" | tr ',' '\n' | grep -qxF "$1"; }
[ -f "$MANIFEST" ] || { echo "ERROR: falta $MANIFEST"; exit 1; }

DST_HOOKS="$DEST/.claude/hooks"
DST_SET="$DEST/.claude/settings.json"
VER="$( [ -f "$VERSION_FILE" ] && head -1 "$VERSION_FILE" || echo '?' )"

echo "==> sincronizar-cerebro (v$VER) — FUENTE: $SRC_HOOKS"
echo "    DESTINO: $DST_HOOKS"
[ "$APPLY" = 1 ] && echo "    modo: APPLY (escribe)" || echo "    modo: DRY-RUN (no escribe; usa --apply para aplicar)"
echo ""

# Evento+matcher para cablear los kind=hook de tier {repo,both}. (Los global-only los cablea el bootstrap.)
ev_de() {
  case "$1" in
    git-branch-guard|merge-squash-guard|confirmar-merge-develop|recordar-dashboard|secret-scan) echo "PreToolUse|Bash" ;;
    dod-verificar)  echo "Stop|" ;;
    sesion-inicio)  echo "SessionStart|" ;;
    *) echo "" ;;
  esac
}

# register_hook <settings.json> <event> <matcher> <cmd> <patrón-dedupe>  (idempotente, igual que install-brain)
register_hook() {
  local gset="$1" ev="$2" m="$3" cmd="$4" pat="$5" tmp
  command -v jq >/dev/null 2>&1 || { echo "  warn: jq no está; cablea '$pat' a mano en $gset"; return; }
  [ -f "$gset" ] || echo '{}' > "$gset"
  tmp="$(mktemp)" || return
  if jq --arg ev "$ev" --arg m "$m" --arg cmd "$cmd" --arg pat "$pat" '
      .hooks = (.hooks // {}) |
      .hooks[$ev] = (.hooks[$ev] // []) |
      if any(.hooks[$ev][]?; ([.hooks[]?.command] | join(" ")) | test($pat))
      then . else .hooks[$ev] += [ (if $m=="" then {} else {"matcher":$m} end) + {"hooks":[{"type":"command","command":$cmd,"shell":"bash"}]} ] end
    ' "$gset" > "$tmp" 2>/dev/null && [ -s "$tmp" ]; then mv "$tmp" "$gset"; else rm -f "$tmp"; echo "  warn: no pude cablear ($pat)"; fi
}

# ── Sincronizar los archivos de tier {repo, both} (se SALTA entero con --prune-only) ──
n_new=0; n_upd=0; n_ok=0; n_wire=0
PER_REPO="$(awk '$1!~/^#/ && NF>=3 && ($2=="repo"||$2=="both"){print $1"|"$3}' "$MANIFEST")"

[ "$PRUNEONLY" = 1 ] && echo "  (--prune-only: NO sincronizo hooks; solo retiro huérfanos)"
[ "$APPLY" = 1 ] && [ "$PRUNEONLY" != 1 ] && mkdir -p "$DST_HOOKS"
while [ "$PRUNEONLY" != 1 ] && IFS='|' read -r name kind; do
  [ -z "$name" ] && continue
  only_ok "$name" || continue
  src="$SRC_HOOKS/$name.sh"; dst="$DST_HOOKS/$name.sh"
  if [ ! -f "$src" ]; then echo "  warn: el manifiesto lista $name pero falta $src"; continue; fi
  if [ ! -f "$dst" ]; then
    echo "  NUEVO      $name.sh ($kind)"; n_new=$((n_new+1))
    [ "$APPLY" = 1 ] && { cp -f "$src" "$dst"; chmod +x "$dst"; }
  elif ! diff -q "$src" "$dst" >/dev/null 2>&1; then
    echo "  ACTUALIZA  $name.sh ($kind)  [$(diff "$src" "$dst" 2>/dev/null | grep -cE '^[<>]') líneas ±]"; n_upd=$((n_upd+1))
    [ "$APPLY" = 1 ] && { cp -f "$src" "$dst"; chmod +x "$dst"; }
  else
    n_ok=$((n_ok+1))
  fi
  # Cablear (solo kind=hook; libs/scripts no se cablean)
  if [ "$kind" = "hook" ]; then
    evm="$(ev_de "$name")"
    if [ -n "$evm" ]; then
      ev="${evm%%|*}"; m="${evm#*|}"
      if [ "$APPLY" = 1 ]; then
        register_hook "$DST_SET" "$ev" "$m" "bash \"\${CLAUDE_PROJECT_DIR}/.claude/hooks/$name.sh\"" "$name"
      fi
      n_wire=$((n_wire+1))
    else
      echo "  warn: no tengo evento para cablear $name (agrégalo a ev_de)"
    fi
  fi
done <<EOF
$PER_REPO
EOF

# ── Estampar la versión SOLO en sync COMPLETO: cualquier operación PARCIAL (--only o --prune-only) NO
# representa esa versión (el repo no queda completo) → estamparla MENTIRÍA sobre el estado del cerebro. ──
if [ "$APPLY" = 1 ] && [ -z "$ONLY" ] && [ "$PRUNEONLY" != 1 ] && [ -f "$VERSION_FILE" ]; then
  cp -f "$VERSION_FILE" "$DST_HOOKS/.brain-version"
  echo ""; echo "  sello: $DST_HOOKS/.brain-version = v$VER"
elif [ "$APPLY" = 1 ] && { [ -n "$ONLY" ] || [ "$PRUNEONLY" = 1 ]; }; then
  echo ""; echo "  (operación PARCIAL (--only/--prune-only): NO estampo versión — el repo no queda completo en v$VER)"
fi

# De-cablea del settings.json TODAS las entradas cuyo 'command' cite el basename del hook (jq).
dewire_hook() {
  local gset="$1" base="$2" tmp
  command -v jq >/dev/null 2>&1 || { echo "  warn: jq no está; quita a mano '$base' de $gset"; return; }
  [ -f "$gset" ] || return
  tmp="$(mktemp)" || return
  if jq --arg pat "$base\\.sh" '
      if (.hooks|type)=="object" then
        .hooks |= ( to_entries
          | map(.value |= [ .[] | select((([.hooks[]?.command]|join(" "))|test($pat))|not) ])
          | map(select((.value|type)=="array" and (.value|length)>0)) | from_entries )
        | (if (.hooks|length)==0 then del(.hooks) else . end)
      else . end
    ' "$gset" > "$tmp" 2>/dev/null && [ -s "$tmp" ]; then mv "$tmp" "$gset"; else rm -f "$tmp"; echo "  warn: no pude de-cablear ($base)"; fi
}

# ── Huérfanos (en el destino, .sh que NO están en el manifiesto). Con --prune-orphans (+ --apply) se RETIRAN. ──
echo ""
n_orph=0
if [ -d "$DST_HOOKS" ]; then
  for f in "$DST_HOOKS"/*.sh; do
    [ -e "$f" ] || continue
    b="$(basename "$f" .sh)"
    if ! awk '$1!~/^#/ && NF>=3 {print $1}' "$MANIFEST" | grep -qxF "$b"; then
      n_orph=$((n_orph+1))
      if [ "$PRUNE" = 1 ] && [ "$APPLY" = 1 ]; then
        dewire_hook "$DST_SET" "$b"; rm -f "$f"
        echo "  RETIRADO   $b.sh — de-cableado del settings.json + borrado (huérfano, retirado del cerebro)"
      elif [ "$PRUNE" = 1 ]; then
        echo "  RETIRARÍA  $b.sh — huérfano; de-cablearía + borraría (usa --apply)"
      else
        echo "  HUÉRFANO   $b.sh — no está en el manifiesto (¿retirado del cerebro? usa --prune-orphans para retirarlo; NO lo borro por default)"
      fi
    fi
  done
fi

echo ""
echo "==> resumen: $n_new nuevos · $n_upd a actualizar · $n_ok ya al día · $n_wire hooks cableados (kind=hook)"
[ "$APPLY" = 1 ] || echo "    (DRY-RUN — nada escrito. Re-corre con --apply para aplicar.)"
