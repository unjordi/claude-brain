#!/usr/bin/env bash
# reubicar-master.sh — GENERA (y verifica) el handoff ejecutable de una mudanza de brain-master.
#
# Es el ÚNICO ejecutable del skill `reubicar-master`. El SKILL.md documenta el POR QUÉ y las decisiones
# del humano; este archivo es el CÓMO, y es la fuente única del preludio y de los pasos destructivos.
#
#   USO   reubicar-master.sh --id <uuid> --dst-repo <ruta> --master-name <nombre> [opciones]
#         reubicar-master.sh verificar <handoff.sh>
#
# Qué hace, en orden — todo en UN proceso, que es justo lo que lo vuelve fiable:
#   1) valida los parámetros                    4) genera el handoff a $DRIVE/handoff-<id>.sh
#   2) escribe el PRELUDIO (tmp + rename)       5) lo VERIFICA por CONTENIDO y falla CERRADO
#   3) lo SOURCEA (preflight + derivadas)       6) imprime los tres comandos para correrlo
#
# NADA de lo que hace este script es destructivo: escribe dos archivos (el preludio y el handoff) y no
# toca el transcript, ni masters.json, ni el repo destino. Los pasos destructivos viven EN el handoff,
# que corre otra sesión con la objetivo cerrada (invariante «nadie se auto-mueve», §6 del SKILL).
#
# POR QUÉ ES UN SCRIPT Y NO UN BLOQUE DE MARKDOWN (2026-09-10, hallazgo de la primera mudanza real):
# cuando el generador vivía como bloque en el SKILL.md, el operador tenía que extraerlo, poblar los
# parámetros y SOURCEAR el preludio en la MISMA shell, en ese orden — dependencias invisibles que el
# generador no verificaba. Un `source` dentro de un pipe (que no persiste) produjo un handoff con el
# preludio SIN embeber: 473 líneas, `bash -n` impecable, certificado como «handoff OK», y muerto en
# `DST_CWD: unbound variable` al primer arranque. En un proceso el orden no se puede equivocar, y el
# candado nuevo (`_verificar_handoff`) exige el preludio EMBEBIDO byte a byte.
set -euo pipefail
umask 077

