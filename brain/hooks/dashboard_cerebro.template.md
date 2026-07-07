# Dashboard del cerebro — <MAQUINA> (memoria GLOBAL de esta compu)

> Para que Claude sepa QUE hay y DONDE, sin adivinar. La memoria GLOBAL es config de ESTA
> maquina; el cerebro de cada proyecto vive en su <repo>/.claude/. Se actualiza en CADA push
> (hook recordar-dashboard.sh): linea a la Bitacora + ajusta Mapa/Infra/Cabos sueltos.

## Mapa — repos y donde vive su cerebro
| Repo | Que es | Remoto | Cerebro |
|---|---|---|---|
| <repo> | <que es> | <remoto> | <.claude/ ...> |

## Infra clave (donde estan las cosas)
- Runner CI/CD: <...>
- Repo nuevo: forkear <plantilla> -> proteger-ramas.sh -> bootstrap-claude.sh
- Guards: ~/.claude/hooks/git-branch-guard.sh + recordar-dashboard.sh

## Cabos sueltos / pendientes
- <...>

## Bitacora (lo mas reciente arriba)
- <YYYY-MM-DD> — <entrada>
