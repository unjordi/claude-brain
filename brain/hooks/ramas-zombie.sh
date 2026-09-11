#!/usr/bin/env bash
# ramas-zombie.sh — LIB compartida (no se cablea; se hace `source`). Decide si una rama YA está integrada
# ("zombie") de forma robusta al flujo SQUASH, resuelve la base de integración, y decide si una rama es
# INTOCABLE pase lo que pase. La consumen `limpiar-worktrees.sh` (barre worktrees) y `limpiar-ramas.sh`
# (barre ramas locales) → una sola definición de "mergeada" Y de "protegida", sin divergencia (antídoto
# al drift entre los dos barredores — auditoría 2026-09-11: la protección solo vivía en uno de los dos).
#
# "Mergeada" es QUÍNTUPLE porque el flujo SQUASHEA (la rama NO queda de ancestro): (a) ancestro de la base
# (flujo merge-commit) O (e) el mensaje de squash trae la línea "Rama: <rama>" (convención del equipo,
# señal LOCAL/gratis/offline — ver abajo) O (d) su PR/MR se MERGEÓ en el host (señal autoritativa, depende
# de gh/glab) O (c) sus commits ya están en la base por EQUIVALENCIA de parche (git cherry) — el merge
# LOCAL a la mini-develop y los cherry-picks O (b) la rama fue pusheada, su rama remota YA no existe (se
# borró al mergear con --delete-branch, típico del squash → `: gone`) Y NO trae commits propios sin integrar.
#
# EL HUECO QUE CIERRA (e) (auditoría 2026-09-11, A-3): (d) es la ÚNICA señal que caza el squash de VARIOS
# commits (el caso MÁS común del flujo), y (d) depende de gh/glab — AUSENTES del PATH de launchd (el que
# hereda el hook cuando Claude corre desde la GUI) → (d) muere en silencio y el squash-multi-commit se
# CONSERVABA para siempre, sin decir que no pudo verificarse. (e) es determinista y NO depende de ningún
# binario externo: el equipo pone "Rama: <nombre>" en el mensaje de cada squash (convención existente),
# así que `git log --format=%B <base> | grep -qxF "Rama: <rama>"` prueba la integración sin red.
#
# EL HUECO QUE CERRÓ (d) en su momento: un squash de VARIOS commits a uno NO empareja patch-id → (c) no lo
# caza y (b) CONSERVA si git cherry marca algún '+'. (d) pregunta al HOST si el PR/MR de la rama se mergeó
# — si sí, sus commits están en la base aunque git no los empareje (y solo si el head mergeado CONTIENE el
# tip local, para no borrar trabajo post-merge). FAIL-OPEN: sin gh/glab, sin red, host no reconocido o
# error → (d) no aplica y se cae a las señales de git (conservador).
#
# Una rama NUNCA pusheada y sin equivalencia → se CONSERVA. La regla (b) NUNCA borra a ciegas: si la rama
# tiene commits propios no equivalentes a la base (git cherry marca '+'), se CONSERVA aunque su remota ya
# no exista — la ausencia de la remota no prueba integración, y el `branch -D` es irreversible (FMEA A5/MEDIO-3).
#
# TRES ESTADOS, no dos (A-3): cuando git cherry marca '+' (contenido no patch-equivalente) y (d) NO pudo
# consultarse (gh/glab ausentes, host no reconocido, sin red), el veredicto correcto NO es "vivo con
# certeza": es INDETERMINADO — pudo ser un squash multi-commit YA mergeado que (d) habría cazado. La
# ACCIÓN es la misma en ambos casos (conservar: `bz_es_zombie` devuelve 1, nunca se borra a ciegas), pero
# el REPORTE debe distinguirlos (`$BZ_RAZON`) para no afirmar "trabajo sin integrar" cuando lo honesto es
# "no se pudo comprobar". Mentir aquí fue lo que contaminó la bitácora con pendientes falsos (A-4).