_uso(){ cat <<'USO'
reubicar-master.sh — genera el handoff ejecutable de una mudanza de brain-master.

  GENERAR    reubicar-master.sh --id <uuid> --dst-repo <ruta> --master-name <nombre> [opciones]
  VERIFICAR  reubicar-master.sh verificar <handoff.sh>
  PARIDAD    reubicar-master.sh paridad --dst-repo <ruta> [--t1 <mem>]... [--t2-local <arch>]...
             [--bundle <tgz>] [--dst-protegido <subdir>] [--src-repo <ruta>]
             G-PARITY: que lo del master este PRESENTE Y CORRECTO en el destino. T4 bifurca por la marca
             `.claude/repo-compartido` (un repo PERSONAL no lleva guards por-repo, por norma dura), y con
             `--bundle` distingue "falta" de "esta en el bundle, lo deposita S5".
  CLASIFICAR reubicar-master.sh clasificar --src-repo <ruta> --dst-repo <ruta>
             La EVIDENCIA para la Decisión #2 (frontera T1↔T3): por cada memoria del origen, su propia
             `description`, si ya está en el destino, si está trackeada, cuándo se tocó, y si es `.local`
             (canal sensible). NO propone el corte: eso lo decide el humano.

Obligatorios (§7 del SKILL: se preguntan al humano en RUNTIME, no se asumen):
  --id <uuid>              el <id> VIGENTE de la sesión (Decisión #1 / G-ID: masters.json tiene
                           duplicados por nombre ⇒ el nombre NO identifica).
  --dst-repo <ruta>        la casa REAL del master (Decisión #0). Sin default: un default apunta al
                           repo de otra máquina y miente.
  --master-name <nombre>   el nombre ACTUAL en masters.json.

Opcionales:
  --nombre-nuevo <nombre>  renombre (Decisión #0b). DEBE terminar en '-master' o el auto-export se apaga.
  --src-repo <ruta>        de dónde sale (default: $HOME/code/plantilladotnet, el caso típico de un cwd
                           que ancló al master por accidente).
  --drive <ruta>           carpeta 'claude-sessions' del Drive sincronizado. Default: $CLAUDE_SESSIONS_DRIVE,
                           que en un shell PLANO está VACÍA (vive en el bloque env de ~/.claude/settings.json).
  --dst-protegido <subdir> subdir del destino que JAMÁS se muta (ej. 'brain' en cortex). Vacío = ninguno.
  --t1 <memoria>           memoria T1 a co-ubicar en el destino (Decisión #2). REPETIBLE — es la única
                           forma correcta de pasar nombres con espacios.
  --t2-local <archivo>     archivo T2 gitignored bajo .claude/memory/. REPETIBLE. SUMA al default
                           (conocimiento-propio.local.md autorizaciones-vigentes.local.md
                           hilo-mental-actual.md hilo-mental-actual-overflow.md) — no lo reemplaza.
  --t2-local-solo <archivo> como --t2-local, pero la PRIMERA vez que se usa VACÍA el default: para
                           cuando de verdad quieres SOLO los archivos que listes, no el default + los tuyos.
  --t2-root <archivo>      T2 en la raíz del repo (default: CLAUDE.local.md). Puede no existir.
  --salida <ruta>          dónde escribir el handoff (default: <drive>/handoff-<id>.sh).
  --dry                    tras generar, corre REUBICAR_MODO=dry (no muta nada). Recomendado.
  -h | --help              esto.

Cada opción tiene su variable de entorno equivalente (ID, DST_REPO, MASTER_NAME, MASTER_NAME_NUEVO,
SRC_REPO, DRIVE, DST_PROTEGIDO, T2_ROOT, REUBICAR_SALIDA); el flag gana. Los ARRAYS (--t1/--t2-local)
solo por flag: un array no se exporta al entorno, y una cadena separada por espacios partiría un nombre
con espacio en dos.

Después de generar, el orden NO es negociable:
  REUBICAR_MODO=dry bash <handoff>                                    # primero, SIEMPRE
  REUBICAR_LIVENESS_OK=1 REUBICAR_QUIESCE_OK=1 bash <handoff>         # los pasos destructivos
  <QA funcional del humano — es el único sello de LISTO>
  REUBICAR_MODO=s7 REUBICAR_QUIESCE_OK=1 bash <handoff>               # re-verificar tras el QA
USO
}

# ══════════════════════════════════════════════════════════════════════════════════════════════════
# EL CANDADO · una sola definición, la usan la generación y el subcomando `verificar`
# ══════════════════════════════════════════════════════════════════════════════════════════════════
# Tres capas, y cada una dice HONESTAMENTE qué prueba:
#   (1) SÍMBOLOS DEL PRELUDIO — que el preludio quedó EMBEBIDO. Es la capa que faltaba: sin ella el
#       candado certificaba un handoff sin helpers ni derivadas, que muere en la primera variable.
#       Cuando el preludio está a mano se exige además presencia TEXTUAL (byte a byte), que cierra la
#       clase completa: cualquier símbolo que el preludio gane en el futuro viaja solo.
#   (2) MARCADORES DE PASO en línea EJECUTABLE — detecta que una edición futura borre un paso del
#       generador, o lo degrade a comentario. `bash -n` no lo caza: un guion al que le falta un paso es
#       sintácticamente perfecto.
#   (3) PROHIBICIONES + sintaxis + LF.
# Lo que NINGUNA capa prueba es que el guion FUNCIONE — eso lo prueban `_postcondiciones` cuando el
# guion se EJECUTA y el `REUBICAR_MODO=dry` previo. Un candado que se vendiera como prueba de
# corrección sería el mismo modo de falla que este skill existe para evitar: certificar sin verificar.

# Los símbolos que el PRELUDIO aporta y de los que el handoff DEPENDE. Se verifica contra el preludio
# real cuando está disponible (una lista que drifte del preludio se detecta, no se cree).
_SIMBOLOS_PRELUDIO='_abort() _mtime() _size() _perm() _fecha() _ahora() _real() _cwdform() _cwds()
_cwds_n() _ultimo_par() _slug() _cap() _capfalta= SO= NOMBRE_FINAL= MJ= BIN= SRC= DST_POSIX=
SRC_POSIX= DST= DST_CWD= SRC_CWD= HOME_CWD= OLD_SLUG= NEW_SLUG= PROJ= JSONL= NEW_JSONL= GLOBAL_MEM=
ST= TARGET='

# Los parámetros que la CABECERA hornea. Sin ellos el handoff no sabe qué mover.
_SIMBOLOS_CABECERA='LIB_SHA_HORNEADO= ID= MASTER_NAME= MASTER_NAME_NUEVO= SRC_REPO= DST_REPO= DRIVE=
DST_PROTEGIDO= T2_ROOT= T2_LOCAL=( MEMORIAS_T1=('

# Un paso obligatorio por marcador. Si un paso se retira A PROPÓSITO, su marcador sale de aquí en el
# MISMO commit: el candado y el generador se mantienen juntos o dejan de significar algo.
_MARCADORES='G-SELF-MOVE G-LIVENESS G-QUIESCE G-SIDECAR --git-branch _reancla S4-2c UPSERT MJ.lock
_postcondiciones REUBICAR_MODO REUBICAR_LIVENESS_OK REUBICAR_QUIESCE_OK REUBICAR_QUIESCE_ESTRICTO
ALIAS_ANTES DESHACER fail-closed'
_MARCADOR_FRASE='PUNTO DE NO RETORNO'

# Un símbolo se busca como DEFINICIÓN o ASIGNACIÓN en frontera de palabra, NO como substring: 'ST='
# casa dentro de 'DST=' y un preludio a MEDIAS pasaría el chequeo por accidente. La frontera admite
# inicio de línea, espacio, ';', ')', '&', '|' y '{' — porque en el preludio hay asignaciones dentro de
# ramas de `case` ("Darwin)  SO=mac ;;") que un ancla a inicio-de-línea rechazaría en falso.
_pat_simbolo(){ printf '(^|[[:space:];)&|{])%s' "$(printf '%s' "$1" | sed 's/[()]/\\&/g')"; }

_fallo_candado(){
  printf '\n❌ handoff RECHAZADO: %s\n' "$1" >&2
  shift
  [ "$#" -eq 0 ] || printf '   %s\n' "$@" >&2
  cat >&2 <<'AYUDA'

   NO parches el handoff a mano: se RE-GENERA, no se edita. En orden:
     1) ¿editaste reubicar-master.sh en esta sesión?
        git -C <tu clon de cortex> diff -- brain/skills/reubicar-master/reubicar-master.sh
     2) si no lo editaste, tu copia está desincronizada de cortex/develop:
        git -C <clon> fetch origin && git -C <clon> diff origin/develop -- brain/skills/reubicar-master/
     3) si el paso se retiró a propósito, quita su marcador de la lista del candado en el MISMO commit.
   Nada se mutó: este candado corre al GENERAR, mucho antes de cualquier paso destructivo.
AYUDA
  exit 1
}

# _verificar_handoff <handoff> [preludio]
_verificar_handoff(){
  local H="$1" P="${2:-}" nocom faltan s m
  [ -f "$H" ] || _fallo_candado "no existe el archivo: $H"

  # ── (3a) LF. Un \r invisible rompe el parseo ANTES de que ninguna línea pueda defenderse, y el Drive
  #         sincroniza con Windows. Se normaliza al generar; al VERIFICAR se exige, no se arregla en
  #         silencio (un handoff que llegó con CR viajó por un camino que hay que conocer).
  if LC_ALL=C grep -q "$(printf '\r')" "$H"; then
    _fallo_candado "el handoff trae CR (CRLF)" \
      "normalízalo: LC_ALL=C tr -d '\\r' < \"$H\" > \"$H.lf\" && mv \"$H.lf\" \"$H\""
  fi

  # ── (1) el PRELUDIO quedó embebido ──────────────────────────────────────────────────────────────
  if [ -n "$P" ] && [ -f "$P" ]; then
    # presencia TEXTUAL: el generador lo concatena con `cat`, así que debe estar byte a byte. Cierra la
    # CLASE: no hay que acordarse de agregar a ninguna lista lo que el preludio gane mañana.
    node -e '
      const fs = require("fs");
      const nl = s => s.replace(/\r/g, "");
      const h = nl(fs.readFileSync(process.argv[1], "utf8"));
      const p = nl(fs.readFileSync(process.argv[2], "utf8"));
      process.exit(h.indexOf(p) >= 0 ? 0 : 1);
    ' "$H" "$P" || _fallo_candado \
      "el PRELUDIO no está embebido TEXTUALMENTE en el handoff" \
      "preludio: $P" \
      "Es el fallo del 2026-09-10: el 'cat' de concatenación recibió una ruta vacía y el handoff salió" \
      "sin helpers ni derivadas — sintaxis perfecta y muerto en 'DST_CWD: unbound variable'."
    # y la lista de símbolos se verifica contra el preludio REAL: si un símbolo de la lista ya no existe
    # en el preludio, la lista driftó y hay que arreglarla — no seguir creyéndole.
    faltan=""
    for s in $_SIMBOLOS_PRELUDIO; do
      grep -qE -- "$(_pat_simbolo "$s")" "$P" || faltan="$faltan $s"
    done
    [ -z "$faltan" ] && [ "$(grep -c 'CLAUDE_SESSIONS_DRIVE' "$P")" -ge 1 ] || _fallo_candado \
      "la lista _SIMBOLOS_PRELUDIO del candado driftó del PRELUDIO real" \
      "no están en el preludio:$faltan" \
      "Arregla la lista en reubicar-master.sh (misma tanda que el cambio del preludio)."
  fi
  faltan=""
  for s in $_SIMBOLOS_PRELUDIO; do
    grep -qE -- "$(_pat_simbolo "$s")" "$H" || faltan="$faltan $s"
  done
  [ -z "$faltan" ] || _fallo_candado \
    "el handoff no define lo que el PRELUDIO aporta ⇒ moriría en la primera variable" \
    "símbolos ausentes:$faltan" \
    "Causa típica: el preludio no se embebió (ver el hallazgo del 2026-09-10 en la cabecera del script)."

  # ── (2) parámetros horneados + marcadores de paso en línea EJECUTABLE ───────────────────────────
  faltan=""
  for s in $_SIMBOLOS_CABECERA; do
    grep -qE -- "$(_pat_simbolo "$s")" "$H" || faltan="$faltan $s"
  done
  [ -z "$faltan" ] || _fallo_candado \
    "la cabecera no horneó todos los parámetros" "ausentes:$faltan"

  # Las líneas no comentadas se materializan UNA vez a un archivo y se grepean ahí: `grep -v … | grep -q`
  # cierra el pipe al primer match, el `grep -v` de arriba muere con SIGPIPE y bajo `pipefail` el candado
  # fallaría EN FALSO sobre un handoff correcto (medido).
  nocom="$(mktemp)"
  grep -vE '^[[:space:]]*#' "$H" > "$nocom" || true
  faltan=""
  for m in $_MARCADORES; do
    grep -qF -- "$m" "$nocom" || faltan="$faltan $m"
  done
  grep -qF -- "$_MARCADOR_FRASE" "$nocom" || faltan="$faltan '$_MARCADOR_FRASE'"
  if [ -n "$faltan" ]; then
    rm -f "$nocom"
    _fallo_candado "faltan pasos obligatorios en línea EJECUTABLE" "marcadores ausentes:$faltan" \
      "(mencionarlos en un comentario NO satisface el candado: era el hueco más barato de abrir sin querer)"
  fi
  rm -f "$nocom"

  # ── (3b) prohibiciones ──────────────────────────────────────────────────────────────────────────
  ! grep -qE '(^|[^-])ln -s' "$H" || _fallo_candado \
    "crea un symlink — S5 lo PROHÍBE (decisión textual del humano: «QUIERO QUE ESTO QUEDE SIN SIMLINKS. PUNTO»)"
  ! grep -qF 'ver SKILL §' "$H" || _fallo_candado \
    "contiene un stub 'ver SKILL §' en vez del paso" \
    "Un handoff que dice «(ver SKILL §4)» obliga a reconstruir los pasos destructivos a mano — justo lo" \
    "que el skill existe para evitar. Si un paso no se puede escribir, va su echo + exit 1, no un comentario."
  if grep -qE 'stat -c [^|]*\)' "$H" && ! grep -qF '_mtime' "$H"; then
    _fallo_candado "usa 'stat -c' sin el helper portable (_mtime/_size/_perm): rompe en BSD/macOS"
  fi

  # ── (3c) sintaxis ───────────────────────────────────────────────────────────────────────────────
  bash -n "$H" || _fallo_candado "no pasa 'bash -n'"

  printf '✅ handoff verificado: preludio %s + %s pasos obligatorios + sintaxis + LF\n' \
    "$( [ -n "$P" ] && [ -f "$P" ] && echo 'EMBEBIDO (textual)' || echo 'presente (por símbolos: sin el preludio a mano NO se pudo comparar textualmente)' )" \
    "$(printf '%s\n' $_MARCADORES | grep -c . || true)"
}

# ══════════════════════════════════════════════════════════════════════════════════════════════════
# SUBCOMANDO `paridad` — G-PARITY EJECUTABLE (era otro bloque de markdown que el operador corría a mano)
# ══════════════════════════════════════════════════════════════════════════════════════════════════
# Mide lo que el invariante NO-LOBOTOMÍA enuncia: que lo clasificado del-master esté PRESENTE Y CORRECTO
# EN EL DESTINO. No mide `SRC == DST`: para la clase que §1.0.1 declara normal —el cerebro del master
# nunca vivió en el origen— un `diff` contra un archivo ausente falla siempre y el gate bloquearía un
# destino COMPLETO.
#
# Dos correcciones que salieron de CORRERLO de verdad el 2026-09-10, y que la versión en markdown traía:
#
#  (a) T4 NO puede exigir `.claude/settings.json` en TODO destino. La norma dura del cerebro dice
#      «repo PERSONAL: memoria/skills SÍ, guards por-repo NUNCA» (sus guards salen del install GLOBAL +
#      la cláusula de dedupe; una copia por-repo solo puede driftar). `cortex` no trae la marca
#      `.claude/repo-compartido` ⇒ es PERSONAL y correctamente NO tiene `settings.json` — y el gate lo
#      declaraba «lobotomía del cableado», empujando a crear justo la copia que la norma prohíbe. Dos
#      piezas correctas por separado que se contradecían juntas. Ahora BIFURCA por la marca: la exige en
#      COMPARTIDO (donde el brain por-repo es el CORREO de quien clona sin brain global) y en PERSONAL
#      verifica que el install GLOBAL exista, que es de donde salen los candados.
#
#  (b) Las filas de T2 solo son evaluables DESPUÉS de S5, que es quien deposita el bundle. Corrido antes
#      —lo natural, porque el flujo lo pone tras S1/S2— reportaba «FALTA EN EL DESTINO» sobre archivos que
#      estaban en el bundle esperando su turno: lee como fallo cuando es el estado correcto. Con
#      `--bundle` distingue «falta» de «está en el bundle, lo deposita S5».
if [ "${1:-}" = paridad ]; then
  shift
  _p_src="$HOME/code/plantilladotnet"; _p_dst=""; _p_prot=""; _p_bundle=""
  _p_t1=(); _p_t2=(); _p_t2root="CLAUDE.local.md"; _p_t2_dado=0
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --src-repo)      _p_src="${2:-}"; shift 2 ;;
      --dst-repo)      _p_dst="${2:-}"; shift 2 ;;
      --dst-protegido) _p_prot="${2:-}"; shift 2 ;;
      --bundle)        _p_bundle="${2:-}"; shift 2 ;;
      --t2-root)       _p_t2root="${2:-}"; shift 2 ;;
      --t1)            _p_t1[${#_p_t1[@]}]="${2:-}"; shift 2 ;;
      --t2-local)
        [ "$_p_t2_dado" -eq 1 ] || { _p_t2=(); _p_t2_dado=1; }
        _p_t2[${#_p_t2[@]}]="${2:-}"; shift 2 ;;
      -h|--help)       _uso; exit 0 ;;
      *) printf 'paridad: opción desconocida: %s\n' "$1" >&2; exit 2 ;;
    esac
  done
  [ -n "$_p_dst" ] || { printf 'paridad: falta --dst-repo\n' >&2; exit 2; }
  # MISMO default que el generador (T2_LOCAL): eran dos listas de lo mismo y al entrar el hilo al default
  # real esta se quedó atrás ⇒ G-PARITY no medía el artefacto que la mudanza acababa de empezar a mover.
  [ "$_p_t2_dado" -eq 1 ] || _p_t2=(conocimiento-propio.local.md autorizaciones-vigentes.local.md hilo-mental-actual.md hilo-mental-actual-overflow.md)
  _p_srcm="$_p_src/.claude/memory"; _p_dstm="$_p_dst/.claude/memory"
  _p_fail=0
  _p_size(){ stat -c %s "$1" 2>/dev/null || stat -f %z "$1" 2>/dev/null || echo '?'; }

  # ¿el archivo viaja en el bundle de S2? Se lista UNA vez: un `tar -tz` por archivo serían N pasadas.
  _p_enbundle=""
  [ -n "$_p_bundle" ] && [ -f "$_p_bundle" ] && _p_enbundle="$(tar -tzf "$_p_bundle" 2>/dev/null | sed 's#^\./##')"
  _p_en_bundle(){ [ -n "$_p_enbundle" ] && printf '%s\n' "$_p_enbundle" | grep -qxF -- "$1"; }

  # El HILO es del (repo x stream), no del master: que DIFIERA del destino es lo normal y S5 lo CO-UBICA
  # al lado (hilo-mental-actual.<master>.md) en vez de pisar o abortar. G-PARITY mide eso: presencia del
  # hilo del master en el destino, con su nombre propio O co-ubicado. Medir 'identico' aqui reportaria
  # ROTA en el 100% de las mudanzas normales.
  _p_es_hilo(){ case "${1##*/}" in hilo-mental-*) return 0 ;; *) return 1 ;; esac; }
  # Busca un hilo CO-UBICADO por S5 (hilo-mental-actual.<master>.md) sin necesitar saber el nombre del
  # master: lo resuelve por glob. EXCLUYE el `.andamio.md`, que casa el mismo patron y NO es un hilo
  # co-ubicado (es el sidecar mecanico que regenera el checkpoint, otra cosa entera).
  _p_co_existe(){
    _b="${1%.md}"
    for _g in "$_p_dstm/$_b".*.md; do
      [ -e "$_g" ] || continue
      case "${_g##*/}" in *.andamio.md) continue ;; esac
      printf '%s' "${_g##*/}"; return 0
    done
    return 1
  }

  # _p_fila <ruta-origen> <ruta-destino> <etiqueta> <es-t2:0|1>
  _p_fila(){
    if _p_es_hilo "$3"; then
      _p_conom="$(_p_co_existe "$3" || true)"
      if [ -n "$_p_conom" ]; then
        printf '  ok    %s (CO-UBICADO como %s; el destino conserva el suyo, el 1er checkpoint fusiona)\n' "$3" "$_p_conom"
        return 0
      fi
    fi
    if   [ -e "$1" ] && [ -e "$2" ]; then
      if diff -q "$1" "$2" >/dev/null 2>&1; then printf '  ok    %s (idéntica en ambos)\n' "$3"
      elif _p_es_hilo "$3"; then
        printf '  ok    %s (existe en ambos y DIFIERE — es lo ESPERADO en un hilo: cada repo tiene el suyo)\n' "$3"
      else printf '  ROTA  %s — existe en ambos y DIFIERE (%s vs %s bytes) => reconciliacion HUMANA, no se pisa\n' \
             "$3" "$(_p_size "$1")" "$(_p_size "$2")"; _p_fail=1; fi
    elif [ -e "$2" ]; then printf '  ok    %s (no venia del origen, ya esta en el destino)\n' "$3"
    elif [ -e "$1" ]; then
      if [ "$4" = 1 ] && _p_en_bundle "$3"; then
        printf '  pend  %s — en el bundle de S2; lo deposita S5 (no es un fallo AUN)\n' "$3"
      else
        printf '  FALTA %s en el destino\n' "$3"; _p_fail=1
      fi
    else printf '  ambos %s — no esta en origen ni en destino: bien clasificada? (Decision #2)\n' "$3"; fi
  }

  # La RAMA del destino importa y el skill no lo decia: T1 vive en la ramita de S1, asi que medir con el
  # destino parado en otra rama reporta un FALTA que es el arbol rotando, no una perdida. Se declara.
  _p_rama="$(git -C "$_p_dst" branch --show-current 2>/dev/null || echo '(sin git)')"
  printf '%s\n' "-- G-PARITY · presente y correcto EN EL DESTINO (no 'igual al origen')"
  printf '%s\n' "   destino: $_p_dst  ·  rama: ${_p_rama:-(detached)}"
  case "$_p_rama" in
    docs/reubicar-*) : ;;
    *) printf '%s\n' "   aviso: el destino NO esta en la ramita de S1 (docs/reubicar-*). Si T1 sale FALTA, revisa" \
              "          primero la rama: el working tree ROTA y las copias de S1 viven en esa ramita." ;;
  esac
  for m in ${_p_t1[@]+"${_p_t1[@]}"}; do _p_fila "$_p_srcm/$m" "$_p_dstm/$m" "$m" 0; done
  for m in ${_p_t2[@]+"${_p_t2[@]}"}; do _p_fila "$_p_srcm/$m" "$_p_dstm/$m" "$m" 1; done
  _p_fila "$_p_src/$_p_t2root" "$_p_dst/$_p_t2root" "$_p_t2root" 1

  # ── T4 · CABLEADO. BIFURCA por la marca `.claude/repo-compartido` (norma dura del cerebro) ──────
  if [ -e "$_p_dst/.claude/repo-compartido" ]; then
    if [ -f "$_p_dst/.claude/settings.json" ]; then
      printf '  ok    T4: destino COMPARTIDO y trae su .claude/settings.json (el CORREO de quien clona sin brain global)\n'
    else
      printf '  FALTA T4: el destino se declara COMPARTIDO (.claude/repo-compartido) y NO trae .claude/settings.json\n'
      printf '            => un colega que clone quedaria SIN los guards creyendo que los tiene. Propagalo con sincronizar-cerebro.sh\n'
      _p_fail=1
    fi
  else
    printf '  ok    T4: destino PERSONAL (sin marca repo-compartido) => por norma NO lleva guards por-repo;\n'
    printf '            sus candados salen del install GLOBAL, y exigir settings.json aqui crearia el drift que la norma prohibe.\n'
    if [ -f "$HOME/.claude/settings.json" ]; then
      printf '  ok    T4: y el install GLOBAL existe (%s hook(s) cableado(s))\n' \
        "$(jq '[.hooks // {} | .[] | .[]? | .hooks // [] | .[]] | length' "$HOME/.claude/settings.json" 2>/dev/null || echo '?')"
    else
      printf '  FALTA T4: no hay ~/.claude/settings.json => en un destino PERSONAL el master despertaria SIN candados.\n'
      printf '            => corre el bootstrap del cerebro en esta maquina.\n'; _p_fail=1
    fi
  fi
  [ -f "$_p_dst/.claude/settings.local.json" ] \
    && printf '  ok    T4: settings.local.json presente (el outputStyle propio del master)\n' \
    || printf '  aviso T4: sin settings.local.json => el master despertara SIN su outputStyle (per-maquina, gitignored: se re-crea a mano)\n'
  if [ -n "$_p_prot" ]; then
    [ -d "$_p_dst/$_p_prot" ] && printf '  ok    el subdir PROTEGIDO %s esta en su sitio\n' "$_p_prot" \
      || { printf '  FALTA el subdir protegido %s en %s (destino equivocado?)\n' "$_p_prot" "$_p_dst"; _p_fail=1; }
  fi
  printf '\n'
  if [ "$_p_fail" -eq 0 ]; then echo "OK G-PARITY en verde"; exit 0
  else echo "BLOQUEA G-PARITY hasta resolver lo marcado (las filas 'pend' NO cuentan: las cierra S5)"; exit 1; fi
