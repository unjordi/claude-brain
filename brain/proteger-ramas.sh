#!/usr/bin/env bash
# proteger-ramas.sh <grupo/subgrupo/repo | id> — aplica la NORMA DE RAMAS a UN repo GitLab:
#   - crea `develop` desde la rama default si falta
#   - protege default + develop: push=nadie (0), merge=Maintainer (40), sin force-push
# Usa la auth LOCAL de glab (no requiere token en CI, sin caducidad). Idempotente.
# Correr al crear/abrir un repo nuevo (el "failsafe" de la norma).
export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
set +e

PROJ="$1"
[ -z "$PROJ" ] && { echo "uso: proteger-ramas.sh <grupo/subgrupo/repo | id>"; exit 1; }
ENC=$(printf '%s' "$PROJ" | sed 's|/|%2F|g')
id=$(glab api "projects/$ENC" 2>/dev/null | jq -r '.id // empty')
[ -z "$id" ] && { echo "✗ no encontré el proyecto: $PROJ"; exit 1; }
def=$(glab api "projects/$id" 2>/dev/null | jq -r '.default_branch // "main"')
echo "proyecto: $PROJ (id $id), default=$def"

if ! glab api "projects/$id/repository/branches/develop" >/dev/null 2>&1; then
  glab api --method POST "projects/$id/repository/branches?branch=develop&ref=$def" >/dev/null 2>&1 \
    && echo "  ✓ develop creada desde $def" || echo "  ✗ no pude crear develop"
else
  echo "  = develop ya existe"
fi

for b in "$def" develop; do
  glab api --method DELETE "projects/$id/protected_branches/$b" >/dev/null 2>&1
  glab api --method POST "projects/$id/protected_branches?name=$b&push_access_level=0&merge_access_level=40&allow_force_push=false" >/dev/null 2>&1 \
    && echo "  🔒 protegida: $b (push=nadie, merge=Maintainer)" || echo "  ✗ falló proteger $b"
done
echo "norma de ramas aplicada a $PROJ."