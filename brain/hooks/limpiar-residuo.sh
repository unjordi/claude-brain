#!/usr/bin/env bash
# limpiar-residuo.sh — barre el RESIDUO de housekeeping que ni `limpiar-ramas`/`limpiar-worktrees`
# (ramas y worktrees git) ni `barrer-flotilla-cerebro` (drift de cerebro) tocan: archivos que el propio
# cerebro va dejando atrás con el uso normal, sin ningún techo. Queja real de unjordi (2026-09):
# "qué pasa con lo que deja detrás... no todo eran ramas con worktree". Medido en vivo: 178MB en
# session-move-backups (ese lo poda session-move.js, por CANTIDAD), reubicar-backups SIN poda alguna,
# 17 logs de barrer-ramas acumulados, cachés de analizar-comando-git en $TMPDIR.
#
# RETENCIÓN POR EDAD, NUNCA POR CANTIDAD (regla dura de esta clase de residuo): un respaldo existe
# precisamente para recuperar un desastre — podar "los primeros N" descartaría el más viejo aunque sea
# el único que sobreviva a un desastre reciente si hubo una ráfaga de N+1 corridas. Podar por EDAD (con
# un default generoso) es lo conservador: un desastre se nota en días/semanas, no en meses.
#
# CONSERVADOR por construcción: cada clase solo toca un PATRÓN explícito reconocido dentro de UN
# directorio conocido (nunca "todo lo viejo de X"), y un error en una clase es fail-open — NUNCA aborta
# el barrido de las demás. Ninguna clase de aquí toca memoria/config/decisiones ni nada fuera de los
# patrones declarados abajo.
#
# Clases que barre:
#   1) <claude>/reubicar-backups/     — respaldos del skill de mudanza (reubicar-master): archivos
#      `*.pre-reubicar.jsonl` y directorios `*.t2` (el depósito T2 del full run). Antes: CERO poda, a
#      propósito (para no arriesgar el respaldo de una mudanza en curso) → crecían para siempre.
#      CLAUDE_RESIDUO_DIAS_BACKUPS (default 90).
#   2) <claude>/memory/.barrer-ramas/ — stamps de throttle (bare, `.merge`) + logs (`.log`,
#      `.worktrees.log`) que `barrer-ramas.sh` deja UNO por repo VISITADO, para siempre — ni se releen
#      tras el siguiente barrido de ESE repo ni nadie los borra. CLAUDE_RESIDUO_DIAS_LOGS (default 60).
#   3) $TMPDIR (o /tmp)               — cachés `acg-mrdest-*` de `analizar-comando-git.sh` (resolución
#      del destino de un MR/PR, por-proceso; archivos sueltos). CLAUDE_RESIDUO_DIAS_TMP (default 7): son
#      cachés de corta vida por diseño, no hace falta ser generoso aquí.
#
# Uso:
#   bash limpiar-residuo.sh [--dry-run] [--dias-backups N] [--dias-logs N] [--dias-tmp N] [--quiet]
# Honra CLAUDE_CONFIG_DIR (o $HOME/.claude) y $TMPDIR — así se aísla en tests sin tocar el ~/.claude real.
# bash-3.2-safe (macOS/Linux/Git Bash); usa `find -mtime` (portable BSD/GNU), sin GNU-ismos.
set -u

DRY=0; QUIET=0
DIAS_BACKUPS="${CLAUDE_RESIDUO_DIAS_BACKUPS:-90}"
DIAS_LOGS="${CLAUDE_RESIDUO_DIAS_LOGS:-60}"
DIAS_TMP="${CLAUDE_RESIDUO_DIAS_TMP:-7}"
for a in "$@"; do
  case "$a" in
    --dry-run) DRY=1 ;;
    --quiet) QUIET=1 ;;
    --dias-backups=*) DIAS_BACKUPS="${a#--dias-backups=}" ;;
    --dias-logs=*) DIAS_LOGS="${a#--dias-logs=}" ;;
    --dias-tmp=*) DIAS_TMP="${a#--dias-tmp=}" ;;
    *) echo "limpiar-residuo: opción desconocida '$a' (usa --dry-run/--dias-backups=N/--dias-logs=N/--dias-tmp=N/--quiet)" >&2; exit 2 ;;
  esac
done
case "$DIAS_BACKUPS" in ''|*[!0-9]*) DIAS_BACKUPS=90 ;; esac
case "$DIAS_LOGS" in ''|*[!0-9]*) DIAS_LOGS=60 ;; esac
case "$DIAS_TMP" in ''|*[!0-9]*) DIAS_TMP=7 ;; esac

