#!/usr/bin/env bash
# limpiar-ramas.sh — barre las RAMAS LOCALES ya integradas de ESTE repo: BORRA las que su MR se mergeó
# (típicamente con --squash, y el remoto se borró al cerrar → localmente quedan `: gone`) y CONSERVA las
# que tienen trabajo sin integrar. Antídoto ESTRUCTURAL a la acumulación de ramas squasheadas: el squash
# rompe la detección de "mergeada" de `git branch -d` (la rama no queda de ancestro) y `fetch --prune`
# NO borra ramas locales → nadie las barría y se acumulaban (un caso real: 60+ en un repo).
#   uso: limpiar-ramas.sh [--dry-run] [--no-fetch]   (desde cualquier lugar del repo)
#
# SEGURO: reusa la MISMA lógica "zombie" (bz_es_zombie) y "protegida" (bz_protegida) que limpiar-worktrees
# — lib ramas-zombie.sh — conserva ante CUALQUIER duda (rama nunca pusheada, con commits únicos, o squash
# multi-commit no-emparejable ni confirmable por el host). NUNCA toca la rama actual, la base de
# integración, develop/main, las mini-develop (Develop*) ni keep/*.
#
# A-1 (auditoría 2026-09-11, "no silent caps"): el resumen antes solo contaba borradas/conservadas y las
# protegidas desaparecían sin dejar rastro (`continue` antes de contar) — invitaba a leer N+M como el
# universo cuando en realidad podía haber más ramas protegidas fuera de la vista. Ahora se examinan TODAS
# y las omitidas se cuentan y NOMBRAN con su motivo en el resumen final.
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
bz_aviso="$(bz_aviso_base "$ROOT")"
[ -n "$bz_aviso" ] && echo "  (aviso: $bz_aviso — Base: $base)"   # M-2
actual="$(git -C "$ROOT" symbolic-ref --short -q HEAD 2>/dev/null || true)"
# Ramas checked-out en CUALQUIER worktree: git rehúsa `branch -D` sobre ellas (protección propia de git).
# Se protegen explícitamente para que el reporte no diga "borraría" algo que nunca se borraría — sobre todo
# ahora que la señal (d) 'PR mergeado' caza ramas integradas que siguen checked-out en el worktree del dev.
wt_ramas="$(git -C "$ROOT" worktree list --porcelain 2>/dev/null | sed -n 's#^branch refs/heads/##p')"

# Remoto configurado (upstream) de una rama; vacío si no tiene → cae a 'origin'. Se consulta ANTES del
# `branch -D` (tras borrar la rama local su @{upstream} ya no resuelve).
rama_remoto() {  # $1 = rama → nombre del remoto
  local up
  up=$(git -C "$ROOT" rev-parse --abbrev-ref "$1@{upstream}" 2>/dev/null) && [ -n "$up" ] && { printf '%s' "${up%%/*}"; return 0; }
  printf 'origin'
}

# _join SEP CUR NUEVO → concatena sin arrays (bash 3.2 + `set -u` no toleran "${arr[@]}" vacío en algunas
# versiones) — usado para las listas de nombres del resumen final.
_join() { [ -z "$2" ] && printf '%s' "$3" || printf '%s%s%s' "$2" "$1" "$3"; }