# bz_resolver_base ROOT → imprime la base de integración.
# La base es configurable (CLAUDE_INTEGRACION_BASE): en el flujo mini-develop NO es develop sino TU rama
# personal (convención `Develop<Usuario>`, p. ej. `DevelopAna`). Precedencia sin override:
#   1) HEAD parado en una mini-develop `Develop<Usuario>` → esa (es la base viva del dev).
#   2) una rama local `Develop<Usuario>` existe → esa (el día a día del dev vive en su mini-develop;
#      sus ramitas se integran a la mini, NO directo a develop — así el barrido las ve integradas).
#   3) fallback clásico: develop, o la rama por defecto del remoto, o main.
# Sin `Develop*` local (repo de flujo develop puro, p. ej. un solo-dev sobre develop) → cae a (3), intacto.
# M-2 (auditoría 2026-09-11): con VARIAS `Develop*` locales y HEAD en ninguna, (2) tomaba la primera por
# orden alfabético (`head -1`) — base ARBITRARIA (podía ser la mini de un colega). Ahora: si hay >1 y HEAD
# no está en ninguna, NO SE ADIVINA — cae a (3). El caller que quiera el AVISO llama `bz_aviso_base ROOT`
# (función independiente, NO una variable global): `base="$(bz_resolver_base "$ROOT")"` es una
# sustitución de comando — bash la corre en un SUBSHELL — así que cualquier variable que la función
# fijara ahí adentro se perdería al volver; una función separada, invocada con su PROPIA sustitución de
# comando, no tiene ese problema porque su valor de retorno ES precisamente lo que imprime.
bz_resolver_base() {
  local ROOT="$1" base="${CLAUDE_INTEGRACION_BASE:-}" cur mini n_mini
  if [ -z "$base" ]; then
    # (1) HEAD en una mini-develop (Develop<Usuario>; case-sensitive, ≥1 char tras "Develop" → excluye
    #     el `develop` minúsculas y un `Develop` pelón).
    cur=$(git -C "$ROOT" symbolic-ref --short -q HEAD 2>/dev/null || true)
    case "$cur" in Develop?*) base="$cur" ;; esac
    # (2) preferir una mini-develop LOCAL si la hay — pero solo si hay UNA sola; con varias y HEAD en
    #     ninguna, adivinar es peor que caer a (3) (M-2).
    if [ -z "$base" ]; then
      n_mini=$(git -C "$ROOT" for-each-ref --format='%(refname:short)' 'refs/heads/Develop*' 2>/dev/null | wc -l | tr -d ' ')
      if [ "${n_mini:-0}" = 1 ]; then
        mini=$(git -C "$ROOT" for-each-ref --format='%(refname:short)' 'refs/heads/Develop*' 2>/dev/null)
        [ -n "$mini" ] && base="$mini"
      fi
    fi
    # (3) fallback: develop → rama por defecto del remoto → main.
    if [ -z "$base" ]; then
      base=develop
      git -C "$ROOT" rev-parse --verify -q refs/heads/develop >/dev/null 2>&1 \
        || base=$(git -C "$ROOT" symbolic-ref --short -q refs/remotes/origin/HEAD 2>/dev/null | sed 's#origin/##' || echo main)
    fi
  fi
  printf '%s' "$base"
}

# bz_aviso_base ROOT → imprime (por stdout) un aviso si hay AMBIGÜEDAD real en la base que
# `bz_resolver_base` no pudo resolver (M-2: varias `Develop*` locales y HEAD en ninguna) — vacío si no
# aplica. Recalcula de forma INDEPENDIENTE (no comparte estado con `bz_resolver_base`): así sobrevive a la
# forma más común de consumir la base (`base="$(bz_resolver_base "$ROOT")"`, que corre en un subshell).
bz_aviso_base() {
  local ROOT="$1" cur n_mini
  [ -n "${CLAUDE_INTEGRACION_BASE:-}" ] && return 0   # override explícito → sin ambigüedad que avisar
  cur=$(git -C "$ROOT" symbolic-ref --short -q HEAD 2>/dev/null || true)
  case "$cur" in Develop?*) return 0 ;; esac           # HEAD ya está en una mini → sin ambigüedad
  n_mini=$(git -C "$ROOT" for-each-ref --format='%(refname:short)' 'refs/heads/Develop*' 2>/dev/null | wc -l | tr -d ' ')
  if [ "${n_mini:-0}" -gt 1 ] 2>/dev/null; then
    printf 'hay %s mini-develop locales y HEAD no está en ninguna; no se adivina' "$n_mini"
  fi
}

