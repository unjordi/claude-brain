#!/usr/bin/env bash
# limpiar-worktrees.sh — barre los worktrees de git de ESTE repo tras un fan-out: BORRA los de ramas
# ya mergeadas (zombies) y DEJA los de ramas vivas/a-medias, anotando su pendiente en la bitácora para
# quien lo retome. Antídoto a los worktrees zombies que se acumulan (un caso real: 29). SEGURO: nunca toca
# el worktree principal, nunca toca una rama PROTEGIDA (base/actual/develop/main/Develop*/keep/*), y
# nunca destruye trabajo sin commitear; ante duda (offline, sin señal clara) CONSERVA.
#   uso: limpiar-worktrees.sh [--dry-run] [--purgar-sucios]   (desde cualquier lugar del repo)
#
# "Mergeada" es QUÍNTUPLE porque el flujo SQUASHEA (la rama NO queda de ancestro): (a) ancestro de la base
# O (e) el squash trae "Rama: <rama>" en su mensaje (señal local/offline) O (d) su PR/MR se MERGEÓ en el
# host (gh/glab) O (c) sus commits ya están en la base por EQUIVALENCIA de parche (git cherry) O (b) la
# rama fue pusheada y su rama remota YA no existe Y NO trae commits propios. Detalle en ramas-zombie.sh.
#
# Auditoría 2026-09-11 — tres arreglos de PÉRDIDA DE DATOS confirmada por ejecución:
#   C-2: este script NO tenía protección alguna (`grep -c protegida` daba 0) — borró el worktree de una
#        mini-develop con trabajo sin commitear y marcó `keep/*` como zombie. Ahora usa `bz_protegida`,
#        LA MISMA que limpiar-ramas.sh (una sola definición, sin divergencia).
#   C-3: `worktree remove --force` destruía cambios sin commitear/untracked de cualquier worktree "zombie"
#        (el veredicto de zombie es SOLO sobre la rama, nunca sobre el estado del árbol). Ahora se intenta
#        SIN --force primero; si git rehúsa por árbol sucio, se REPORTA y se CONSERVA — nunca se fuerza,
#        salvo con el flag explícito --purgar-sucios.
#   A-2: un typo en la única opción reconocida (`--dry-run`) caía a modo destructivo con rc=0. Ahora
#        cualquier opción desconocida aborta con rc=2 (igual que limpiar-ramas.sh).
#   M-4: un worktree `prunable` (su directorio ya no existe) se reportaba "vivo" y retenía su rama para
#        siempre. Ahora se poda (`git worktree prune`) ANTES del bucle, también en dry-run (no destruye
#        nada: solo depura registros de directorios que ya no existen).
#   M-6: `MAIN_WT` se calculaba como el toplevel del CWD (no el worktree PRINCIPAL real) — corriendo desde
#        un worktree enlazado, el principal quedaba SIN protección. Ahora es la primera entrada de
#        `git worktree list --porcelain` (git siempre lista el principal primero).
set -u
DRY=0; PURGAR_SUCIOS=0
for a in "$@"; do
  case "$a" in
    --dry-run) DRY=1 ;;
    --purgar-sucios) PURGAR_SUCIOS=1 ;;
    *) echo "limpiar-worktrees: opción desconocida '$a' (usa --dry-run / --purgar-sucios)" >&2; exit 2 ;;
  esac
done
ROOT=$(git rev-parse --show-toplevel 2>/dev/null) || { echo "limpiar-worktrees: no es un repo git" >&2; exit 1; }
# M-4: podar ANTES de listar — un worktree "prunable" (directorio borrado a mano, p. ej. un scratchpad
# efímero) no debe contarse como "vivo" reteniendo su rama. `worktree prune` es no-destructivo: solo
# depura registros de directorios que YA no existen, nunca toca archivos. Seguro también en dry-run.
git -C "$ROOT" worktree prune 2>/dev/null
# M-6: el worktree PRINCIPAL es la primera entrada de la lista (git la ordena así siempre), no el
# toplevel del cwd — si este script corre DESDE un worktree enlazado, el principal debe seguir protegido.
MAIN_WT="$(git -C "$ROOT" worktree list --porcelain 2>/dev/null | sed -n 's#^worktree ##p' | head -1)"
BITA="$ROOT/.claude/memory/bitacora.md"
# La lógica de "rama mergeada" (robusta al squash) + "protegida" + la base de integración viven en la lib
# compartida ramas-zombie.sh — la MISMA que usa limpiar-ramas.sh (una sola definición, sin divergencia).
# shellcheck source=ramas-zombie.sh
. "$(dirname "$0")/ramas-zombie.sh"
base="$(bz_resolver_base "$ROOT")"
bz_aviso="$(bz_aviso_base "$ROOT")"
[ -n "$bz_aviso" ] && echo "  (aviso: $bz_aviso — Base: $base)"   # M-2
es_zombie() { bz_es_zombie "$ROOT" "$1" "$base"; }  # $1 = rama

