#!/usr/bin/env bash
# nuevo-repo.sh — crea un proyecto GitLab NUEVO E INDEPENDIENTE sembrado desde un repo
# clonable canónico de la empresa, protege ramas, lo clona local y corre el bootstrap
# (instala tus convenciones + impone la norma). Mismo comando para humanos y para Claude.
#
# NO usa "fork" (deja relación con el upstream) ni "Create from template" (Premium en Free).
# Usa: crear proyecto vacío (glab/API) + `git push --mirror` del canónico = proyecto propio,
# con main+develop, sin relación de fork. Funciona en GitLab Free.
#
# Uso:
#   ./nuevo-repo.sh <grupo/nombre> [--from dotnet|vacio|<grupo/repo>] [--dir <ruta-local>]
# Ejemplos:
#   ./nuevo-repo.sh mx_pind_devops/potencia/mi-servicio            # default: dotnet
#   ./nuevo-repo.sh mx_pind_devops/potencia/algo --from vacio
#   ./nuevo-repo.sh mx_pind_devops/mx_megaflux_devops/x --dir ~/code/x
set -euo pipefail

DEST="${1:-}"; shift || true
FROM="dotnet"; DIR=""
while [ $# -gt 0 ]; do
    case "$1" in
        --from) FROM="${2:?}"; shift 2 ;;
        --dir)  DIR="${2:?}";  shift 2 ;;
        *) echo "arg desconocido: $1" >&2; exit 2 ;;
    esac
done
[ -n "$DEST" ] || { echo "uso: $0 <grupo/nombre> [--from dotnet|vacio|<grupo/repo>] [--dir <ruta>]" >&2; exit 2; }

# repo clonable canónico según --from
case "$FROM" in
    dotnet) SRC="mx_pind_devops/potencia/plantilladotnet" ;;
    vacio)  SRC="mx_pind_devops/plantillaRepoVacio" ;;
    */*)    SRC="$FROM" ;;
    *) echo "--from debe ser dotnet | vacio | <grupo/repo>" >&2; exit 2 ;;
esac
SRC_URL="git@gitlab.com:${SRC}.git"
DEST_URL="git@gitlab.com:${DEST}.git"
NAME="${DEST##*/}"
GROUP="${DEST%/*}"
DIR="${DIR:-$HOME/code/$NAME}"
HERE="$(cd "$(dirname "$0")" && pwd)"

echo "==> nuevo repo : $DEST   (desde: $SRC)"

# 1) crear el proyecto vacío en el grupo destino
GID="$(glab api "groups/$(printf '%s' "$GROUP" | sed 's#/#%2F#g')" | sed -n 's/.*"id":\([0-9]*\).*/\1/p' | head -1)"
[ -n "$GID" ] || { echo "no pude resolver el grupo '$GROUP'" >&2; exit 1; }
glab api --method POST projects -f "name=$NAME" -f "namespace_id=$GID" -f "visibility=private" \
    -f "initialize_with_readme=false" >/dev/null
echo "ok: proyecto creado ($DEST, grupo id $GID)"

# 2) sembrar con mirror del canónico -> proyecto INDEPENDIENTE (sin relación de fork), trae main+develop
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
git clone --bare -q "$SRC_URL" "$TMP/seed.git"
git -C "$TMP/seed.git" push -q --mirror "$DEST_URL"
echo "ok: sembrado desde $SRC (main+develop + tags)"

# 3) proteger ramas (failsafe universal, no depende del CI del template)
if [ -x "$HERE/proteger-ramas.sh" ]; then
    bash "$HERE/proteger-ramas.sh" "$DEST" || echo "warn: proteger-ramas.sh reportó problemas; revisa a mano"
else
    echo "warn: no encontré proteger-ramas.sh junto a este script; protege ramas a mano"
fi

# 4) clonar local + correr el bootstrap (instala convenciones + norma + enlaza cerebro)
if [ -e "$DIR" ]; then
    echo "warn: $DIR ya existe; no clono. Clónalo tú y corre .claude/bootstrap-claude.sh"
else
    git clone -q "$DEST_URL" "$DIR"
    echo "ok: clonado en $DIR"
    if [ -f "$DIR/.claude/bootstrap-claude.sh" ]; then
        ( cd "$DIR" && bash .claude/bootstrap-claude.sh ) && echo "ok: bootstrap corrido (convenciones + cerebro)"
    else
        echo "warn: el repo no trae .claude/bootstrap-claude.sh (¿el template lo tiene?)"
    fi
fi

echo "listo: $DEST creado, sembrado, protegido y clonado en $DIR."
echo "recuerda: trabaja en ramitas -> MR -> develop; main es release-only."
