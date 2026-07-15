# Dashboard del cerebro — <MAQUINA> (memoria GLOBAL de esta compu)

> Para que Claude sepa QUE hay y DONDE, sin adivinar. La memoria GLOBAL es config de ESTA
> maquina; el cerebro de cada proyecto vive en su <repo>/.claude/. Se actualiza en CADA push
> (hook recordar-dashboard.sh): APPENDEA una linea al FINAL de la Bitacora (con `>>`, no editando
> arriba) + ajusta Mapa/Infra/Cabos sueltos. El append-al-final es lo que evita chocar con otras
> sesiones de Claude que escriben este mismo archivo a la vez (dos `>>` no se pisan; un Edit si).

## Mapa — repos y donde vive su cerebro
| Repo | Que es | Remoto | Cerebro |
|---|---|---|---|
| <repo> | <que es> | <remoto> | <.claude/ ...> |

## Infra clave (donde estan las cosas)
- Runner CI/CD: <...>
- Repo nuevo: forkear <tu-repo-plantilla> -> proteger-ramas.sh -> bootstrap-claude.sh
- Guards: ~/.claude/hooks/git-branch-guard.sh + recordar-dashboard.sh

## Cabos sueltos / pendientes
- <...>

## Bitacora (mas reciente ABAJO — appendea al final con `>>`, append-safe entre sesiones)
- <YYYY-MM-DD> — <entrada>
