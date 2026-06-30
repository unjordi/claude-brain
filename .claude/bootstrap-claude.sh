#!/usr/bin/env bash
# bootstrap-claude.sh — enlaza el "cerebro" (memory/) de ESTE repo al lugar donde
# Claude Code lo busca por slug. Córrelo UNA vez tras `git clone`. Re-correrlo es seguro.
#
# Cópialo a <repo>/.claude/bootstrap-claude.sh y commitéalo (skill: claude-proyecto-autocontenido).
set -eu

# Raíz del repo = el dir padre de este script (vive en <repo>/.claude/).
# OJO: rutas LÓGICAS (pwd sin -P), no físicas. Claude Code calcula el slug con la ruta tal
# cual la ve el shell ($PWD), SIN resolver symlinks. En macOS (iCloud/Drive bajo symlinks)
# resolverlos con -P daría un slug distinto al de CC y enlazaría el dir equivocado.
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$SCRIPT_DIR/.." && pwd)"
TARGET="$REPO/.claude/memory"                       # memoria real, versionada

# Slug = ruta absoluta del repo con [^a-zA-Z0-9] -> '-'  (lo calcula CADA máquina)
SLUG="$(printf '%s' "$REPO" | sed 's/[^a-zA-Z0-9]/-/g')"
PROJ_DIR="$HOME/.claude/projects/$SLUG"
LINK="$PROJ_DIR/memory"

echo "repo : $REPO"
echo "slug : $SLUG"
echo "       (ojéalo: debe coincidir con el dir que CC tiene en ~/.claude/projects/)"

mkdir -p "$PROJ_DIR" "$TARGET"

# Ya enlazado correctamente -> nada que hacer
if [ -L "$LINK" ] && [ "$(readlink "$LINK")" = "$TARGET" ]; then
    echo "ok: memory ya apunta a $TARGET"
    exit 0
fi

# Había algo en el slug (dir real con notas, o symlink viejo) -> apártalo, no lo pierdas
if [ -e "$LINK" ] || [ -L "$LINK" ]; then
    BAK="$LINK.bak-$(date +%Y%m%d%H%M%S)"
    mv "$LINK" "$BAK"
    echo "warn: había memory previo -> respaldado en $BAK (revisa si guardaba notas tuyas)"
fi

ln -s "$TARGET" "$LINK"
echo "ok: enlazado $LINK -> $TARGET"
echo "    (skills/ y settings.json los lee CC solo al abrirse desde $REPO)"
