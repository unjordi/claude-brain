#!/usr/bin/env bash
# sembrar-mini-develop.sh — siembra TU rama personal de integración ("mini-develop", convención
# Develop<Usuario>) en el repo actual y, si el remoto es GitLab, la PROTEGE server-side (push/merge =
# Developer, allow_force_push=true; al quedar protegida no es borrable por accidente — una mini-develop
# borrada ya costó trabajo real, 2026-07). Es el MECANISMO de la norma "Modelo MINI-DEVELOP" (toda
# norma nace con su mecanismo). SELF-SERVICE e idempotente: cada dev la corre UNA vez por repo; nadie
# siembra la mini de otro.
#
# Uso:  bash sembrar-mini-develop.sh [NombreRama]
#   Sin argumento deriva el nombre: Develop + git config user.name (sin espacios, capitalizado).
#   No toca tu worktree (crea la rama remota por refspec, sin checkout). Jamás usa develop/main como nombre.
set -u

ROOT="${CLAUDE_PROJECT_DIR:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"
git -C "$ROOT" rev-parse --git-dir >/dev/null 2>&1 || { echo "sembrar-mini-develop: aquí no hay repo git"; exit 1; }

BR="${1:-}"
if [ -z "$BR" ]; then
  base=$(git -C "$ROOT" config user.name 2>/dev/null | tr -d ' ')
  [ -n "$base" ] || base="${USER:-dev}"
  BR="Develop$(printf '%s' "$base" | awk '{print toupper(substr($0,1,1)) substr($0,2)}')"
fi
case "$BR" in develop|main|master) echo "sembrar-mini-develop: '$BR' es una rama base, no puede ser tu mini"; exit 1;; esac

git -C "$ROOT" fetch -q origin --prune 2>/dev/null || true

if git -C "$ROOT" show-ref --verify --quiet "refs/remotes/origin/$BR"; then
  echo "ok: la mini-develop '$BR' ya existe en el remoto (idempotente)"
else
  git -C "$ROOT" show-ref --verify --quiet refs/remotes/origin/develop \
    || { echo "sembrar-mini-develop: no existe origin/develop (siembra develop primero)"; exit 1; }
  # Crea la rama REMOTA desde origin/develop por refspec (sin tocar tu worktree ni tu rama actual).
  git -C "$ROOT" push -q origin "refs/remotes/origin/develop:refs/heads/$BR" \
    || { echo "sembrar-mini-develop: no pude crear '$BR' en el remoto"; exit 1; }
  git -C "$ROOT" fetch -q origin 2>/dev/null || true
  git -C "$ROOT" branch -q "$BR" "origin/$BR" 2>/dev/null || true   # ref local trackeando (si no existía)
  echo "ok: mini-develop '$BR' creada desde origin/develop y pusheada"
fi

# Protección server-side (GitLab): push/merge = Developer(30) + allow_force_push (tu mini es tuya:
# puedes reescribirla); protegida ⇒ NO borrable desde la web/CLI por accidente. En GitHub/otros, aviso.
url=$(git -C "$ROOT" remote get-url origin 2>/dev/null || echo "")
case "$url" in
  *gitlab*)
    if command -v glab >/dev/null 2>&1; then
      out=$(cd "$ROOT" && glab api "projects/:id/protected_branches" --method POST \
              -f "name=$BR" -f "push_access_level=30" -f "merge_access_level=30" \
              -f "allow_force_push=true" 2>&1) \
        && echo "ok: '$BR' PROTEGIDA server-side (push/merge=Developer, force-push ok, NO borrable)" \
        || { printf '%s' "$out" | grep -qiE "already|taken|protected" \
              && echo "ok: '$BR' ya estaba protegida (idempotente)" \
              || echo "aviso: no pude protegerla por API — hazlo en la web: Settings → Repository → Protected branches ($BR: push/merge=Developer)"; }
    else
      echo "aviso: sin glab en PATH — protege '$BR' en la web (Settings → Repository → Protected branches)"
    fi;;
  *github*) echo "aviso: remoto GitHub — la mini queda creada; la protección de rama ahí se configura aparte (Settings → Branches)";;
  *)        echo "aviso: remoto no reconocido — protege '$BR' manualmente si tu servidor lo soporta";;
esac
exit 0