fi

# ══════════════════════════════════════════════════════════════════════════════════════════════════
# SUBCOMANDO `clasificar` — la EVIDENCIA para la Decisión #2, no un veredicto
# ══════════════════════════════════════════════════════════════════════════════════════════════════
# Reemplaza al "comando de descubrimiento" que §7 #2 traía antes: un `grep -rilEv` de seis palabras de
# stack (`plantilladotnet|.NET|blazor|dapper|EF Core|webapi|migracion-ef`) sobre las memorias del origen.
# MEDIDO el 2026-09-10 en la mudanza real: devolvió **44 de 43** archivos — incluido el propio MEMORY.md —
# porque "no menciona blazor" no es una señal de PROPIEDAD: casi ninguna memoria menciona el stack, ni las
# de otro proyecto ni las de trato personal. Un descubrimiento que no descarta nada no descubre nada, y
# empujaba al operador a inventar el corte de memoria (que es exactamente lo que pasó).
#
# Las señales que SÍ hablan de propiedad, y que este subcomando pone en una tabla:
#   · el `description:` que la memoria trae de sí misma (dice de QUÉ es, en sus palabras);
#   · si YA existe en el destino (si está, no hay nada que mover — §1.0.1);
#   · si está TRACKEADA en el origen (si se copia sin retirarla, quedan dos copias versionadas que driftan);
#   · cuándo la tocó el último commit (una memoria del master se toca cuando se trabaja el cerebro);
#   · el sufijo `.local.md`, que por convención del cerebro es el canal SENSIBLE (T2), no una opinión.
#
# NO propone el corte a propósito. La frontera T1↔T3 es la Decisión #2 del humano (§7), y una columna
# "veredicto" invitaría a aceptarla sin leer — el modo de falla que este subcomando existe para cerrar.
if [ "${1:-}" = clasificar ]; then
  shift
  _c_src="$HOME/code/plantilladotnet"; _c_dst=""
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --src-repo) _c_src="${2:-}"; shift 2 ;;
      --dst-repo) _c_dst="${2:-}"; shift 2 ;;
      -h|--help)  _uso; exit 0 ;;
      *) printf 'clasificar: opción desconocida: %s\n' "$1" >&2; exit 2 ;;
    esac
  done
  [ -n "$_c_dst" ] || { printf 'clasificar: falta --dst-repo (el destino se necesita para la columna "destino")\n' >&2; exit 2; }
  _c_srcm="$_c_src/.claude/memory"; _c_dstm="$_c_dst/.claude/memory"
  [ -d "$_c_srcm" ] || { printf 'clasificar: no hay %s\n' "$_c_srcm" >&2; exit 2; }

  _c_size(){ stat -c %s "$1" 2>/dev/null || stat -f %z "$1" 2>/dev/null || echo '?'; }

  # La descripción que la memoria da de SÍ MISMA: el `description:` del frontmatter (una línea o un
  # bloque `>-`/`|` con continuaciones indentadas), y si no lo trae, su primer encabezado o su primer `>`.
  _c_desc(){
    awk '
      NR==1 && $0=="---" { fm=1; next }
      fm && /^---[[:space:]]*$/ { fm=0; next }
      fm && /^description:/ {
        sub(/^description:[[:space:]]*/, ""); gsub(/^[>|]-?[[:space:]]*$/, "")
        d=$0; cont=1; next
      }
      fm && cont && /^[[:space:]]+/ { sub(/^[[:space:]]+/, " "); d=d $0; next }
      fm && cont { cont=0 }
      !fm && d=="" && /^# / { sub(/^# /, ""); d=$0 }
      !fm && d=="" && /^> / { sub(/^> /, ""); d=$0 }
      END { gsub(/^[["]|[]"]$/, "", d); gsub(/[[:space:]]+/, " ", d); print d }
    ' "$1" 2>/dev/null | cut -c1-118
  }

  printf '%s\n' "── EVIDENCIA para la Decisión #2 · origen: $_c_srcm"
  printf '%s\n' "   destino: $_c_dstm"
  printf '\n%-46s %8s  %-7s %-6s %-10s\n' "memoria" "bytes" "destino" "canal" "ult.commit"
  printf '%s\n' "$(printf '%.0s─' $(seq 1 88))"
  _c_n=0; _c_ya=0; _c_local=0
  for _c_f in "$_c_srcm"/*.md; do
    [ -f "$_c_f" ] || continue
    _c_b="$(basename "$_c_f")"; _c_n=$((_c_n+1))
    # ASCII a propósito: `printf '%-7s'` cuenta BYTES, así que un acento desalinea la tabla entera.
    _c_en_dst=$([ -f "$_c_dstm/$_c_b" ] && { _c_ya=$((_c_ya+1)); echo "YA"; } || echo "-")
    _c_trk=$(git -C "$_c_src" ls-files --error-unmatch -- ".claude/memory/$_c_b" >/dev/null 2>&1 && echo "git" || echo "ign")
    _c_last=$(git -C "$_c_src" log -1 --format=%ad --date=short -- ".claude/memory/$_c_b" 2>/dev/null)
    case "$_c_b" in *.local.md) _c_local=$((_c_local+1)); _c_mark=' ⟵ .local ⇒ canal SENSIBLE (T2 por convención)' ;; *) _c_mark='' ;; esac
    printf '%-46s %8s  %-7s %-6s %-10s%s\n' "$_c_b" "$(_c_size "$_c_f")" \
      "$_c_en_dst" "$_c_trk" "${_c_last:-(sin commit)}" "$_c_mark"
    _c_d="$(_c_desc "$_c_f")"
    if [ -z "$_c_d" ]; then   # ni frontmatter ni encabezado: la primera línea útil informa más que "ábrela"
      _c_d="$(grep -vE '^[[:space:]]*$|^---[[:space:]]*$' "$_c_f" 2>/dev/null | head -1 | cut -c1-118)"
      [ -n "$_c_d" ] && _c_d="(sin description) $_c_d" || _c_d="(vacía)"
    fi
    printf '    %s\n' "$_c_d"
  done
  printf '\n%s\n' "$_c_n memoria(s) · $_c_ya ya en el destino · $_c_local con sufijo .local"
  cat <<'LEYENDA'

CÓMO LEERLO (ninguna columna decide por sí sola — la frontera T1↔T3 es la Decisión #2, del humano):
  · destino=YA    → ya está allá: nada que mover (§1.0.1). Si además DIFIERE, S1/S5 PARAN y piden
                    reconciliación humana; no se pisa.
  · canal=git     → está VERSIONADA en el origen: copiarla al destino sin retirarla de allá deja DOS
                    copias versionadas, que driftan. Retirarla del origen es DESTRUCTIVO para el origen ⇒ decisión del humano.
  · canal=ign     → gitignored en el origen. Con sufijo `.local` es el canal SENSIBLE por convención del cerebro: viaja por bundle gitignored (T2), NUNCA
                    versionado, y da igual que el destino sea privado (un privado puede volverse público).
  · ult.commit    → cuándo se tocó por última vez: el cerebro del master se toca al trabajar el cerebro.
  · TRATO/preferencia personal → NO es T1/T2/T3. Por norma del cerebro vive en el
                    `como-trabajar-con-<user>.md` GLOBAL per-máquina, que no viaja por git. Si una memoria
                    es una preferencia tuya y no conocimiento del proyecto, su destino es ESE archivo.

Con el corte confirmado, pásalo al generador:  --t1 <memoria>  (repetible)
LEYENDA
  exit 0
fi

# ── subcomando `verificar` (re-verifica un handoff ya escrito: viajó por Drive/Windows, o lo generó
#    otra máquina). Se despacha ANTES del parseo de flags: no necesita ni parámetros ni Drive. ──────
if [ "${1:-}" = verificar ]; then
  [ -n "${2:-}" ] || { echo "uso: reubicar-master.sh verificar <handoff.sh>" >&2; exit 2; }
  _verificar_handoff "$2" "${REUBICAR_PRELUDIO:-$HOME/.claude/reubicar-preludio.sh}"
  exit 0
fi

# ══════════════════════════════════════════════════════════════════════════════════════════════════
# PARÁMETROS (§7 · Decisiones #0/#0b/#1/#2 — se preguntan al humano en RUNTIME, no se asumen)
# ══════════════════════════════════════════════════════════════════════════════════════════════════
# Ninguno tiene un default engañoso. `DRIVE` no tiene fallback: un default que apunta a la ruta de OTRA
# máquina no ayuda, miente — y CLAUDE_SESSIONS_DRIVE vive en el bloque `env` de ~/.claude/settings.json,
# así que en el shell plano que este skill prescribe está VACÍA (medido).
ID="${ID:-}"
DST_REPO="${DST_REPO:-}"
MASTER_NAME="${MASTER_NAME:-}"
MASTER_NAME_NUEVO="${MASTER_NAME_NUEVO:-}"
SRC_REPO="${SRC_REPO:-$HOME/code/plantilladotnet}"
DRIVE="${DRIVE:-${CLAUDE_SESSIONS_DRIVE:-}}"
DST_PROTEGIDO="${DST_PROTEGIDO:-}"
T2_ROOT="${T2_ROOT:-CLAUDE.local.md}"
SALIDA="${REUBICAR_SALIDA:-}"
CORRER_DRY=0
MEMORIAS_T1=()
# hilo-mental-actual.md (+ su overflow): es del MASTER, no del repo — gitignored en origen Y destino, así
# que si no viaja por aquí (T2) git NO lo recupera (M1/H3, ALTO). Va en el default junto a identidad y
# autorizaciones: misma clase (T2, gitignored, per-máquina), mismo canal.
T2_LOCAL=(conocimiento-propio.local.md autorizaciones-vigentes.local.md hilo-mental-actual.md hilo-mental-actual-overflow.md)
_t2_local_dado=0

while [ "$#" -gt 0 ]; do
  case "$1" in
    --id)             ID="${2:-}";                shift 2 ;;
    --dst-repo)       DST_REPO="${2:-}";          shift 2 ;;
    --master-name)    MASTER_NAME="${2:-}";       shift 2 ;;
    --nombre-nuevo)   MASTER_NAME_NUEVO="${2:-}"; shift 2 ;;
    --src-repo)       SRC_REPO="${2:-}";          shift 2 ;;
    --drive)          DRIVE="${2:-}";             shift 2 ;;
    --dst-protegido)  DST_PROTEGIDO="${2:-}";     shift 2 ;;
    --t2-root)        T2_ROOT="${2:-}";           shift 2 ;;
    --salida)         SALIDA="${2:-}";            shift 2 ;;
    --t1)             MEMORIAS_T1[${#MEMORIAS_T1[@]}]="${2:-}"; shift 2 ;;
    # --t2-local SUMA al default (M2, ALTO: la versión vieja de este flag REEMPLAZABA el default a la
    # primera vez que se usaba, y un operador que lo usaba para "arreglar" M1 —añadir hilo-mental-actual.md—
    # tiraba en SILENCIO conocimiento-propio.local.md y autorizaciones-vigentes.local.md: identidad y
    # autorizaciones, lo más caro). Quien de verdad quiera SOLO lo que liste usa --t2-local-solo.
    --t2-local)       T2_LOCAL[${#T2_LOCAL[@]}]="${2:-}"; shift 2 ;;
    --t2-local-solo)
      [ "$_t2_local_dado" -eq 1 ] || { T2_LOCAL=(); _t2_local_dado=1; }   # SOLO este flag reemplaza, y solo la 1a vez
      T2_LOCAL[${#T2_LOCAL[@]}]="${2:-}"; shift 2 ;;
    --dry)            CORRER_DRY=1;               shift ;;
    -h|--help)        _uso; exit 0 ;;
    *) printf 'opción desconocida: %s\n\n' "$1" >&2; _uso >&2; exit 2 ;;
  esac
done

# El ID se interpola en RUTAS (el .jsonl, el .state, el handoff, el .gz del Drive) ⇒ se valida su forma
# ANTES de construir una sola de ellas. Un id con '/' o con espacios escribiría fuera de donde se cree.
case "$ID" in
  '') printf 'falta --id (Decisión #1 / G-ID). Con --help ves cómo resolverlo.\n' >&2; exit 2 ;;
  *[!A-Za-z0-9._-]*) printf 'el --id "%s" trae caracteres fuera de [A-Za-z0-9._-]: se interpola en rutas.\n' "$ID" >&2; exit 2 ;;
esac
[ -n "$DST_REPO" ]    || { printf 'falta --dst-repo (Decisión #0: la casa REAL; sin default).\n' >&2; exit 2; }
[ -n "$MASTER_NAME" ] || { printf 'falta --master-name (el nombre ACTUAL en masters.json).\n' >&2; exit 2; }

# ══════════════════════════════════════════════════════════════════════════════════════════════════
# EL PRELUDIO — fuente única de helpers, preflight y derivadas
# ══════════════════════════════════════════════════════════════════════════════════════════════════
# Lo consumen los DOS lados: este script lo SOURCEA y el handoff lo CONCATENA. Es lo que hace imposible
# que el generador y el guion ejecutable deriven por separado — la clase de falla histórica del skill.
PRELUDIO="${REUBICAR_PRELUDIO:-$HOME/.claude/reubicar-preludio.sh}"
mkdir -p "$(dirname "$PRELUDIO")"
# Se escribe a un TEMPORAL y se publica con `mv` (rename atómico en el mismo dir), igual que todo lo
# demás del skill: es un archivo COMPARTIDO entre corridas y dos mudanzas casi simultáneas en la misma
# máquina lo sobre-escribirían a la vez. Con tmp+mv, un consumidor nunca lee un preludio a medio escribir.
PRELUDIO_TMP="$PRELUDIO.tmp.$$"
cat > "$PRELUDIO_TMP" <<'PRELUDIO_EOF'
# ── reubicar-master · PRELUDIO (helpers portables + preflight + derivadas) ──────────────
# Consumidores: (a) el cuerpo del skill lo SOURCEA; (b) el handoff de §6.1 lo CONCATENA.
# NO trae `set -e` a propósito: se sourcea. Quien lo ejecuta (el handoff) lo pone en su cabecera.
# Sourcéalo en un shell DESECHABLE (`bash`), no en tu terminal de trabajo: sus abortos hacen `exit`.

_abort(){ printf '%s\n' "$@" >&2; exit 1; }
# mtime en epoch. GNU primero, BSD de respaldo. Devuelve 0 si NINGUNA sirve → el llamador FALLA CERRADO.
_mtime(){ stat -c %Y "$1" 2>/dev/null || stat -f %m "$1" 2>/dev/null || echo 0; }
_size(){  stat -c %s "$1" 2>/dev/null || stat -f %z "$1" 2>/dev/null || echo 0; }
_perm(){  stat -c %a "$1" 2>/dev/null || stat -f %Lp "$1" 2>/dev/null || echo '?'; }
_fecha(){ date -r "$1" '+%m-%d %H:%M' 2>/dev/null || date -d "@$1" '+%m-%d %H:%M' 2>/dev/null || echo '??-?? ??:??'; }
_ahora(){ date '+%FT%T%z'; }                        # POSIX; `date -Iseconds` no lo es
# Ruta FÍSICA en la forma que habla ESTE shell. Va por `cd`+`pwd -P` (bash puro) y NO por
# `node -e realpathSync`: en Git Bash los parámetros del skill vienen en forma POSIX (`$HOME` es
# /c/Users/…) y node.exe es un binario NATIVO con la conversión de MSYS ya apagada, así que recibiría
# `/c/Users/…` como "raíz sin unidad" y la resolvería contra la unidad actual (`C:\c\Users\…`, que no
# existe) ⇒ ENOENT en la PRIMERA derivada, antes de llegar a la traducción `cygpath -w` de más abajo.
# `pwd -P` habla el mismo idioma que el resto del bash del guion en los tres OS.
_real(){  ( cd "$1" 2>/dev/null && pwd -P ) || _abort "no puedo resolver la ruta física de: $1" \
            "  (¿no existe, o no es un directorio?)"; }
# La forma que el HARNESS verá como cwd, y de la que DERIVA el slug: en Windows corre nativo (C:\…),
# así que la ruta de Git Bash (/c/…) produciría un slug que nadie mira. En macOS/Linux es la misma.
_cwdform(){ if [ "${SO:-}" = win ]; then cygpath -w "$1"; else printf '%s' "$1"; fi; }
# Los cwd de PRIMER NIVEL, tolerando la última línea cortada (verificado: `fromjson?` la omite, y el
# `cwd` de un sub-objeto —p. ej. dentro de toolUseResult— NO se cuenta; un `grep` textual sí los ve
# y aborta en falso). Es la MISMA vista que tiene el harness, que también parsea JSON por línea.
_cwds(){ jq -rR 'fromjson? | .cwd // empty' "$1" | sort -u; }
_cwds_n(){ _cwds "$1" | grep -c . || true; }
# El último evento CON cwd (no "la última línea"): es el par que hereda el próximo resume.
_ultimo_par(){ jq -rR 'fromjson? | select(.cwd) | "\(.cwd)|\(.gitBranch // "NULO")"' "$1" | tail -1; }

# ── PREFLIGHT de herramientas ───────────────────────────────────────────────────────────
_falta=""
for _t in bash jq node git tar find sort grep gzip; do
  command -v "$_t" >/dev/null 2>&1 || _falta="$_falta $_t"
done
[ -z "$_falta" ] || _abort "PREFLIGHT: faltan herramientas:$_falta" \
  "  Windows/Git Bash: corre cortex/bootstrap.ps1 (Git Bash + jq + Node) o 'winget install jqlang.jq'" \
  "  macOS: brew install <lo que falte>  ·  Linux: tu gestor de paquetes"

# ── PREFLIGHT de plataforma ─────────────────────────────────────────────────────────────
case "$(uname -s 2>/dev/null || echo desconocido)" in
  Darwin)              SO=mac ;;
  Linux)               SO=linux ;;
  MINGW*|MSYS*|CYGWIN*) SO=win ;;
  *)                   SO=otro ;;
esac
if [ "$SO" = win ]; then
  command -v cygpath >/dev/null 2>&1 || _abort "PREFLIGHT (Windows): falta cygpath (viene con Git for Windows)"
  # MSYS reescribe argumentos que PARECEN rutas POSIX al invocar binarios nativos (node.exe). Se apaga:
  # las rutas que pasamos a node son deliberadamente NATIVAS o deliberadamente POSIX, no una mezcla.
  export MSYS2_ARG_CONV_EXCL='*'
fi

# ── PREFLIGHT de parámetros ─────────────────────────────────────────────────────────────
[ -n "${ID:-}" ]          || _abort "PREFLIGHT: falta ID (Decisión #1 / G-ID)"
[ -n "${DST_REPO:-}" ]    || _abort "PREFLIGHT: falta DST_REPO (Decisión #0 — no hay default)"
[ -n "${SRC_REPO:-}" ]    || _abort "PREFLIGHT: falta SRC_REPO (de dónde SALE el master; se usa para OLD_SLUG)"
[ -n "${MASTER_NAME:-}" ] || _abort "PREFLIGHT: falta MASTER_NAME"
[ -d "$DST_REPO/.git" ] || [ -f "$DST_REPO/.git" ] || _abort "PREFLIGHT: DST_REPO no es un repo git: $DST_REPO"
NOMBRE_FINAL="${MASTER_NAME_NUEVO:-$MASTER_NAME}"
# El hook exportar-sesion-master.sh decide si una sesión es master leyendo el customTitle del transcript
# y EXIGE el sufijo `-master`. Un nombre final sin él APAGA el auto-export del master.
case "$NOMBRE_FINAL" in
  *-master) : ;;
  *) _abort "PREFLIGHT: el nombre final '$NOMBRE_FINAL' NO termina en '-master'." \
            "  exportar-sesion-master.sh dejaría de reconocer la sesión como master (su detección exige" \
            "  el sufijo) y el auto-export se APAGARÍA. Elige otro nombre (§7 #0b)." ;;
esac

# ── PREFLIGHT del Drive (punto único de falla: se valida ANTES, no a media mutación) ────
[ -n "${DRIVE:-}" ] || _abort "PREFLIGHT: DRIVE está vacío." \
  "  CLAUDE_SESSIONS_DRIVE vive en el bloque 'env' de ~/.claude/settings.json ⇒ en un shell PLANO NO existe." \
  "  Expórtala a mano apuntando a la carpeta 'claude-sessions' de TU Drive sincronizado:" \
  "    export CLAUDE_SESSIONS_DRIVE=\"\$HOME/<tu-carpeta-de-Drive>/claude-sessions\"" \
  "  (el hook de auto-export usa OTRO fallback — \$HOME/.claude-sessions — así que si no la exportas," \
  "   el operador y el mecanismo pueden apuntar a Drives DISTINTOS sin que nada lo note)"
[ -d "$DRIVE" ] || _abort "PREFLIGHT: el Drive no está montado/sincronizado: $DRIVE"
MJ="$DRIVE/masters.json"
[ -f "$MJ" ] || _abort "PREFLIGHT: no hay masters.json en $DRIVE (¿Drive a medio sincronizar?)"
jq -e . "$MJ" >/dev/null 2>&1 || _abort "PREFLIGHT: $MJ no es JSON válido (¿copia-en-conflicto a medias?)"
for _cc in "$DRIVE"/masters*.json; do
  [ -e "$_cc" ] || continue
  [ "$_cc" = "$MJ" ] && continue
  _abort "PREFLIGHT: copia-en-conflicto de Drive presente: $_cc" \
         "  masters.json es UN archivo compartido ⇒ reconcilia a mano ANTES de correr (Decisión #6)"
done

# ── PREFLIGHT de BIN (resuelto como seed.sh, no asumido en ~/code/cortex) ───────────────
BIN=""
for _c in "${CORTEX_BIN:-}" "$HOME/.local/bin" "$HOME/.cortex/bin" "$HOME/code/cortex/bin"; do
  [ -n "$_c" ] && [ -f "$_c/session-move.js" ] && [ -f "$_c/session-lib.js" ] && { BIN="$_c"; break; }
done
[ -n "$BIN" ] || _abort "PREFLIGHT: no encuentro session-move.js + session-lib.js." \
  "  Buscados: \$CORTEX_BIN, \$HOME/.local/bin, \$HOME/.cortex/bin, \$HOME/code/cortex/bin" \
  "  Instala cortex (bootstrap.sh / bootstrap.ps1) o exporta CORTEX_BIN=<dir>"

# ── PREFLIGHT de CAPACIDAD de la maquinaria (se mide lo que el guion INVOCA, no su versión) ─────────
# El BIN resuelto puede ser un cortex INSTALADO más viejo que este skill, y el skill lo descubriría a
# media mutación. MEDIDO el 2026-09-10 sobre la mudanza real: `~/.local/bin` llevaba 3 días atrás y NO
# tenía NI `--git-branch` NI `rewriteTranscriptStream` — las dos cosas que S4 invoca DESPUÉS del punto de
# no retorno. El handoff habría movido 152 MB de transcript y reventado al re-anclar.
# Se mide CAPACIDAD (que no caduca) y no fechas ni SHAs: un SHA distinto puede ser inofensivo, y uno
# idéntico puede seguir sin la función. El sello LIB_SHA del handoff es complementario — avisa de un
# CAMBIO entre generar y correr; esto exige la capacidad, y falla CERRADO.
_capfalta=""
_cap(){   # _cap <archivo> <patrón>
  if [ ! -f "$BIN/$1" ]; then
    case " $_capfalta " in *" $1(ausente) "*) : ;; *) _capfalta="$_capfalta $1(ausente)" ;; esac
  else
    grep -q -- "$2" "$BIN/$1" || _capfalta="$_capfalta $1:$2"
  fi
}
_cap session-move.js   '--git-branch'              # S4: re-ancla (cwd, gitBranch) en la MISMA pasada
_cap session-export.js '--name'                    # S3: exporta con el nombre FINAL (si no, un import revierte el alias)
for _fn in slugFromCwd sessionAliases writeAlias rewriteTranscriptStream aliasLockPath; do
  _cap session-lib.js "$_fn"
done
[ -z "$_capfalta" ] || _abort \
  "PREFLIGHT: la maquinaria de $BIN es MÁS VIEJA que este skill — le falta lo que el guion invoca:" \
  " $_capfalta" \
  "  Dos de esas se invocan DESPUÉS del punto de no retorno (el --git-branch del move y el re-anclaje en" \
  "  streaming de la lib), así que descubrirlo a media mudanza deja el transcript movido y el par" \
  "  (cwd, gitBranch) mal. Por eso se exige AQUÍ y aborta." \
  "  ARRÉGLALO actualizando cortex con SU herramienta de release (el updater del widget), NO corriendo" \
  "  el instalador a mano; o apunta CORTEX_BIN al bin del clon que sí las trae:" \
  "    CORTEX_BIN=<clon>/bin  (verifica con: grep -c -- --git-branch <clon>/bin/session-move.js)"

# ── DERIVADAS ───────────────────────────────────────────────────────────────────────────
SRC="$SRC_REPO/.claude"
DST_POSIX="$(_real "$DST_REPO")"        # ruta FÍSICA en el idioma de ESTE shell (bash la usa así)
SRC_POSIX="$(_real "$SRC_REPO")"
DST="$DST_POSIX/.claude"
# Las tres rutas de las que sale un slug pasan por `_cwdform`: el slug SIEMPRE se deriva de la forma
# NATIVA. Derivar OLD_SLUG de la ruta POSIX en Windows daba `-c-Users-…` donde el harness escribe
# `C--Users-…` ⇒ el gate buscaba el transcript en un slug que no existe.
DST_CWD="$(_cwdform "$DST_POSIX")"
SRC_CWD="$(_cwdform "$SRC_POSIX")"
HOME_CWD="$(_cwdform "$(_real "$HOME")")"
# El slug se deriva con la MISMA función que usa el mutador (single source: ni un `sed` paralelo).
_slug(){ node -e 'process.stdout.write(require(process.argv[1]).slugFromCwd(process.argv[2]))' "$BIN/session-lib.js" "$1"; }
OLD_SLUG="$(_slug "$SRC_CWD")"          # ojo: suele ser COMPARTIDO por cientos de sesiones
NEW_SLUG="$(_slug "$DST_CWD")"
PROJ="$HOME/.claude/projects"
JSONL="$PROJ/$OLD_SLUG/$ID.jsonl"
NEW_JSONL="$PROJ/$NEW_SLUG/$ID.jsonl"
GLOBAL_MEM="$PROJ/$(_slug "$HOME_CWD")/memory"   # cerebro de MÁQUINA
ST="$DRIVE/reubicar-$ID.state"               # archivo de ESTADO (reanudación por estado, no por adivinanza)
# target de masters.json: relativo a $HOME cuando el repo vive bajo $HOME; ABSOLUTO si no.
case "$DST_POSIX" in
  "$HOME"/*) TARGET="${DST_POSIX#"$HOME"/}" ;;
  *) TARGET="$DST_POSIX"
     echo "  nota: el destino vive FUERA de \$HOME ⇒ target ABSOLUTO ($TARGET). seed.sh lo consume como" >&2
     echo "        relativo a \$HOME: verifica a mano que resuelva bien antes de sembrar en otra máquina." >&2 ;;
esac
PRELUDIO_EOF
bash -n "$PRELUDIO_TMP" || { rm -f "$PRELUDIO_TMP"; echo "PRELUDIO con error de sintaxis: no lo publico" >&2; exit 1; }
mv -f "$PRELUDIO_TMP" "$PRELUDIO"      # publicación ATÓMICA (rename en el mismo dir)
echo "preludio OK: $PRELUDIO"

# El preludio se SOURCEA aquí, en ESTE proceso. Ya no hay «córrelo en la misma shell» que equivocar: sus
# abortos son abortos DEL SCRIPT (fail-closed) y sus derivadas están disponibles para el generador de
# abajo sin depender de ningún paso previo del operador.
. "$PRELUDIO"
echo "SO=$SO  BIN=$BIN  OLD_SLUG=$OLD_SLUG  NEW_SLUG=$NEW_SLUG  DST_CWD=$DST_CWD  TARGET=$TARGET"

# H4: --salida se asignaba y nunca se leía (la ruta salía SIEMPRE hardcodeada al Drive, sin aviso). Un
# operador que la redirige FUERA del Drive sincronizado —por privacidad, o porque el Drive es el recurso
# en disputa del §9— obtenía justo lo contrario de lo que pidió. Ahora manda si se dio.
H="${SALIDA:-$DRIVE/handoff-$ID.sh}"
mkdir -p "$(dirname "$H")"
# ── 1) cabecera: los parámetros HORNEADOS con printf %q (una sustitución controlada; el resto del
#       guion va en heredocs CITADOS, así que no hay ni un `\$` que escapar a mano) ─────────────
{
  printf '%s\n' '#!/usr/bin/env bash'
  printf '# handoff reubicar-master: %s (%s) → %s%s\n' "$MASTER_NAME" "$ID" "$DST_CWD" \
         "${MASTER_NAME_NUEVO:+  (renombre a $MASTER_NAME_NUEVO)}"
  printf '# Generado %s · CLI de Claude Code verificado al escribirlo: %s\n' "$(_ahora)" \
         "${CLAUDE_CODE_VERSION:-2.1.236}"
  printf '%s\n' '# El formato del .jsonl es INTERNO y cambia entre versiones del CLI: si tu CLI es otro,'
  printf '%s\n' '# corre primero con REUBICAR_MODO=dry y revisa el "último evento" antes de mutar.'
  printf '%s\n' '# CORRER con la sesión CERRADA, desde un SHELL PLANO (no desde una sesión de Claude).'
  printf '%s\n' '#   REUBICAR_MODO=dry|full|s7   ·   REUBICAR_LIVENESS_OK=1   ·   REUBICAR_QUIESCE_OK=1'
  printf '%s\n' 'set -euo pipefail'
  printf '%s\n' 'umask 077'
  # SELLO de la maquinaria que se horneó. Lo que el preludio congela es su propio TEXTO, no la API de
  # session-lib.js que ese texto invoca en tiempo de EJECUCIÓN: un handoff generado hoy, guardado en el
  # Drive y corrido después de actualizar cortex invocaría la lib NUEVA con los supuestos VIEJOS.
  printf 'LIB_SHA_HORNEADO=%q\n' \
    "$(node -e 'const c=require("crypto"),f=require("fs");process.stdout.write(c.createHash("sha256").update(f.readFileSync(process.argv[1])).digest("hex").slice(0,12))' "$BIN/session-lib.js")"
  printf 'ID=%q\n'                 "$ID"
  printf 'MASTER_NAME=%q\n'        "$MASTER_NAME"
  printf 'MASTER_NAME_NUEVO=%q\n'  "${MASTER_NAME_NUEVO:-}"
  printf 'SRC_REPO=%q\n'           "$SRC_REPO"
  printf 'DST_REPO=%q\n'           "$DST_REPO"
  printf 'DRIVE=%q\n'              "$DRIVE"
  printf 'DST_PROTEGIDO=%q\n'      "${DST_PROTEGIDO:-}"
  printf 'T2_ROOT=%q\n'            "$T2_ROOT"
  printf 'T2_LOCAL=(';    for m in ${T2_LOCAL[@]+"${T2_LOCAL[@]}"};       do printf '%q ' "$m"; done; printf ')\n'
  printf 'MEMORIAS_T1=('; for m in ${MEMORIAS_T1[@]+"${MEMORIAS_T1[@]}"}; do printf '%q ' "$m"; done; printf ')\n'
} > "$H"

# ── 2) el PRELUDIO, textual: la MISMA fuente que sourcea el cuerpo (§2). No es una copia en markdown:
#       es `cat` del archivo. Por construcción, cuerpo y handoff no pueden divergir en helpers,
#       preflight ni derivadas — que fue exactamente la clase de falla histórica de este skill. ──
cat "$PRELUDIO" >> "$H"

# ── 3) los pasos destructivos (heredoc CITADO: nada se expande aquí) ─────────────────────────────
cat >> "$H" <<'HANDOFF_EOF'

MODO="${REUBICAR_MODO:-full}"
echo "### handoff reubicar-master · MODO=$MODO · ID=$ID · destino=$DST_CWD ($NEW_SLUG)"

# ── ¿la maquinaria que invoco es la que se horneó? (AVISA, no bloquea: una actualización legítima de
#    cortex no debe frenar una mudanza, pero el operador tiene que saber que el guion es de otra época) ─
LIB_SHA_AHORA="$(node -e 'const c=require("crypto"),f=require("fs");process.stdout.write(c.createHash("sha256").update(f.readFileSync(process.argv[1])).digest("hex").slice(0,12))' "$BIN/session-lib.js" 2>/dev/null || echo desconocido)"
if [ "$LIB_SHA_AHORA" != "${LIB_SHA_HORNEADO:-}" ]; then
  echo "  ⚠ session-lib.js CAMBIÓ desde que se generó este handoff (horneado ${LIB_SHA_HORNEADO:-?} · instalado $LIB_SHA_AHORA)."
  echo "    Este guion asume el comportamiento de la lib de ENTONCES. Re-genera el handoff desde el skill"
  echo "    (§6.1) antes de mutar, o corre primero REUBICAR_MODO=dry y revisa el plan."
fi

# ── inventario de ESTADO ante cualquier salida anormal (§ DESHACER del skill) ───────────────────
_inventario(){
  echo ""
  echo "── INVENTARIO DE ESTADO (para reanudar o deshacer) ──"
  echo "  paso alcanzado : $( [ -f "$ST" ] && cat "$ST" || echo '(sin archivo de estado ⇒ nada destructivo corrió)' )"
  echo "  origen         : $JSONL  →  $( [ -f "$JSONL" ] && echo "PRESENTE ($(_size "$JSONL") bytes)" || echo ausente )"
  echo "  destino        : $NEW_JSONL  →  $( [ -f "$NEW_JSONL" ] && echo "PRESENTE ($(_size "$NEW_JSONL") bytes)" || echo ausente )"
  echo "  masters.json   : $(jq -r --arg id "$ID" '(.masters[]|select(.id==$id)|"target=\(.target) name=\(.name)") // "(el id NO está en el registro)"' "$MJ" 2>/dev/null || echo '(ilegible)')"
  echo "  respaldos      : $HOME/.claude/reubicar-backups/   (propios, la poda NO los toca)"
  echo "                   $HOME/.claude/session-move-backups/   (de session-move.js: conserva 10)"
  echo "                   $DRIVE/$ID.jsonl.gz   (export de S3, durable)"
  echo "  REANUDAR: re-corre ESTE script (detecta el estado y continúa).  DESHACER: § DESHACER del skill."
}
trap 'rc=$?; [ "$rc" -eq 0 ] || _inventario' EXIT

# ── G-SELF-MOVE (fail-CLOSED: la variable real es CLAUDE_CODE_SESSION_ID) ───────────────────────
echo "── G-SELF-MOVE ──"
if [ "${CLAUDECODE:-}" = "1" ] || [ -n "${CLAUDE_CODE_ENTRYPOINT:-}" ]; then
  YO="${CLAUDE_CODE_SESSION_ID:-${CLAUDE_SESSION_ID:-}}"
  [ -n "$YO" ] || _abort "BLOQUEO G-SELF-MOVE (fail-closed): corro DENTRO de Claude Code y no puedo leer mi session-id" \
    "  Sin medirlo no puedo descartar ser la sesión objetivo. Córrelo desde un SHELL PLANO."
  [ "$YO" != "$ID" ] || _abort "BLOQUEO G-SELF-MOVE: soy la sesión objetivo ($ID); moverme me partiría el transcript" \
    "  Ciérrame y corre este guion desde un shell plano, la otra máquina o una sesión DISTINTA (danza §6)."
  echo "  ok: soy $YO, el objetivo es $ID"
else
  YO=""
  echo "  ok: shell plano (CLAUDECODE ausente) ⇒ no puedo ser la sesión objetivo"
fi

# ── G-QUIESCE por ARTEFACTO (no por proceso: contar con pgrep falla en las dos direcciones — ver §9
#    del skill, fila "El gate de quiescencia no mide nada") ───────────────────────────────────────
# Mide lo que esta mudanza REALMENTE puede pisar, no "cualquier sesión de Claude en la máquina":
#   · BLOQUEA una sesión ajena caliente en el slug ORIGEN o el slug DESTINO. Ahí la colisión es real: el
#     barrido del origen, el `.jsonl` del destino y el depósito T2 en el repo destino se pisan con lo que
#     esa sesión escriba — y el daemon transitorio CUENTA, porque arrastra el PWD de quien lo lanzó y
#     puede sembrar un transcript justo en el slug nuevo.
#   · AVISA (no bloquea) por las de OTROS slugs. Los dos artefactos COMPARTIDOS que quedan —`masters.json`
#     y el mapa de alias— se escriben BAJO LOCK (`mkdir`, con reciclado del huérfano) por todo lo que pasa
#     por la lib, y todo lo demás que el guion toca está scopeado a $ID. **La relajación es sólida SOLO
#     por ese lock**, y por eso el preflight de capacidad EXIGE `aliasLockPath`: una lib vieja sin lock no
#     llega hasta aquí. Excepción conocida (§10 del skill): el widget de Plasma escribe el mapa desde QML
#     sin la lib ⇒ sin lock; por eso `_postcondiciones` asevera además que ningún alias AJENO se perdió —
#     el lock ata a quien pasa por la lib, la aserción caza a quien no.
#   · REUBICAR_QUIESCE_ESTRICTO=1 restaura el todo-o-nada (cero sesiones vivas en la máquina).
# Medido el 2026-09-10: con un `databases-master` trabajando en otro repo, el gate viejo bloqueaba una
# mudanza que no tenía forma de tocarlo, y el humano tenía que interrumpir su trabajo por un proxy.
echo "── G-QUIESCE ──"
QUIESCE_MIN="${REUBICAR_QUIESCE_MIN:-5}"
_ref="$(mktemp)"
touch -t "$(date -v-"${QUIESCE_MIN}"M '+%Y%m%d%H%M' 2>/dev/null || date -d "-${QUIESCE_MIN} min" '+%Y%m%d%H%M')" "$_ref" \
  || { rm -f "$_ref"; _abort "BLOQUEO G-QUIESCE (fail-closed): no pude fabricar la referencia de tiempo (ni 'date -v' ni 'date -d')"; }
_calientes="$(find "$PROJ" -maxdepth 2 -name '*.jsonl' -newer "$_ref" ! -name "$ID.jsonl" 2>/dev/null || true)"
rm -f "$_ref"
[ -n "$YO" ] && _calientes="$(printf '%s\n' "$_calientes" | grep -v "/$YO\.jsonl\$" || true)"
# los slugs son [A-Za-z0-9-] por construcción (todo lo demás se vuelve '-'), así que van directo en la ERE
_cal_relev="$(printf '%s\n' "$_calientes" | grep -E "/($OLD_SLUG|$NEW_SLUG)/[^/]+\.jsonl\$" || true)"
_cal_otros="$(printf '%s\n' "$_calientes" | grep -vE "/($OLD_SLUG|$NEW_SLUG)/[^/]+\.jsonl\$" || true)"
if [ -n "$(printf '%s' "$_cal_relev" | tr -d '[:space:]')" ]; then
  echo "  sesión(es) ajena(s) CALIENTE(s) en el slug de ORIGEN o de DESTINO:"
  printf '    %s\n' $_cal_relev
  _abort "BLOQUEO G-QUIESCE: hay una sesión viva parada en el repo ORIGEN o DESTINO de esta mudanza." \
         "  Ahí la colisión es REAL (barrido del origen · .jsonl del destino · depósito T2 en el repo" \
         "  destino). Ciérrala y vuelve a correr; las de OTROS repos no hace falta cerrarlas." \
         "  (el daemon transitorio CUENTA: arrastra el PWD de quien lo lanzó)"
fi
echo "  ok: nada ajeno caliente en los slugs de origen/destino (<${QUIESCE_MIN}m)"
if [ -n "$(printf '%s' "$_cal_otros" | tr -d '[:space:]')" ]; then
  if [ "${REUBICAR_QUIESCE_ESTRICTO:-0}" = "1" ]; then
    echo "  transcript(s) ajenos calientes en otros slugs, y REUBICAR_QUIESCE_ESTRICTO=1:"
    printf '    %s\n' $_cal_otros
    _abort "BLOQUEO G-QUIESCE (estricto): cierra TODAS las sesiones de Claude en esta máquina"
  fi
  echo "  ⚠ sesión(es) viva(s) en OTROS slugs — NO bloquean (masters.json y el mapa de alias van bajo lock):"
  printf '    %s\n' $_cal_otros
  echo "    Si quieres cero riesgo compartido, ciérralas y corre con REUBICAR_QUIESCE_ESTRICTO=1."
fi

# ── CITAS HUMANAS materializadas como GATES (en 'dry' se listan, no se exigen) ──────────────────
if [ "$MODO" != dry ]; then
  [ "${REUBICAR_QUIESCE_OK:-0}" = "1" ] || _abort \
    "BLOQUEO: falta la CITA HUMANA de G-QUIESCE." \
    "  Cuando el humano diga textual «no hay ninguna sesión de Claude trabajando en <origen> ni en" \
    "  <destino>» (las de OTROS repos pueden seguir abiertas), re-corre con  REUBICAR_QUIESCE_OK=1"
  if [ "$MODO" = full ]; then
    [ "${REUBICAR_LIVENESS_OK:-0}" = "1" ] || _abort \
      "BLOQUEO: falta la CITA HUMANA de G-LIVENESS." \
      "  Cuando el humano diga textual «la sesión $ID en <máquina> está CERRADA»," \
      "  re-corre con  REUBICAR_LIVENESS_OK=1"
  fi
fi

# ── rama del destino: se necesita ANTES de mutar (un detached HEAD dejaría gitBranch="" y la
#    postcondición se cumpliría con la cadena vacía) ─────────────────────────────────────────────
RAMA_DST="$(git -C "$DST_POSIX" branch --show-current 2>/dev/null || true)"
[ -n "$RAMA_DST" ] || _abort "BLOQUEO: el destino está en detached HEAD ⇒ no hay rama que escribir en el último evento" \
  "  Haz checkout de la rama de trabajo del destino y vuelve a correr."

# Fotografía de las claves del mapa de alias ANTES de tocarlo. El mapa es COMPARTIDO por todos los
# masters de la máquina: `writeAlias` ya va bajo lock, pero una lib VIEJA corriendo en otro proceso puede
# seguir escribiéndolo sin lock ⇒ no se confía en el lock, se ASEVERA el resultado. Vacío = no aplica
# (modo s7, o el paso del alias aún no corrió).
ALIAS_ANTES=""
_alias_keys(){ node -e 'const a=require(process.argv[1]).sessionAliases();process.stdout.write(Object.keys(a).sort().join("\n"))' "$BIN/session-lib.js"; }

# ── POSTCONDICIONES · UNA sola definición, la usan S4/S5 (modo full) y S7 ───────────────────────
_postcondiciones(){
  local n uniq_n uniq_v got par modo_f alias_leido enl perdidas keys_ahora k
  echo "── POSTCONDICIONES (aserciones: si una falla, NO se imprime el ✅) ──"
  n="$(find "$PROJ" -maxdepth 2 -name "$ID.jsonl" 2>/dev/null | grep -c . || true)"
  if [ "$n" -ne 1 ]; then
    find "$PROJ" -maxdepth 2 -name "$ID.jsonl" 2>/dev/null | sed 's/^/    /'
    _abort "ABORTO: hay $n copias de $ID.jsonl (se exige exactamente 1)" \
           "  Si la del slug VIEJO es un transcript NUEVO (un resume mal parado), NO la borres:" \
           "  sácala del árbol con 'mv' a $HOME/.claude/session-move-backups/ y conserva su contenido."
  fi
  echo "  ok: exactamente 1 copia del .jsonl"
  uniq_v="$(_cwds "$NEW_JSONL")"; uniq_n="$(_cwds_n "$NEW_JSONL")"
  [ "$uniq_n" -eq 1 ] && [ "$uniq_v" = "$DST_CWD" ] \
    || _abort "ABORTO: cwd no uniforme ($uniq_n valor/es distintos de primer nivel):" "$(_cwds "$NEW_JSONL" | sed 's/^/    /')" \
              "  esperaba exactamente: $DST_CWD"
  echo "  ok: cwd único = $uniq_v"
  par="$(_ultimo_par "$NEW_JSONL")"
  [ "$par" = "$DST_CWD|$RAMA_DST" ] \
    || _abort "ABORTO: el ÚLTIMO evento con cwd quedó '$par', esperaba '$DST_CWD|$RAMA_DST'" \
              "  (es el par que hereda el PRÓXIMO resume — lo fija el move con --git-branch; ver S4)"
  echo "  ok: último evento con cwd = $par"
  modo_f="$(_perm "$NEW_JSONL")"
  if [ "$SO" = win ]; then
    echo "  ⚠ S4-2c en Windows/NTFS: 'chmod 600' NO se refleja en ACLs; el modo leído ($modo_f) es INFORMATIVO."
    echo "    Límite DECLARADO de la plataforma, no un fallo: protege el transcript por permisos de carpeta."
  else
    [ "$modo_f" = 600 ] || _abort "ABORTO: el modo del .jsonl es $modo_f, esperaba 600 (S4-2c)"
    echo "  ok: modo 600"
  fi
  got="$(jq -r --arg id "$ID" '(.masters[]|select(.id==$id)|"\(.target)|\(.name)") // ""' "$MJ")"
  [ "$got" = "$TARGET|$NOMBRE_FINAL" ] \
    || _abort "ABORTO: masters.json quedó '$got', esperaba '$TARGET|$NOMBRE_FINAL'" \
              "  (cadena vacía = el id NO está en el registro ⇒ el UPSERT no corrió o se revirtió)"
  echo "  ok: masters.json target|name = $got"
  alias_leido="$(node -e 'const a=require(process.argv[1]).sessionAliases(); process.stdout.write(a[process.argv[2]]||"")' "$BIN/session-lib.js" "$ID")"
  [ "$alias_leido" = "$NOMBRE_FINAL" ] \
    || _abort "ABORTO: el alias quedó '$alias_leido', esperaba '$NOMBRE_FINAL'" \
              "  writeAlias respalda un JSON ilegible y va BAJO LOCK (no pisa a otro escritor): si el alias" \
              "  no quedó, o el lock estaba tomado (lo dice en su AVISO) o alguien escribió el mapa SIN lock" \
              "  (una lib de cortex vieja en otro proceso). Revisa ~/.claude/sesiones-alias.json y su .lock."
  echo "  ok: alias = $alias_leido"
  if [ -n "${ALIAS_ANTES:-}" ]; then
    keys_ahora="$(_alias_keys)"; perdidas=""
    for k in $ALIAS_ANTES; do
      printf '%s\n' "$keys_ahora" | grep -qx -- "$k" || perdidas="$perdidas $k"
    done
    [ -z "$perdidas" ] || _abort \
      "ABORTO: se PERDIERON alias AJENOS del mapa compartido:$perdidas" \
      "  El mapa lo comparten todos los masters de la máquina. Otro escritor SIN lock (una lib de cortex" \
      "  vieja en otro proceso) hizo read-modify-write encima. Recupéralos: el respaldo del mapa vive en" \
      "  $HOME/.claude/sesiones-alias.json.ilegible.* si estaba corrupto, y si no, re-fíjalos con" \
      "  node -e 'require(\"$BIN/session-lib.js\").writeAlias(\"<id>\",\"<nombre>\")' — y actualiza el" \
      "  cortex de esa otra máquina/proceso: sin el lock esto se repite."
    echo "  ok: los $(printf '%s\n' $ALIAS_ANTES | grep -c . || true) alias que ya existían siguen en el mapa"
  fi
  [ -L "$PROJ/$NEW_SLUG/memory" ] && _abort "ABORTO: reapareció el symlink 'memory' en el slug nuevo (el bootstrap lo re-siembra) ⇒ retíralo" || true
  enl="$(find "$DST" -type l 2>/dev/null || true)"      # SIN -L: con -L, find solo ve los ROTOS (verificado)
  [ -z "$enl" ] || _abort "ABORTO: el cerebro del destino tiene symlinks (ni rotos ni sanos deben quedar):" "$(printf '%s\n' "$enl" | sed 's/^/    /')"
  echo "  ok: cero symlinks en $DST y en el slug nuevo"
  if find "$PROJ/$OLD_SLUG" -maxdepth 1 -name memory 2>/dev/null | grep -q .; then
    echo "  ok: el 'memory' del slug COMPARTIDO sigue vivo (no se tocó)"
  else
    echo "  nota: el slug viejo no tiene 'memory' (puede que nunca lo tuviera — este skill jamás lo crea"
    echo "        ni lo borra; si lo tenía y desapareció, alguien más lo barrió)"
  fi
  # ── SIDECAR (H1): session-move.js ya lo mueve consigo (subagents/tool-results/workflows) con su propia
  #    disciplina de copia+verificación+publicación. Aquí solo se ASEVERA que no quedó huérfano en el
  #    slug VIEJO — si esto dispara, `session-move.js` cambió y dejó de llevárselo: no declares LISTO.
  if [ -d "$PROJ/$OLD_SLUG/$ID" ]; then
    _abort "ABORTO [G-SIDECAR]: el sidecar de la sesión ($PROJ/$OLD_SLUG/$ID: subagents/tool-results/workflows)" \
           "  quedó huérfano en el slug VIEJO — session-move.js debía llevárselo junto con el .jsonl." \
           "  El master despertaría con su fan-out incompleto. NO declares LISTO."
  fi
  echo "  ok [G-SIDECAR]: sin sidecar huérfano en el slug viejo ($PROJ/$OLD_SLUG/$ID)"
}

# ── RE-ANCLAJE de REPARACIÓN · UNA sola definición, la usan S4 (si el move no dejó el par bueno) y S7
#    (si el resume lo contaminó). Va por `rewriteTranscriptStream` de la MISMA lib que usa el move:
#    STREAMING con memoria ACOTADA por la ventana de retención, no `readFileSync` del archivo completo.
#    Medido: el pico lo fija `holdBytes`, NO el tamaño del archivo (mismo pico sobre 107 MB y 428 MB;
#    con 32 MiB de ventana ≈ 320 MB de pico). Leer el transcript completo a un string costaba 1.73 GiB
#    sobre un archivo de 429 MB — y este paso corre DESPUÉS del punto de no retorno, que es justo donde
#    una excepción por memoria es catastrófica.
#    Escribe a un temporal del MISMO dir y publica con rename; preserva el modo y la última línea cortada.
#    `gitBranchRewritten` vuelve en 0 si el último evento con `cwd` quedó FUERA de la ventana ⇒ se
#    propaga como fallo (exit 3) para que NO se declare reparado lo que no se reparó.
_reancla(){
  echo "  re-anclando en streaming (cwd + gitBranch del último evento con cwd)"
  node -e '
    const fs=require("fs"), lib=require(process.argv[1]);
    const [f,cwd,br]=process.argv.slice(2);
    const t=f+".reubicar.tmp";
    lib.rewriteTranscriptStream(fs.createReadStream(f), t, {toCwd:cwd, gitBranch:br, holdBytes:33554432})
      .then(function(r){
        fs.chmodSync(t, fs.statSync(f).mode & 0o777);
        fs.renameSync(t, f);
        process.stdout.write("    cwd reescritos="+r.cwdRewritten+"  gitBranch="+r.gitBranchRewritten
                             +"  lineas="+r.lines+"  ultima-linea-cortada="+r.truncated+"\n");
        if (r.gitBranchRewritten !== 1) {
          process.stderr.write("    el ultimo evento con cwd quedo FUERA de la ventana de 32 MiB:"
            + " no se fijo el gitBranch\n");
          process.exit(3);
        }
      })
      .catch(function(e){
        try { fs.unlinkSync(t); } catch (_) {}
        process.stderr.write("    "+String((e && e.message) || e)+"\n");
        process.exit(1);
      });
  ' "$BIN/session-lib.js" "$NEW_JSONL" "$DST_CWD" "$RAMA_DST"
}

# ── MODO dry: gates + plan + el último evento, y FUERA antes de mutar ───────────────────────────
if [ "$MODO" = dry ]; then
  echo "── PLAN (dry-run: nada se muta) ──"
  echo "  ID              : $ID"
  echo "  nombre          : $MASTER_NAME  →  $NOMBRE_FINAL"
  echo "  origen  (slug)  : $OLD_SLUG"
  echo "  destino (slug)  : $NEW_SLUG"
  echo "  --to-cwd        : $DST_CWD"
  echo "  masters target  : $TARGET"
  echo "  rama del destino: $RAMA_DST"
  echo "  bundle T2       : $( [ -f "$DRIVE/$ID.brain-local.tgz" ] && echo presente || echo "ausente ($( [ -f "$DRIVE/$ID.brain-local.tgz.aplicado" ] && echo 'ya aplicado' || echo 'S2 fue no-op' ))" )"
  # dry REPLICA el chequeo de colisión de G-LIVENESS (que solo corre en MODO=full): con `head -1`
  # el dry-run daba un plan silencioso sobre UNA copia mientras full bloquearía por las N.
  _COPIAS_DRY="$(find "$PROJ" -maxdepth 2 -name "$ID.jsonl" 2>/dev/null)"
  _NCOP_DRY=$(printf '%s\n' "$_COPIAS_DRY" | grep -c . || true)
  _DRY_ALERTA=0
  if [ "$_NCOP_DRY" -eq 0 ]; then
    echo "  transcript      : ⚠️ NINGUNO bajo $PROJ ⇒ MODO=full BLOQUEARÍA en G-LIVENESS"
    _DRY_ALERTA=1
  elif [ "$_NCOP_DRY" -gt 1 ]; then
    echo "  transcript      : ⚠️ el id vive en $_NCOP_DRY slugs ⇒ MODO=full BLOQUEARÍA en G-LIVENESS y pediría limpieza manual:"
    printf '%s\n' "$_COPIAS_DRY" | sed 's/^/                      /'
    echo "                    (estado típico de una corrida previa muerta entre el rename y el unlink: recuperable, pero se resuelve A MANO)"
    _DRY_ALERTA=1
  else
    _t="$_COPIAS_DRY"
    echo "  transcript      : $_t  ($(_size "$_t") bytes, $(_cwds_n "$_t") cwd distintos)"
    echo "  último evento   : $(_ultimo_par "$_t")   ⇒ quedará '$DST_CWD|$RAMA_DST' (move --git-branch)"
  fi
  echo "  citas humanas   : LIVENESS=${REUBICAR_LIVENESS_OK:-0}  QUIESCE=${REUBICAR_QUIESCE_OK:-0}  (ambas deben ser 1 en MODO=full)"
  if [ "${_DRY_ALERTA:-0}" -eq 0 ]; then
    echo "✅ dry-run OK: los gates pasan y el plan es el de arriba. Nada se mutó."
  else
    echo "⚠️ dry-run con AVISO: MODO=full bloquearía por lo marcado arriba. Nada se mutó."
  fi
  exit 0
fi

# ── MODO s7: re-verificar DESPUÉS del QA (§S7) ──────────────────────────────────────────────────
if [ "$MODO" = s7 ]; then
  echo "── S7 · re-verificando las invariantes DESPUÉS del QA ──"
  ALIAS_ANTES="$(_alias_keys)"   # el QA fue un resume: si el mapa ya perdió claves, esto NO lo caza —
                                 # aquí solo se verifica que S7 mismo no las pierda. Lo dice para no mentir.
  [ -f "$NEW_JSONL" ] || _abort "S7: no hay transcript en el slug nuevo ($NEW_JSONL)"
  uniq_v="$(_cwds "$NEW_JSONL")"; uniq_n="$(_cwds_n "$NEW_JSONL")"
  par="$(_ultimo_par "$NEW_JSONL")"
  if [ "$uniq_n" -ne 1 ] || [ "$uniq_v" != "$DST_CWD" ] || [ "$par" != "$DST_CWD|$RAMA_DST" ]; then
    echo "  el resume contaminó el cwd y/o el último evento ⇒ reparando"
    _reancla
  fi
  _postcondiciones
  echo "✅ S7 verificado: las invariantes de S4/S5 siguen en pie tras el QA (esto NO es LISTO:"
  echo "   el sello lo pone el humano con su QA funcional, no este guion)."
  echo "   Recuerda la COTA del bucle S6→S7: máximo 2 iteraciones; a la tercera, PARA y escala."
  exit 0
fi

# ══════════════════════════════════════════════════════════════════════════════════════════════
# MODO full · pasos DESTRUCTIVOS
# ══════════════════════════════════════════════════════════════════════════════════════════════

# ── G-LIVENESS: mide EL ARCHIVO QUE SE VA A MOVER (findSession barre TODOS los slugs y elige por
#    mtime; un gate que mire solo el slug viejo puede certificar frío sobre la copia MUERTA
#    mientras el mutador se lleva la VIVA de otro slug) ──────────────────────────────────────────
echo "── G-LIVENESS (re-verificado AQUÍ, no heredado) ──"
COPIAS="$(find "$PROJ" -maxdepth 2 -name "$ID.jsonl" 2>/dev/null | sort)"
NCOP="$(printf '%s\n' "$COPIAS" | grep -c . || true)"
if [ "$NCOP" -eq 0 ]; then
  _abort "BLOQUEO: no hay ningún $ID.jsonl bajo $PROJ"
elif [ "$NCOP" -gt 1 ]; then
  printf '    %s\n' $COPIAS
  _abort "BLOQUEO G-LIVENESS: el id vive en $NCOP slugs ⇒ el mutador elegiría por CONTENIDO (ts→bytes→mtime) y podría llevarse la que NO es" \
         "  Deja UNA sola copia ANTES (las otras a $HOME/.claude/session-move-backups/ con 'mv', nunca 'rm')."
fi
TGT_FILE="$COPIAS"
if [ "$TGT_FILE" = "$NEW_JSONL" ]; then
  echo "  (ya movido: el .jsonl vive en el slug NUEVO ⇒ reanudando desde S4 paso 3)"
  YA_MOVIDO=1
else
  YA_MOVIDO=0
  _mt="$(_mtime "$TGT_FILE")"
  [ "$_mt" -gt 0 ] || _abort "BLOQUEO G-LIVENESS (fail-closed): no pude leer el mtime de $TGT_FILE (¿stat incompatible?)"
  _age=$(( ( $(date +%s) - _mt ) / 60 ))
  [ "$_age" -ge "${REUBICAR_LIVE_MIN:-15}" ] \
    || _abort "BLOQUEO G-LIVENESS: $TGT_FILE tocado hace ${_age}m (<${REUBICAR_LIVE_MIN:-15}) ⇒ presunta VIVA"
  [ -f "$DRIVE/.export-$ID.lock" ] && _abort "BLOQUEO G-LIVENESS: auto-export detached en vuelo (el hook exporta en background)" || true
  echo "  ok: $TGT_FILE frío hace ${_age}m"
  # SIN techo de tamaño: todo el camino que toca el transcript va en STREAMING con memoria ACOTADA
  # (medido: el pico lo fija la ventana de retención, no el archivo — ver §9). Lo único que ESCALA con
  # el tamaño es el DISCO: el move escribe la copia completa del destino ANTES de borrar el origen.
  _sz="$(_size "$TGT_FILE")"
  echo "  transcript: $_sz bytes ⇒ necesitas ~$(( _sz / 1024 / 1024 * 4 )) MB libres en el filesystem de"
  echo "    $PROJ: pueden coexistir hasta 4 copias — origen + respaldo del handoff + respaldo interno"
  echo "    de session-move.js + el .part del destino (el origen se borra al final)."
fi

# ── S3 export-first (capa 3 de recuperación; postcondición por CONTENIDO, no por mtime) ─────────
echo "── S3 export-first ──"
if [ "$YA_MOVIDO" -eq 0 ]; then
  _tmpe="$(mktemp -d)"
  node "$BIN/session-export.js" "$ID" --repo "$_tmpe" --name "$NOMBRE_FINAL" --force
  cp -f "$_tmpe/.claude/sessions/$ID.jsonl.gz" "$_tmpe/.claude/sessions/$ID.meta.json" "$DRIVE/"
  rm -rf "$_tmpe"
  _lsrc="$(wc -l < "$TGT_FILE" | tr -d ' ')"
  _lgz="$(gzip -dc "$DRIVE/$ID.jsonl.gz" | wc -l | tr -d ' ')"
  [ "$_lgz" -ge "$_lsrc" ] \
    || _abort "S3: el .gz tiene $_lgz líneas y la sesión $_lsrc ⇒ el export NO cubre la sesión. ABORTA (nada se mutó aún)."
  echo "  ok: $DRIVE/$ID.jsonl.gz cubre la sesión ($_lgz >= $_lsrc líneas) · nombre exportado: $NOMBRE_FINAL"
else
  echo "  (ya movido: el export de esta corrida no aplica; el .gz previo sigue siendo la capa 3)"
fi

# ── S4 · bloque ININTERRUMPIDO. Todo lo verificable se hizo ARRIBA; de aquí en adelante el diseño
#    es "no abortar donde continuar es inofensivo, y abortar solo donde es obligatorio", dejando
#    siempre el paso alcanzado en $ST para que la reanudación sea por ESTADO y no por adivinanza. ─
echo "── S4 move --git-branch + 2c + target/name (LOCK) + alias — BLOQUE ININTERRUMPIDO ──"
mkdir -p "$HOME/.claude/reubicar-backups"
if [ "$YA_MOVIDO" -eq 0 ]; then
  # respaldo PROPIO: sufijo distinto de *.jsonl.bak a propósito — pruneBackups() de session-move.js
  # SOLO poda *.jsonl.bak (conserva 10), así que esta copia no se recicla nunca.
  BK="$HOME/.claude/reubicar-backups/$ID.$(date +%s).pre-reubicar.jsonl"
  cp -f "$TGT_FILE" "$BK"
  cp -f "$MJ" "$DRIVE/masters.json.pre-reubicar-$ID.bak"
  LIN_ANTES="$(wc -l < "$TGT_FILE" | tr -d ' ')"
  echo "  respaldos: $BK  ·  $DRIVE/masters.json.pre-reubicar-$ID.bak  ·  $LIN_ANTES líneas de origen"
  echo "S4:pre-move" > "$ST"
  echo "  ⚠ PUNTO DE NO RETORNO: session-move.js copia al slug nuevo y hace unlink del origen."
  # `--git-branch` normaliza el gitBranch del ÚLTIMO evento con cwd en la MISMA pasada en streaming del
  # move: el re-anclaje del par (cwd, gitBranch) que hereda el próximo resume queda hecho ANTES del
  # unlink, sin una segunda lectura del archivo después de la mutación destructiva. Las ramas
  # HISTÓRICAS no se tocan (falsificaría el registro).
  node "$BIN/session-move.js" "$ID" --to-cwd "$DST_CWD" --git-branch "$RAMA_DST"
  echo "S4:moved" > "$ST"
  [ -f "$NEW_JSONL" ] || _abort "ABORTO: no se creó $NEW_JSONL (¿el slug derivado no coincide?)" \
    "  slug esperado: $NEW_SLUG   ·   restaura desde $BK (§ DESHACER) antes de reintentar."
  # validación por CONTENIDO, no por existencia: un detector [ -f "$NEW_JSONL" ] daría por hecho "S4"
  # con cualquier archivo en el destino. session-move.js publica con temp+verify+rename (nunca deja un
  # destino parcial visible); esto verifica SU resultado — defensa en profundidad, no desconfianza.
  LIN_DESPUES="$(wc -l < "$NEW_JSONL" | tr -d ' ')"
  [ "$LIN_DESPUES" -ge "$LIN_ANTES" ] \
    || _abort "ABORTO: el destino tiene $LIN_DESPUES líneas y el origen tenía $LIN_ANTES ⇒ escritura TRUNCADA" \
              "  NO reintentes el move (session-move.js se negará diciendo 'ya está en el slug destino')." \
              "  Restaura desde $BK (§ DESHACER) y vuelve a empezar."
  echo "  ok: $LIN_DESPUES líneas en el destino (>= $LIN_ANTES del origen)"
fi

# El move ya dejó el cwd uniforme y el par (cwd, gitBranch) del último evento re-anclado, en su propia
# pasada en streaming. Aquí solo se MIDE; si algo no cuadra (un `--git-branch` que no alcanzó a llegar
# al último evento, o un transcript que llegó ya contaminado a la reanudación) se REPARA con `_reancla`
# —también en streaming— y se re-mide. Un cwd ANIDADO (dentro de `toolUseResult`) no cuenta: `_cwds`
# solo ve el primer nivel, la misma vista que tiene el harness.
uniq_v="$(_cwds "$NEW_JSONL")"; uniq_n="$(_cwds_n "$NEW_JSONL")"
par="$(_ultimo_par "$NEW_JSONL")"
if [ "$uniq_n" -ne 1 ] || [ "$uniq_v" != "$DST_CWD" ] || [ "$par" != "$DST_CWD|$RAMA_DST" ]; then
  echo "  el move no dejó el re-anclaje completo (cwd=$uniq_n valores · último par='$par') ⇒ reparando"
  # Un re-anclaje que falla NO aborta aquí: estamos pasado el punto de no retorno y abortar ENTRE el
  # move y `masters.json` es exactamente el tail que este bloque existe para evitar. Se anota el estado,
  # se sigue hasta dejar el registro y el alias coherentes, y quien decide es `_postcondiciones` al
  # final — con el diagnóstico completo y sin haber dejado el ecosistema a medias.
  if _reancla; then
    uniq_v="$(_cwds "$NEW_JSONL")"; uniq_n="$(_cwds_n "$NEW_JSONL")"
  else
    echo "S4:reanclaje-fallido" > "$ST"
    echo "  ⚠ el re-anclaje NO pudo completarse. El transcript está intacto (se escribe a un temporal y"
    echo "    solo se publica si termina). SIGO hasta dejar masters.json y el alias coherentes; las"
    echo "    postcondiciones del final abortarán con el detalle. Después, re-corre este script."
  fi
fi
echo "  cwd de primer nivel: $uniq_n valor/es · último par: $(_ultimo_par "$NEW_JSONL")"

# S4-2c · el modo del transcript. El move CONSERVA el modo del ORIGEN, y el origen puede venir fuera de
# convención (verificado 2026-09-08: 1 de 131 en 644 donde el resto del slug está en 600) ⇒ se normaliza
# aquí. En Windows/NTFS es no-op y la postcondición se declara informativa en vez de fingirse.
echo "  S4-2c · chmod 600"
chmod 600 "$NEW_JSONL" 2>/dev/null || true

# S4 paso 3 · masters.json UPSERT, con el LOCK del ecosistema y ASERCIÓN de lectura-tras-escritura
echo "  S4 paso 3 · masters.json (UPSERT con lock)"
_mjlock="$MJ.lock"; _gotlock=0
for _i in 1 2 3 4 5 6 7 8 9 10; do
  if mkdir "$_mjlock" 2>/dev/null; then _gotlock=1; break; fi
  # un lock huérfano de un crash (>5 min) se recicla — mismo criterio que exportar-sesion-master.sh
  if [ -n "$(find "$_mjlock" -maxdepth 0 -mmin +5 2>/dev/null)" ]; then rm -rf "$_mjlock" 2>/dev/null || true; continue; fi
  sleep 2
done
if [ "$_gotlock" -ne 1 ]; then
  echo "S4:sin-lock-masters" > "$ST"
  _abort "ABORTO: no pude tomar $_mjlock en ~20s (otro master está escribiendo el registro)" \
         "  El transcript YA está movido. Re-corre este script: detecta el estado y continúa."
fi
_tmpm="$MJ.reubicar.tmp.$$"    # MISMO directorio que $MJ ⇒ el mv SÍ es un rename atómico
if ! jq --arg id "$ID" --arg t "$TARGET" --arg n "$NOMBRE_FINAL" '
      if ([.masters[]? | select(.id==$id)] | length) > 0
      then (.masters[] | select(.id==$id)) |= (.target = $t | .name = $n)
      else .masters = ((.masters // []) + [{id:$id, name:$n, target:$t}]) end' "$MJ" > "$_tmpm"; then
  rm -f "$_tmpm"; rmdir "$_mjlock" 2>/dev/null || true
  echo "S4:jq-masters-FALLO" > "$ST"
  _abort "ABORTO: el fix de masters.json FALLÓ (jq). El transcript YA está movido." \
         "  Respaldo del registro: $DRIVE/masters.json.pre-reubicar-$ID.bak" \
         "  Re-corre este script (detecta el estado y continúa)."
fi
mv -f "$_tmpm" "$MJ"
rmdir "$_mjlock" 2>/dev/null || true
echo "S4:masters-ok" > "$ST"

# S4 paso 4 · alias con el nombre FINAL (usa la lib, no editar a mano). El mapa es compartido: se
# fotografían las claves ajenas ANTES, y `_postcondiciones` asevera que ninguna se perdió.
echo "  S4 paso 4 · alias"
ALIAS_ANTES="$(_alias_keys)"
node -e 'require(process.argv[1]).writeAlias(process.argv[2],process.argv[3])' "$BIN/session-lib.js" "$ID" "$NOMBRE_FINAL"

# S4 paso 5 · residuo REAL del renombre (el alias no es un symlink: es un mapa JSON por id)
if [ -n "$MASTER_NAME_NUEVO" ] && [ "$MASTER_NAME_NUEVO" != "$MASTER_NAME" ]; then
  echo "  S4 paso 5 · residuo del renombre"
  echo "    otras entradas de masters.json con el nombre VIEJO (pueden ser de OTRA máquina — revisa, no borres a ciegas):"
  jq -r --arg n "$MASTER_NAME" '.masters[]|select(.name==$n)|"      \(.id)  target=\(.target)"' "$MJ" || true
  echo "    el meta.label del Drive se regeneró en S3 con '$NOMBRE_FINAL' (si no, un import revertiría el alias)"
  echo "    RECORDATORIO doc=realidad (S6): grep -rl '$MASTER_NAME' \"$DST/memory\" \"$DST_POSIX/$T2_ROOT\""
  echo "    y el customTitle del transcript sigue diciendo el nombre viejo: el hook re-deriva de ahí ⇒"
  echo "    renómbralo desde la sesión (el CLI escribe un evento custom-title nuevo, que es el que gana)."
fi

# ── S5 · depositar T2 SIN PISAR + barrido quirúrgico + CERO symlinks ────────────────────────────
echo "── S5 depositar T2 (con diff, sin pisar) + barrido quirúrgico ──"
TGZ="$DRIVE/$ID.brain-local.tgz"
if [ -f "$TGZ" ]; then
  _t2="$(mktemp -d)"; tar -C "$_t2" -xzf "$TGZ"
  find "$_t2" -type f -print > "$_t2.lista"
  _dst_de(){ if [ "$1" = "$T2_ROOT" ]; then printf '%s' "$DST_POSIX/$T2_ROOT"; else printf '%s' "$DST/memory/$1"; fi; }
  # ── El HILO no es identidad: su llave es (repo × stream), no (master) ──────────────────────────
  # `conocimiento-propio` y `autorizaciones-vigentes` son del MASTER: hay UNA copia buena y que difiera
  # es una anomalía que un humano debe reconciliar. El `hilo-mental-actual.md` NO: cada repo tiene el
  # suyo, el master escribe uno DISTINTO en cada repo donde trabaja (medido: 70 escrituras al de cortex
  # y 61 al de plantilladotnet, el MISMO master) y el destino casi siempre llega con uno propio y vivo.
  # Tratarlo como identidad convertía la mudanza en un merge manual de un archivo VOLÁTIL en el 100% de
  # los casos normales — un gate que dispara siempre no es un gate, es un peaje. Se CO-UBICA: el destino
  # conserva el suyo, el del master aterriza al lado con el nombre del master, y el PRIMER checkpoint
  # (que es quien tiene el criterio) los fusiona. Cero pérdida, cero pisada, cero abort.
  _es_hilo(){ case "${1##*/}" in hilo-mental-*) return 0 ;; *) return 1 ;; esac; }
  _co_ubicado(){ case "$1" in *.md) printf '%s.%s.md' "${1%.md}" "$NOMBRE_FINAL" ;; *) printf '%s.%s' "$1" "$NOMBRE_FINAL" ;; esac; }
  _hilos_co=""
  _conf=0
  while IFS= read -r _p; do
    _f="${_p#$_t2/}"; _d="$(_dst_de "$_f")"
    if [ -e "$_d" ] && ! diff -q "$_p" "$_d" >/dev/null 2>&1; then
      if _es_hilo "$_f"; then
        echo "    HILO distinto en el destino (ESPERADO: el hilo es del repo×stream) ⇒ se CO-UBICA como '$(_co_ubicado "$_f")'"
        echo "      el destino conserva el suyo; el 1er checkpoint del master FUSIONA lo que aplique"
        _hilos_co="$_hilos_co $(_co_ubicado "$_f")"
      else
        echo "    CONFLICTO T2: '$_f' existe DISTINTO en el destino ⇒ NO lo piso (misma regla que S1 para T1)"
        echo "      destino: $_d"; echo "      bundle : $_p"
        _conf=1
      fi
    fi
  done < "$_t2.lista"
  if [ "$_conf" -eq 1 ]; then
    echo "S5:conflicto-T2" > "$ST"
    _abort "ABORTO S5: T2 es IDENTIDAD y AUTORIZACIONES VIGENTES, y es gitignored ⇒ git NO lo puede recuperar." \
           "  Reconcilia a mano (diff + merge) y re-corre. El bundle extraído queda en $_t2"
  fi
  _bkt2="$HOME/.claude/reubicar-backups/$ID.$(date +%s).t2"; mkdir -p "$_bkt2"
  while IFS= read -r _p; do
    _f="${_p#$_t2/}"; _d="$(_dst_de "$_f")"
    # un HILO que difiere aterriza AL LADO del que ya vive en el destino, nunca encima
    if _es_hilo "$_f" && [ -e "$_d" ] && ! diff -q "$_p" "$_d" >/dev/null 2>&1; then
      _d="$(_dst_de "$(_co_ubicado "$_f")")"
    fi
    [ -e "$_d" ] && cp -a "$_d" "$_bkt2/" || true
    mkdir -p "$(dirname "$_d")"; cp -a "$_p" "$_d"
  done < "$_t2.lista"
  rm -rf "$_t2" "$_t2.lista"
  # idempotencia REAL: marcar el bundle como aplicado. Sin esto, re-correr el guion (lo que su propia
  # re-entrancia INVITA a hacer) re-extraía el tgz y REVERTÍA en silencio la edición de identidad de S6.
  mv -f "$TGZ" "$TGZ.aplicado"
  echo "    ok: T2 depositado · respaldo previo en $_bkt2 · bundle marcado .aplicado"