# --- Señal (d): ¿el PR/MR de la rama se MERGEÓ en el host? (autoritativa para el flujo SQUASH) --------
# Se consulta 1× por proceso (memoizado por ROOT). FAIL-OPEN total: sin gh/glab, sin red, host no
# reconocido o error → cache vacío → (d) no aplica → se cae a las señales de git. TEST: exporta
# CLAUDE_BZ_PRCACHE=<archivo con líneas 'rama<TAB>sha'> para inyectar el mapa de PRs mergeados sin red.
# $_BZ_D_INTENTADO: 1 si de verdad se INTENTÓ consultar el host (binario disponible e invocado, o cache
# inyectada por test) — 0 si no se pudo ni intentar (binario ausente). $_BZ_D_APLICABLE: 1 si hay un
# remoto de RED configurado (scheme:// o user@host:) donde (d) PODRÍA en teoría aplicar — 0 si no hay
# remoto o es una ruta local (nunca hubo dónde mergear un PR/MR, así que (d) no aplica ni en teoría — no
# es "no se pudo consultar", es "no corresponde"). `bz_es_zombie` usa AMBAS para distinguir "consultamos y
# esta rama no aplica" / "no había host que consultar" (ambas → vivo con certeza) de "había host pero no
# se pudo consultar" (→ indeterminado, tercer estado).
_BZ_PRCACHE_FILE=""; _BZ_PRCACHE_ROOT=""; _BZ_D_INTENTADO=0; _BZ_D_APLICABLE=0
_bz_run() {  # _bz_run SEGUNDOS cmd... — con timeout si existe (que un host colgado no cuelgue la poda)
  local t="$1"; shift
  if command -v timeout >/dev/null 2>&1; then timeout "$t" "$@"; else "$@"; fi
}
_bz_intentar_gh() {  # $1=ROOT $2=proj — apéndice al cache si gh está disponible
  local ROOT="$1" proj="$2"
  command -v gh >/dev/null 2>&1 || return 0
  _BZ_D_INTENTADO=1
  _bz_run 15 gh -R "$proj" pr list --state merged --limit 300 \
    --json headRefName,headRefOid --jq '.[] | "\(.headRefName)\t\(.headRefOid)"' \
    >>"$_BZ_PRCACHE_FILE" 2>/dev/null
}
_bz_intentar_glab() {  # $1=ROOT $2=proj — apéndice al cache si glab está disponible
  local ROOT="$1" proj="$2"
  command -v glab >/dev/null 2>&1 || return 0
  _BZ_D_INTENTADO=1
  _bz_run 15 glab mr list -R "$proj" -M --per-page 300 -F json \
    --jq '.[] | "\(.source_branch)\t\(.sha)"' \
    >>"$_BZ_PRCACHE_FILE" 2>/dev/null
}
_bz_cargar_prcache() {  # puebla $_BZ_PRCACHE_FILE (líneas 'rama<TAB>sha') para ROOT, una sola vez
  local ROOT="$1" url proj host
  [ "$_BZ_PRCACHE_ROOT" = "$ROOT" ] && return 0
  _BZ_PRCACHE_ROOT="$ROOT"
  if [ -n "${CLAUDE_BZ_PRCACHE:-}" ]; then
    _BZ_PRCACHE_FILE="$CLAUDE_BZ_PRCACHE"; _BZ_D_INTENTADO=1; _BZ_D_APLICABLE=1; return 0
  fi
  _BZ_PRCACHE_FILE="$(mktemp 2>/dev/null)" || { _BZ_PRCACHE_FILE=""; return 0; }
  # el temp es NUESTRO (no el inyectado) → limpiarlo al salir del proceso; ningún caller usa trap EXIT
  _BZ_PRCACHE_OWNED="$_BZ_PRCACHE_FILE"; trap 'rm -f "$_BZ_PRCACHE_OWNED" 2>/dev/null' EXIT
  url="$(git -C "$ROOT" remote get-url origin 2>/dev/null || true)"
  # ¿Tiene forma de remoto de RED (scheme:// o user@host:)? Una ruta local (bare de un fixture de prueba,
  # o un remoto sin origin) NUNCA tuvo dónde mergear un PR/MR → (d) no aplica NI EN TEORÍA (no es "no se
  # pudo consultar" — no corresponde). Evita además invocar gh/glab contra un path que no es un host real.
  case "$url" in
    *://*|*@*:*) : ;;
    *) return 0 ;;
  esac
  _BZ_D_APLICABLE=1
  # path del proyecto desde el remoto (owner/repo o group/subgrupo/proyecto) → -R, sin `cd` (un `cd`
  # dispararía un hook chpwd del shell que contaminaría el cache; -R es además más robusto).
  proj="$(printf '%s' "$url" | sed -E 's#^[a-z]+://[^/]+/##; s#^[^@]+@[^:]+:##; s#\.git$##')"
  [ -n "$proj" ] || return 0
  # M-5 (auditoría 2026-09-11): clasificar por el HOST real de la URL, no por una subcadena de la URL
  # ENTERA — `git@gitlab.com:grupo/github-tools.git` matcheaba *github* por el PATH del proyecto (CLI
  # equivocado). Con host self-hosted/desconocido: probar lo que haya instalado en vez de rendirse.
  host="$(printf '%s' "$url" | sed -E 's#^[a-z]+://##; s#^[^@]+@##; s#[:/].*$##')"
  case "$host" in
    github.com|*.github.com) _bz_intentar_gh "$ROOT" "$proj" ;;
    gitlab.com|*.gitlab.com) _bz_intentar_glab "$ROOT" "$proj" ;;
    *) _bz_intentar_gh "$ROOT" "$proj"; _bz_intentar_glab "$ROOT" "$proj" ;;
  esac
  return 0
}
# bz_pr_mergeado ROOT BR → 0 si el PR/MR de BR se mergeó y su head CONTIENE el tip actual de BR (todos sus
# commits integrados). Si BR trae commits MÁS ALLÁ del head mergeado (trabajo post-merge) → 1 (conservar).
bz_pr_mergeado() {
  local ROOT="$1" br="$2" oid
  _bz_cargar_prcache "$ROOT"
  [ -n "$_BZ_PRCACHE_FILE" ] && [ -s "$_BZ_PRCACHE_FILE" ] || return 1
  oid="$(awk -F'\t' -v b="$br" '$1==b{print $2; exit}' "$_BZ_PRCACHE_FILE" 2>/dev/null)"
  [ -n "$oid" ] || return 1
  git -C "$ROOT" merge-base --is-ancestor "$br" "$oid" 2>/dev/null   # tip de br ⊆ head mergeado → integrada
}

