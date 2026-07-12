#!/usr/bin/env bash
# limpiar-worktrees.sh — barre los worktrees de git de ESTE repo tras un fan-out: BORRA los de ramas
# ya mergeadas (zombies) y DEJA los de ramas vivas/a-medias, anotando su pendiente en la bitácora para
# quien lo retome. Antídoto a los worktrees zombies que se acumulan (caso cps: 29). SEGURO: nunca toca
# el worktree principal; ante duda (offline, sin señal clara) CONSERVA.
#   uso: limpiar-worktrees.sh [--dry-run]   (desde cualquier lugar del repo)
#
# "Mergeada" es doble porque el flujo SQUASHEA (la rama NO queda de ancestro): (a) ancestro de la base
# (flujo merge-commit) O (b) la rama fue pusheada y su rama remota YA no existe (se borró al mergear
# con --delete-branch, típico del squash). Una rama local nunca pusheada NO se considera zombie.
set -u
DRY=0; [ "${1:-}" = "--dry-run" ] && DRY=1
ROOT=$(git rev-parse --show-toplevel 2>/dev/null) || { echo "limpiar-worktrees: no es un repo git" >&2; exit 1; }
MAIN_WT=$(git -C "$ROOT" rev-parse --show-toplevel)
BITA="$ROOT/.claude/memory/bitacora.md"
base=develop
git -C "$ROOT" rev-parse --verify -q refs/heads/develop >/dev/null 2>&1 || base=$(git -C "$ROOT" symbolic-ref --short -q refs/remotes/origin/HEAD 2>/dev/null | sed 's#origin/##' || echo main)

es_zombie() {  # $1 = rama
  local br="$1" up
  git -C "$ROOT" merge-base --is-ancestor "$br" "$base" 2>/dev/null && return 0   # (a) merge-commit
  up=$(git -C "$ROOT" rev-parse --abbrev-ref "$br@{upstream}" 2>/dev/null) || return 1  # nunca pusheada → conservar
  git -C "$ROOT" ls-remote --exit-code --heads "${up%%/*}" "${up#*/}" >/dev/null 2>&1 && return 1 || return 0  # (b) remota borrada
}

borrados=0; dejados=0; pend=""; wt=""
while IFS= read -r line; do
  case "$line" in
    "worktree "*) wt="${line#worktree }" ;;
    "branch "*)
      br="${line#branch refs/heads/}"
      [ "$wt" = "$MAIN_WT" ] && continue
      if es_zombie "$br"; then
        if [ "$DRY" = 1 ]; then echo "  [dry] zombie: $wt (rama $br)"; borrados=$((borrados+1))
        else git -C "$ROOT" worktree remove --force "$wt" 2>/dev/null && { borrados=$((borrados+1)); echo "  borrado zombie: $wt ($br)"; }; fi
      else
        dejados=$((dejados+1)); pend="$pend
  - worktree \`${wt##*/}\` (rama \`$br\`) sin mergear a $base — retomar o cerrar."
        echo "  DEJADO (vivo): $wt ($br)"
      fi ;;
  esac
done < <(git -C "$ROOT" worktree list --porcelain 2>/dev/null)

if [ "$DRY" = 0 ]; then
  git -C "$ROOT" worktree prune 2>/dev/null
  if [ -n "$pend" ] && [ -f "$BITA" ]; then
    printf '%s\n' "- **[worktrees pendientes tras barrido]**$pend" >> "$BITA"
    echo "  (pendientes anotados en bitacora.md)"
  fi
fi
echo "limpiar-worktrees: $borrados zombie(s), $dejados vivo(s) conservado(s)."
