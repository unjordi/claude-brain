# 🐧 claude-brain — widget de Linux (KDE Plasma 6)

El plasmoide QML del widget de cuota + los detalles operativos específicos de Linux. El panorama
general (el cerebro, las 3 plataformas, cómo funciona) vive en el [README raíz](../README.md); aquí
va lo fino de KDE.

## Instalar

**Autocontenido (jala las deps solo — recomendado):**

```sh
curl -fsSL https://raw.githubusercontent.com/unjordi/claude-brain/main/bootstrap.sh | bash
# variantes: … | bash -s -- --no-gui   (cerebro+daemon, sin widget)
#            … | bash -s -- --no-brain (daemon+widget, sin cerebro)
```

El `bootstrap.sh` instala lo que falte (`git`, `jq`, `node`) con tu gestor de paquetes, clona el
repo en `~/claude-brain` y corre `install.sh`. **O a mano** (si ya tienes los prereqs):

> El widget mide **Claude Code (el CLI `claude`)**: el instalador también lo instala (sáltalo con
> `--no-claude-code`), pero el **login es tuyo** — corre `claude` y `/login` una vez, o el widget solo
> muestra el fallback calibrado.

```sh
git clone https://github.com/unjordi/claude-brain
cd claude-brain
./install.sh                 # cerebro + daemon + widget KDE
./install.sh --no-gui        # cerebro + daemon (sin widget)
./install.sh --no-brain      # daemon + widget (sin cerebro)
```

Luego en Plasma: clic derecho en el panel → **Agregar o administrar widgets…** → busca
**"Claude Code Quota"** → arrástralo al panel.

**Prerrequisitos:** KDE Plasma 6, `jq` (normalización JSON), y `npm` para instalar `ccusage` (el
instalador corre `npm i -g ccusage`; si ya lo tienes en `PATH` se usa directo; con `--no-ccusage` cae
a `npx -y ccusage@latest` en cada corrida, ~7 s más lento).

## Arquitectura (Linux)

El daemon es un `systemd --user` timer que **impone un piso de refresco de 5 min** (`OnUnitActiveSec=5min`,
`Persistent=true`) — la API de Anthropic avisa si sondeas de más, así que el timer es la única fuente
de cadencia. El plasmoide es vista pura: lee `~/.cache/claude-quota/state.json` cada 10 s y renderiza.

## Ajustar los caps del fallback (solo importa offline)

Con el endpoint OAuth alcanzable los porcentajes son exactos y **no hay que ajustar nada**. Para el
fallback offline, pon cada cap en USD en `~/.config/claude-quota/limits.env` como *"$ usado" del popup
÷ la fracción de `/usage`*, y `systemctl --user restart claude-quota.service`.

| Plan | `FIVE_HOUR_CAP_USD` | `WEEKLY_CAP_USD` |
|---|---|---|
| Pro | 2.5 | 250 |
| Max 5x | 11 | 1,200 |
| Max 20x | 45 | 4,800 |

## La pestaña "Proyectos" — nombres y alias

El fetch agrega el uso por proyecto desde `~/.claude/projects/<slug>/` y **normaliza** cada slug a un
nombre canónico: subdirectorios y worktrees bajo un repo conocido (de `.projects` en `~/.claude.json`)
**se fusionan con ese repo** (longest-prefix en frontera de segmento, así `-Users-me-code-cps-cpscsmWasm`
→ `cps`); worktrees efímeros de `/tmp` colapsan en un bucket **`(worktrees)`**; lo demás cae al **último
segmento** del path. Para renombrar un proyecto canónico, deja un mapa en `~/.claude/proyectos-alias.json`
(`cp brain/proyectos-alias.example.json …`), aplicado después de normalizar. El archivo es opcional.

## Diagnóstico

```sh
just status   # ¿corre el timer? ¿último fetch?
just logs     # sigue el journal del servicio de fetch
just refresh  # fuerza un fetch ya e imprime el resultado
```

- **Píldora gris con `…`** — el caché aún no se escribe; el primer fetch tarda mientras `ccusage` arranca en frío.
- **`error: cat rc=1`** — el fetch tronó (`journalctl --user -u claude-quota.service`); normalmente falta `jq`/`ccusage`.
- **Porcentajes lejos de `/usage`** — `jq .basis ~/.cache/claude-quota/state.json`: `"cost"` = el endpoint OAuth no es alcanzable (¿credenciales? ¿en línea?) y estás en el fallback; `"oauth"` = viene de Anthropic y debe coincidir.
- **Widget en blanco en el panel** — reinicia plasmashell una vez: `just reload-plasmashell`.

## Desarrollo

```sh
just test-brain           # las 45 pruebas del cerebro (contra un $HOME falso)
just upgrade-plasmoid      # reconstruye + reinstala el plasmoide tras editar main.qml
just reload-plasmashell    # reinicia plasmashell para tomar cambios
just lint                  # shellcheck a los scripts bash
just package               # arma dist/claude-quota-widget-X.Y.Z.plasmoid
```

## Desinstalar

```sh
just uninstall              # widget + daemon
just uninstall-keep-cfg     # conserva ~/.config/claude-quota/limits.env
bash ../brain/uninstall-brain.sh   # el cerebro (idempotente; conserva tus datos)
```