# bz_es_zombie ROOT BR BASE → 0 si BR ya está integrada a BASE (zombie), 1 si conservar. Deja el MOTIVO en
# $BZ_RAZON: a=ancestro · e=squash con "Rama:" en el log · d=PR/MR mergeado · c=cherry patch-equivalente ·
# b=remota borrada sin commits propios · vivo=commits propios confirmados (con o sin remota) ·
# indeterminado=había '+' en git cherry pero NO se pudo consultar el host para descartar un squash-multi
# ya mergeado (A-3: la acción es conservar igual, pero el reporte no debe afirmar "vivo" con certeza).
BZ_RAZON=""
bz_es_zombie() {
  local ROOT="$1" br="$2" base="$3" up cherry
  BZ_RAZON=""
  git -C "$ROOT" merge-base --is-ancestor "$br" "$base" 2>/dev/null && { BZ_RAZON=a; return 0; }  # (a)
  # (e) señal LOCAL determinista y offline: el mensaje del squash trae "Rama: <br>" (convención de equipo).
  if git -C "$ROOT" log --format='%B' "$base" -- 2>/dev/null | grep -qxF "Rama: $br"; then
    BZ_RAZON=e; return 0
  fi
  bz_pr_mergeado "$ROOT" "$br" && { BZ_RAZON=d; return 0; }   # (d) PR/MR mergeado (host, autoritativo)
  # (c) squash/cherry a la base: los commits de la rama ya están en base por EQUIVALENCIA de parche
  # (git cherry los marca '-'; NINGUNO '+').
  cherry=$(git -C "$ROOT" cherry "$base" "$br" 2>/dev/null)
  if [ -n "$cherry" ] && ! printf '%s\n' "$cherry" | grep -q '^+'; then BZ_RAZON=c; return 0; fi
  # (b) remota borrada — NUNCA a ciegas. La ausencia de la remota NO prueba que la rama esté integrada
  # (pudo borrarse por rename/limpieza manual, o traer commits VIVOS post-merge sin pushear). Si la rama
  # tiene commits PROPIOS no equivalentes a la base (git cherry marcó algún '+'), se CONSERVA aunque su
  # remota ya no exista: el `branch -D` de los barredores es irreversible y borraría ese trabajo. Antes
  # (b) declaraba zombie sin re-chequear commits únicos → PÉRDIDA DE DATOS (FMEA A5/MEDIO-3). El header
  # promete "conserva ante duda": aquí se hace cumplir — solo una rama SIN trabajo único cae a (b).
  if printf '%s\n' "$cherry" | grep -q '^+'; then
    # A-3: '+' pudo ser un squash-multi YA mergeado que (d) habría cazado. Si (d) SÍ se pudo consultar
    # (host reachable, este branch simplemente no apareció como mergeado) → confianza real: vivo. Si NO
    # HAY host que consultar (nunca hubo remoto de red, p. ej. un fixture con origin local) → también vivo
    # con certeza (no es indeterminado; no es "no se pudo", es "no corresponde"). Solo cuando HABÍA un host
    # de red configurado y NO se pudo consultar (gh/glab ausentes, error) → no lo sabemos: indeterminado.
    if [ "$_BZ_D_INTENTADO" = 1 ] || [ "$_BZ_D_APLICABLE" != 1 ]; then BZ_RAZON=vivo; else BZ_RAZON=indeterminado; fi
    return 1
  fi
  up=$(git -C "$ROOT" rev-parse --abbrev-ref "$br@{upstream}" 2>/dev/null) || { BZ_RAZON=vivo; return 1; }  # nunca pusheada → conservar
  if git -C "$ROOT" ls-remote --exit-code --heads "${up%%/*}" "${up#*/}" >/dev/null 2>&1; then
    BZ_RAZON=vivo; return 1   # remota existe, sin commits propios pero tampoco huella de integración → conservar
  else
    BZ_RAZON=b; return 0      # (b) remota borrada Y sin commits únicos → zombie
  fi
}