# _intentar_borrar WT — C-3: SIN --force primero (git rehúsa solo si hay cambios sin commitear/untracked).
# Si rehúsa, NO se fuerza por defecto: se reporta sucio y se conserva. Con --purgar-sucios, se fuerza (opt-in
# explícito) y se avisa igual. Devuelve 0 si quedó borrado, 1 si se conservó (sucio o error).
_intentar_borrar() {
  local wt="$1"
  if git -C "$ROOT" worktree remove "$wt" 2>/dev/null; then return 0; fi
  local n
  n=$(git -C "$wt" status --porcelain 2>/dev/null | wc -l | tr -d ' ')
  if [ "$PURGAR_SUCIOS" = 1 ]; then
    git -C "$ROOT" worktree remove --force "$wt" 2>/dev/null && { echo "  (purgado con --purgar-sucios pese a $n archivo(s) sin commitear)"; return 0; }
  fi
  echo "  SUCIO (no se toca): $wt — ${n:-?} archivo(s) sin commitear/untracked"
  return 1
}

borrados=0; dejados=0; protegidas=0; sucios=0; indeterminados=0; detached=0; pend=""; wt=""
while IFS= read -r line; do
  case "$line" in
    "worktree "*) wt="${line#worktree }" ;;
    "branch "*)
      br="${line#branch refs/heads/}"
      [ "$wt" = "$MAIN_WT" ] && continue
      if bz_protegida "$br" "$base"; then
        protegidas=$((protegidas+1))
        echo "  PROTEGIDA (no se toca — $BZ_PROT_RAZON): $wt ($br)"
        continue
      fi
      if es_zombie "$br"; then
        if [ "$DRY" = 1 ]; then
          # dry-run: previsualiza si el árbol está sucio (C-3) en vez de prometer un borrado que git rehusaría.
          n=$(git -C "$wt" status --porcelain 2>/dev/null | wc -l | tr -d ' ')
          if [ "${n:-0}" != 0 ]; then echo "  [dry] SUCIO (no se tocaría): $wt ($br) — $n archivo(s) sin commitear/untracked"
          else echo "  [dry] zombie: $wt ($br)"; fi
          borrados=$((borrados+1))
        else
          if _intentar_borrar "$wt"; then borrados=$((borrados+1)); echo "  borrado zombie: $wt ($br)"
          else sucios=$((sucios+1)); fi
        fi
      else
        # A-3/A-4: distinguir "vivo confirmado" de "indeterminado" (no se pudo consultar el host) — el
        # pendiente de bitácora SOLO se escribe cuando el veredicto es una afirmación real (A-4).
        if [ "$BZ_RAZON" = indeterminado ]; then
          indeterminados=$((indeterminados+1))
          echo "  INDETERMINADO (no pude consultar el foro: gh/glab no disponible o host no reconocido): $wt ($br)"
        else
          dejados=$((dejados+1))
          pend="$pend
  - worktree \`${wt##*/}\` (rama \`$br\`) sin mergear a $base — retomar o cerrar."
          echo "  DEJADO (vivo): $wt ($br)"
        fi
      fi ;;
    "detached")
      # M-3: un worktree en HEAD detached no emite línea "branch " → antes era invisible (ni zombie, ni
      # vivo, ni contado) y se acumulaba para siempre. Ahora se nombra explícitamente.
      [ "$wt" = "$MAIN_WT" ] && continue
      detached=$((detached+1))
      echo "  DETACHED (no evaluable, requiere revisión manual): $wt" ;;
  esac
done < <(git -C "$ROOT" worktree list --porcelain 2>/dev/null)

if [ "$DRY" = 0 ]; then
  git -C "$ROOT" worktree prune 2>/dev/null
  if [ -n "$pend" ] && [ -f "$BITA" ]; then
    # A-4: idempotencia — si YA hay un pendiente vigente para este worktree en la bitácora, no lo re-appendees
    # (el append-only nunca se limpia solo; sin esto, cada pasada de 24h/merge duplicaba el MISMO pendiente).
    pend_nuevo=""
    while IFS= read -r wline; do
      [ -z "$wline" ] && continue
      wtname="$(printf '%s' "$wline" | sed -n 's/^  - worktree `\([^`]*\)`.*/\1/p')"
      [ -n "$wtname" ] && grep -qF "worktree \`$wtname\`" "$BITA" 2>/dev/null && continue
      pend_nuevo="$pend_nuevo
$wline"
    done <<EOF_PEND
$pend
EOF_PEND
    if [ -n "$pend_nuevo" ]; then
      printf '%s\n' "- **[worktrees pendientes tras barrido]**$pend_nuevo" >> "$BITA"
      echo "  (pendientes anotados en bitacora.md)"
    fi
  fi
fi
echo "limpiar-worktrees: $borrados zombie(s), $dejados vivo(s) conservado(s), $protegidas protegido(s), $sucios sucio(s) conservado(s), $indeterminados indeterminado(s), $detached detached(s)."
