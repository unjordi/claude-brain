---
name: publicar-widget
description: >
  Publica un cambio del widget/cerebro claude-brain por el flujo de git del equipo —
  ramita → MR → develop (squash) → release a main (merge-commit) — y esquiva los gotchas
  reales (guard de squash cacheado que bloquea el CLI a main, conflicto de rebase tras un
  squash, y el autoupdate por version.json). Úsalo para cerrar/soltar cualquier slice del repo.
---

# publicar-widget — flujo de release del widget/cerebro (con gotchas)

Repo `github.com/unjordi/claude-brain` (GitHub). Norma dura: **NUNCA push a develop/main**; todo
por ramita → PR. Al integrar a develop se **SQUASHEA**; los releases a main van **SIN squash**.

## Flujo normal (a develop)
```
git checkout -b feat/<tema> origin/develop     # SIEMPRE desde develop ACTUALIZADO
# … commits en la ramita (libres, sin preguntar) …
git push -u origin feat/<tema>
gh pr create --repo unjordi/claude-brain --base develop --head feat/<tema> --title … --body …
gh pr merge <n> --repo unjordi/claude-brain --squash --delete-branch
```
El **merge a develop necesita el OK EXPLÍCITO de unjordi** (lo exige el flujo y el hook
`confirmar-merge-develop`); los commits/push a la ramita NO.

## Release a main (decisión deliberada de unjordi)
PR `develop → main` y **"Create a merge commit" (NO squash)** para conservar historia.
- **GOTCHA (cacheado):** el `merge-squash-guard` que se cargó al INICIAR la sesión puede ser el
  viejo (pre-target-aware) y **bloquea el `gh pr merge` a main por CLI** exigiendo `--squash` (que
  un release NO usa). → **Hazlo en la WEB** (botón Merge → "Create a merge commit"). En una sesión
  NUEVA, el guard target-aware ya cargado permite el CLI. Los hooks se snapshotean al iniciar sesión.
- Deja el PR creado por CLI (`gh pr create --base main`) y pásale el link a unjordi para el clic.

## GOTCHA: conflicto de rebase tras un squash
Si squasheaste una ramita a develop y SIGUES trabajando en esa MISMA ramita para el siguiente slice,
el próximo MR a develop **choca** (mismos cambios, historias divergentes: develop los tiene squasheados,
tu ramita como commits sueltos). Solución limpia (sin resolver conflictos a mano):
```
git checkout -B feat/<nuevo> origin/develop
git checkout <ramita-vieja> -- .          # trae el árbol final (si es superset de develop)
git commit -m "…"                          # 1 commit sin conflicto
```
Verifica el superset con `git diff <ramita>..origin/develop --stat` (debe ser el espejo inverso del
`origin/develop..<ramita>`). LECCIÓN: tras squashear, **ramifica de develop actualizado**, no sigas en la vieja.

## Autoupdate (version.json) — por qué importa al publicar
Las 3 GUIs embeben `version.json` (sha+fecha+repo) al buildear/instalar (`macos/make-app.sh`,
`install.sh` en el empaquetado del plasmoid, `windows/install.ps1`). El widget consulta `commits/main`
y ofrece un banner "Actualizar widget" que hace **ff a origin/main + reinstala**. Por eso el
**self-update solo es real desde un release a main** (el clon del usuario debe estar limpio en main):
un build de dev (ramita, árbol sucio) muestra el banner pero el ff aborta a salvo. Suelta releases a
main para que el autoupdate llegue a la gente.

## Reinstalar para QA (macOS)
```
bash macos/install.sh --no-brain      # rebuild + reinstala (NO corre el instalador del cerebro)
pkill -f "Claude Quota.app/Contents/MacOS/ClaudeQuota"; sleep 2
open "/Users/unjordi/Applications/Claude Quota.app"
```
`--no-brain` = solo widget/daemon (no toca `~/.claude`). El QA visual de unjordi es el sello final;
verde técnico (build/tests) es necesario pero **no** suficiente (definición de LISTO).

## Cierre
Usa la skill genérica `cerrar-slice` del cerebro (build+tests+memoria+MR+cosecha). Actualiza el
dashboard global (`dashboard_cerebro.md`) en la misma tanda del push (lo recuerda `recordar-dashboard`).
Para sumar un guardrail nuevo, ver `agregar-hook-cerebro`.