# bz_protegida BR BASE [ACTUAL] [WT_RAMAS] → 0 si BR NUNCA debe tocarse destructivamente, pase lo que
# pase (la base de integración, la rama actual, develop/main, cualquier mini-develop Develop* o guardada
# a propósito keep/*, o checked-out en CUALQUIER worktree — WT_RAMAS son sus nombres, uno por línea).
# 1 si no. Deja la RAZÓN en $BZ_PROT_RAZON: base_actual | convencion | worktree.
#
# C-2 (auditoría 2026-09-11): antes esta protección SOLO vivía en limpiar-ramas.sh; limpiar-worktrees.sh
# no tenía equivalente y borró el worktree de una mini-develop con trabajo sin commitear y marcó `keep/*`
# como zombie. Ahora es UNA sola definición que consumen los DOS barredores — igual que bz_es_zombie.
BZ_PROT_RAZON=""
bz_protegida() {
  local br="$1" base="$2" actual="${3:-}" wt_ramas="${4:-}"
  BZ_PROT_RAZON=""
  if [ "$br" = "$base" ] || { [ -n "$actual" ] && [ "$br" = "$actual" ]; }; then
    BZ_PROT_RAZON=base_actual; return 0
  fi
  case "$br" in
    develop|main|Develop*|keep/*) BZ_PROT_RAZON=convencion; return 0 ;;
  esac
  if [ -n "$wt_ramas" ] && printf '%s\n' "$wt_ramas" | grep -qxF "$br"; then
    BZ_PROT_RAZON=worktree; return 0
  fi
  return 1
}
