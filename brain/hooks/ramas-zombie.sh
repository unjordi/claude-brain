#!/usr/bin/env bash
# ramas-zombie.sh — LIB compartida (no se cablea; se hace `source`). Decide si una rama YA está integrada
# ("zombie") de forma robusta al flujo SQUASH, y resuelve la base de integración. La consumen
# `limpiar-worktrees.sh` (barre worktrees) y `limpiar-ramas.sh` (barre ramas locales) → una sola
# definición de "mergeada", sin divergencia (antídoto al drift entre los dos barredores).
#
# "Mergeada" es TRIPLE porque el flujo SQUASHEA (la rama NO queda de ancestro): (a) ancestro de la base
# (flujo merge-commit) O (b) la rama fue pusheada y su rama remota YA no existe (se borró al mergear con
# --delete-branch, típico del squash → localmente queda marcada `: gone`) O (c) sus commits ya están en
# la base por EQUIVALENCIA de parche (git cherry) — el merge LOCAL a la rama personal (mini-develop) y
# los cherry-picks. Un squash de VARIOS commits a uno NO empareja patch-id → se CONSERVA (mejor un
# zombie de más que borrar trabajo vivo). Una rama NUNCA pusheada y sin equivalencia → se CONSERVA.

# bz_resolver_base ROOT → imprime la base de integración.
# La base es configurable (CLAUDE_INTEGRACION_BASE): en el flujo mini-develop NO es develop sino TU rama
# personal (p. ej. `DevelopAna`). Sin override: develop, o la rama por defecto del remoto, o main.
bz_resolver_base() {
  local ROOT="$1" base="${CLAUDE_INTEGRACION_BASE:-}"
  if [ -z "$base" ]; then
    base=develop
    git -C "$ROOT" rev-parse --verify -q refs/heads/develop >/dev/null 2>&1 \
      || base=$(git -C "$ROOT" symbolic-ref --short -q refs/remotes/origin/HEAD 2>/dev/null | sed 's#origin/##' || echo main)
  fi
  printf '%s' "$base"
}

# bz_es_zombie ROOT BR BASE → 0 si BR ya está integrada a BASE (zombie), 1 si conservar.
bz_es_zombie() {
  local ROOT="$1" br="$2" base="$3" up cherry
  git -C "$ROOT" merge-base --is-ancestor "$br" "$base" 2>/dev/null && return 0   # (a) ancestro de la base
  # (c) squash/cherry a la base: los commits de la rama ya están en base por EQUIVALENCIA de parche
  # (git cherry los marca '-'; NINGUNO '+').
  cherry=$(git -C "$ROOT" cherry "$base" "$br" 2>/dev/null)
  [ -n "$cherry" ] && ! printf '%s\n' "$cherry" | grep -q '^+' && return 0
  up=$(git -C "$ROOT" rev-parse --abbrev-ref "$br@{upstream}" 2>/dev/null) || return 1  # nunca pusheada → conservar
  git -C "$ROOT" ls-remote --exit-code --heads "${up%%/*}" "${up#*/}" >/dev/null 2>&1 && return 1 || return 0  # (b) remota borrada
}