CLAUDE_DIR="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
TMP_BASE="${TMPDIR:-/tmp}"

say() { [ "$QUIET" = 1 ] || printf '%s\n' "$1"; }

total_borrados=0; total_kb=0

# tamaño aproximado en KB de un archivo o directorio (`du -sk` es común a BSD y GNU); fail-open a 0.
kb_de() { du -sk "$1" 2>/dev/null | awk '{print $1; exit}'; }

# barre por PATRÓN + EDAD dentro de UN directorio (find -maxdepth 1, no recursivo salvo el propio
# patrón); nunca toca lo que no matchea. $1 dir  $2 patrón(find -name)  $3 dias  $4 tipo(f|d)  $5 etiqueta
barrer_patron() {
  local dir="$1" patron="$2" dias="$3" tipo="$4" etiqueta="$5" n=0 item kb
  [ -d "$dir" ] || return 0
  while IFS= read -r item; do
    [ -n "$item" ] || continue
    n=$((n + 1))
    kb="$(kb_de "$item")"; kb="${kb:-0}"
    if [ "$DRY" = 1 ]; then
      say "  [dry] ${etiqueta}: borraría $item (~${kb}KB)"
    else
      if [ "$tipo" = d ]; then rm -rf -- "$item" 2>/dev/null; else rm -f -- "$item" 2>/dev/null; fi
      say "  ${etiqueta}: borrado $item (~${kb}KB)"
    fi
    total_borrados=$((total_borrados + 1))
    total_kb=$((total_kb + kb))
  done < <(find "$dir" -maxdepth 1 -name "$patron" -type "$tipo" -mtime "+$dias" 2>/dev/null)
  [ "$n" -gt 0 ] && say "limpiar-residuo (${etiqueta}): $n candidato(s) en $dir (>${dias}d)."
}

say "limpiar-residuo: barriendo ($([ "$DRY" = 1 ] && echo 'dry-run, no borra nada' || echo 'aplicando'))…"

# 1) respaldos de la mudanza (reubicar-master) — por EDAD, nunca por cantidad (ver cabecera).
barrer_patron "$CLAUDE_DIR/reubicar-backups" '*.pre-reubicar.jsonl' "$DIAS_BACKUPS" f "reubicar-backups"
barrer_patron "$CLAUDE_DIR/reubicar-backups" '*.t2' "$DIAS_BACKUPS" d "reubicar-backups/t2"

# 2) logs/stamps de barrer-ramas (uno por repo visitado, para siempre).
barrer_patron "$CLAUDE_DIR/memory/.barrer-ramas" '*.log' "$DIAS_LOGS" f "barrer-ramas-logs"
barrer_patron "$CLAUDE_DIR/memory/.barrer-ramas" '*.worktrees.log' "$DIAS_LOGS" f "barrer-ramas-logs"
barrer_patron "$CLAUDE_DIR/memory/.barrer-ramas" '*.merge' "$DIAS_LOGS" f "barrer-ramas-stamps"
# el stamp PELÓN (nombre = solo el slug numérico, SIN sufijo): `! -name '*.*'` para no re-atrapar los
# .log/.worktrees.log/.merge de arriba (ya barridos primero → sin doble conteo, incluso en --dry-run).
{
  n=0
  while IFS= read -r item; do
    [ -n "$item" ] || continue
    n=$((n + 1))
    kb="$(kb_de "$item")"; kb="${kb:-0}"
    if [ "$DRY" = 1 ]; then
      say "  [dry] barrer-ramas-stamps: borraría $item (~${kb}KB)"
    else
      rm -f -- "$item" 2>/dev/null
      say "  barrer-ramas-stamps: borrado $item (~${kb}KB)"
    fi
    total_borrados=$((total_borrados + 1))
    total_kb=$((total_kb + kb))
  done < <(find "$CLAUDE_DIR/memory/.barrer-ramas" -maxdepth 1 -name '[0-9]*' ! -name '*.*' -type f -mtime "+$DIAS_LOGS" 2>/dev/null)
  [ "$n" -gt 0 ] && say "limpiar-residuo (barrer-ramas-stamps): $n candidato(s) (>${DIAS_LOGS}d)."
}

# 3) cachés de corta vida de analizar-comando-git.sh (archivos sueltos, nombre acg-mrdest-<clave>).
barrer_patron "$TMP_BASE" 'acg-mrdest-*' "$DIAS_TMP" f "acg-cache"

say "limpiar-residuo: $total_borrados elemento(s), ~${total_kb}KB $([ "$DRY" = 1 ] && echo 'que se liberarían' || echo 'liberados')."
exit 0