# 1a — LIMPIEZA COMPLETA: tras borrar el zombie LOCAL, si su rama REMOTA AÚN cuelga, bórrala también. Un
# MR squash-mergeado SIN --delete-branch/--remove-source-branch deja la remota huérfana; las señales
# a/e/d/c de bz_es_zombie declaran zombie CON la remota todavía presente → aquí se cierra ese hueco.
#
# C-1 (auditoría 2026-09-11, PÉRDIDA DE DATOS): antes se decidía con `ls-remote --exit-code` — que solo
# pregunta si la remota EXISTE, no QUÉ TIENE. Si la remota va adelante del tip local (un colega siguió
# trabajando en esa rama tras el squash, o simplemente estás atrasado), el push --delete borraba SU
# trabajo. Ahora se exige CONTAINMENT: el SHA remoto debe ser ANCESTRO del tip LOCAL (capturado ANTES del
# `branch -D`, cuando la rama local todavía resuelve). Si no se puede confirmar (objeto ausente, sin red,
# remota adelantada) → NO se borra, y se dice por qué.
barrer_remota() {  # $1 = rama zombie   $2 = nombre del remoto   $3 = SHA del tip LOCAL (antes de -D)
  local br="$1" remoto="$2" local_sha="$3" rout rc rsha
  [ -n "$remoto" ] || return 0
  rout="$(git -C "$ROOT" ls-remote --heads "$remoto" "$br" 2>/dev/null)"; rc=$?
  if [ "$rc" -ne 0 ]; then
    echo "  (remota $remoto/$br: no se pudo consultar — ¿sin red/permiso? NO se borra)"
    return 0
  fi
  rsha="$(printf '%s' "$rout" | awk '{print $1; exit}')"
  [ -n "$rsha" ] || return 0   # la remota ya no existe → nada que hacer
  if [ -z "$local_sha" ] \
     || ! git -C "$ROOT" cat-file -e "${rsha}^{commit}" 2>/dev/null \
     || ! git -C "$ROOT" merge-base --is-ancestor "$rsha" "$local_sha" 2>/dev/null; then
    echo "  (remota $remoto/$br va ADELANTE del tip local o no se pudo verificar → NO se borra)"
    return 0
  fi
  if [ "$DRY" = 1 ]; then echo "  [dry] remota contenida en el tip local → borraría: $remoto/$br"; return 0; fi
  if git -C "$ROOT" push "$remoto" --delete "$br" >/dev/null 2>&1; then
    echo "  remota borrada: $remoto/$br"
  else
    echo "  (remota $remoto/$br cuelga pero no se pudo borrar — ¿sin red/permiso? se omite)"
  fi
}

borradas=0; conservadas=0; total=0
omit_ba=0; omit_ba_n=""; omit_cv=0; omit_cv_n=""; omit_wt=0; omit_wt_n=""
while IFS= read -r br; do
  [ -z "$br" ] && continue
  total=$((total+1))
  if bz_protegida "$br" "$base" "$actual" "$wt_ramas"; then
    case "$BZ_PROT_RAZON" in
      base_actual) omit_ba=$((omit_ba+1)); omit_ba_n="$(_join ', ' "$omit_ba_n" "$br")" ;;
      convencion)  omit_cv=$((omit_cv+1)); omit_cv_n="$(_join ', ' "$omit_cv_n" "$br")" ;;
      worktree)    omit_wt=$((omit_wt+1)); omit_wt_n="$(_join ', ' "$omit_wt_n" "$br")" ;;
    esac
    continue
  fi
  if bz_es_zombie "$ROOT" "$br" "$base"; then
    remoto_pre="$(rama_remoto "$br")"
    local_sha="$(git -C "$ROOT" rev-parse "$br" 2>/dev/null || true)"
    if [ "$DRY" = 1 ]; then
      echo "  [dry] integrada → borraría: $br"; borradas=$((borradas+1)); barrer_remota "$br" "$remoto_pre" "$local_sha"
    else
      if git -C "$ROOT" branch -D "$br" >/dev/null 2>&1; then
        borradas=$((borradas+1)); echo "  borrada: $br"
        barrer_remota "$br" "$remoto_pre" "$local_sha"
      fi
    fi
  else
    if [ "$BZ_RAZON" = indeterminado ]; then
      conservadas=$((conservadas+1))
      echo "  INDETERMINADA (no pude consultar el foro: gh/glab no disponible o host no reconocido — se conserva): $br"
    else
      conservadas=$((conservadas+1)); echo "  CONSERVADA (trabajo sin integrar): $br"
    fi
  fi
done < <(git -C "$ROOT" for-each-ref --format='%(refname:short)' refs/heads 2>/dev/null)

omit_total=$((omit_ba+omit_cv+omit_wt))
detalle=""
[ "$omit_ba" -gt 0 ] && detalle="$(_join '; ' "$detalle" "$omit_ba base/actual: $omit_ba_n")"
[ "$omit_cv" -gt 0 ] && detalle="$(_join '; ' "$detalle" "$omit_cv protegida(s) por convención: $omit_cv_n")"
[ "$omit_wt" -gt 0 ] && detalle="$(_join '; ' "$detalle" "$omit_wt retenida(s) por worktree: $omit_wt_n")"

resumen="limpiar-ramas: examinadas $total de $total → $borradas integrada(s)$([ "$DRY" = 1 ] && echo ' (dry-run, no borradas)'), $conservadas con trabajo conservada(s)"
[ "$omit_total" -gt 0 ] && resumen="$resumen, $omit_total omitida(s) ($detalle)"
resumen="$resumen. Base: $base."
echo "$resumen"