elif [ -f "$TGZ.aplicado" ]; then
  echo "    (T2 ya aplicado en una corrida previa: $TGZ.aplicado)"
else
  echo "    (sin bundle T2: S2 fue no-op o el destino ya lo trae — lo mide G-PARITY, §3)"
fi
# fuga: `git status --porcelain` NO lista ignorados ⇒ se exige el marcador !! por ARCHIVO
for _f in "$T2_ROOT" $(for m in ${T2_LOCAL[@]+"${T2_LOCAL[@]}"}; do printf '.claude/memory/%s\n' "$m"; done) \
           $(for m in ${_hilos_co:-}; do printf '.claude/memory/%s\n' "$m"; done); do
  [ -e "$DST_POSIX/$_f" ] || continue
  git -C "$DST_POSIX" check-ignore -q -- "$_f" || _abort "FUGA: '$_f' está en el destino y NO está ignorado ⇒ ABORTA"
  git -C "$DST_POSIX" ls-files --error-unmatch -- "$_f" >/dev/null 2>&1 \
    && _abort "FUGA: '$_f' YA está trackeado ⇒ git -C \"$DST_POSIX\" rm --cached -- '$_f'" || true
  echo "    ok: '$_f' presente e ignorado (!!)"
done
# barrido QUIRÚRGICO del slug COMPARTIDO: SOLO el <id>.jsonl. NUNCA el 'memory' del slug.
[ -f "$PROJ/$OLD_SLUG/$ID.jsonl" ] && rm -f "$PROJ/$OLD_SLUG/$ID.jsonl" || true
# ⛔ NO se crea symlink 'memory' en el slug NUEVO — decisión de unjordi (2026-09-08, textual):
#   "QUIERO QUE ESTO QUEDE SIN SIMLINKS. PUNTO" · "son un pinche bug que no logro que dejen de propagar"
# Si el bootstrap ya lo sembró, se RETIRA (solo el enlace: sin -r y sin slash final).
[ -L "$PROJ/$NEW_SLUG/memory" ] && { rm "$PROJ/$NEW_SLUG/memory"; echo "    retirado el symlink 'memory' del slug nuevo"; } || true
if [ -e "$PROJ/$OLD_SLUG/memory" ]; then
  echo "    nota: el slug VIEJO tiene 'memory' (canal per-máquina del SLUG, compartido por todas sus sesiones)."
  echo "      NO se mueve. Si el master guardaba algo SUYO ahí, cópialo al slug nuevo como DIRECTORIO REAL"
  echo "      (nunca symlink) — Decisión #7 de §7."
