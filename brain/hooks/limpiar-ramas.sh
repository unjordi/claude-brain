#!/usr/bin/env bash
# limpiar-ramas.sh — barre las RAMAS LOCALES ya integradas de ESTE repo: BORRA las que su MR se mergeó
# (típicamente con --squash, y el remoto se borró al cerrar → localmente quedan `: gone`) y CONSERVA las
# que tienen trabajo sin integrar. Antídoto ESTRUCTURAL a la acumulación de ramas squasheadas: el squash
# rompe la detección de "mergeada" de `git branch -d` (la rama no queda de ancestro) y `fetch --prune`
# NO borra ramas locales → nadie las barría y se acumulaban (un caso real: 60+ en un repo).
#   uso: limpiar-ramas.sh [--dry-run] [--no-fetch]   (desde cualquier lugar del repo)
#
# SEGURO: reusa la MISMA lógica "zombie" que limpiar-worktrees (lib ramas-zombie.sh) — conserva ante
# CUALQUIER duda (rama nunca pusheada, con commits únicos, o squash multi-commit no-emparejable). NUNCA
# toca la rama actual, la base de integración, develop/main, las mini-develop (Develop*) ni keep/*.
set -u
DRY=0; FETCH=1
for a in "$@"; do
  case "$a" in
    --dry-run) DRY=1 ;;
    --no-fetch) FETCH=0 ;;
    *) echo "limpiar-ramas: opción desconocida '$a' (usa --dry-run / --no-fetch)" >&2; exit 2 ;;
  esac
done
ROOT=$(git rev-parse --show-toplevel 2>/dev/null) || { echo "limpiar-ramas: no es un repo git" >&2; exit 1; }
# shellcheck source=ramas-zombie.sh
. "$(dirname "$0")/ramas-zombie.sh"

# fetch --prune: refresca los refs remotos (surface de las remotas ya borradas) para que la detección de
# "remota borrada" sea fiel. Se puede saltar (--no-fetch) si estás offline o ya lo corriste.
[ "$FETCH" = 1 ] && git -C "$ROOT" fetch --all --prune -q 2>/dev/null

base="$(bz_resolver_base "$ROOT")"
actual="$(git -C "$ROOT" symbolic-ref --short -q HEAD 2>/dev/null || true)"

# Ramas NUNCA candidatas a borrar, pase lo que pase (bases y guardadas a propósito).
protegida() {  # $1 = rama
  case "$1" in
    "$base"|"$actual"|develop|main|Develop*|keep/*) return 0 ;;
    *) return 1 ;;
  esac
}

borradas=0; conservadas=0
while IFS= read -r br; do
  [ -z "$br" ] && continue
  protegida "$br" && continue
  if bz_es_zombie "$ROOT" "$br" "$base"; then
    if [ "$DRY" = 1 ]; then echo "  [dry] integrada → borraría: $br"; borradas=$((borradas+1))
    else git -C "$ROOT" branch -D "$br" >/dev/null 2>&1 && { borradas=$((borradas+1)); echo "  borrada: $br"; }; fi
  else
    conservadas=$((conservadas+1)); echo "  CONSERVADA (trabajo sin integrar): $br"
  fi
done < <(git -C "$ROOT" for-each-ref --format='%(refname:short)' refs/heads 2>/dev/null)

echo "limpiar-ramas: $borradas integrada(s)$([ "$DRY" = 1 ] && echo ' (dry-run, no borradas)'), $conservadas con trabajo conservada(s). Base: $base."