fi
echo "S5:ok" > "$ST"

_postcondiciones
rm -f "$ST"
echo ""
echo "✅ Pasos DESTRUCTIVOS verificados (esto NO es LISTO)."
echo "   FALTA (humano): claude --resume $ID  parado en  $DST_CWD   → QA de §S6"
echo "     identidad cargada · skills del destino + GLOBAL visibles · memorias T1∪T2 presentes ·"
echo "     T4: hooks tier-repo del destino disparando y outputStyle propio · masters.json y alias correctos."
echo "   Y DESPUÉS, OBLIGATORIO:  REUBICAR_MODO=s7 REUBICAR_QUIESCE_OK=1 bash \"$0\"   (§S7)"
HANDOFF_EOF

# ══════════════════════════════════════════════════════════════════════════════════════════════════
# EL CANDADO (arriba, una sola definición) + cómo correrlo
# ══════════════════════════════════════════════════════════════════════════════════════════════════
LC_ALL=C tr -d '\r' < "$H" > "$H.lf" && mv -f "$H.lf" "$H"    # LF forzado: el Drive sincroniza con Windows
chmod +x "$H"
_verificar_handoff "$H" "$PRELUDIO"

cat <<INSTRUCCIONES

Handoff: $H
Correrlo, en este orden (con la sesión $ID CERRADA y desde un SHELL PLANO):

  1) plan, sin mutar nada — SIEMPRE primero
     REUBICAR_MODO=dry bash "$H"

  2) los pasos destructivos (las dos citas humanas son GATES reales, no adorno)
     REUBICAR_LIVENESS_OK=1 REUBICAR_QUIESCE_OK=1 bash "$H" 2>&1 | tee "$H.\$(date +%s).log"

  3) QA funcional del humano — el ÚNICO sello de LISTO
     cd "$DST_POSIX" && claude --resume $ID

  4) re-verificar DESPUÉS del QA (obligatorio: un resume MUTA el transcript)
     REUBICAR_MODO=s7 REUBICAR_QUIESCE_OK=1 bash "$H"

INSTRUCCIONES

if [ "$CORRER_DRY" -eq 1 ]; then
  echo "── corriendo el dry-run (nada se muta) ──"
  REUBICAR_MODO=dry bash "$H"
fi
