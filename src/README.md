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
repo en `~/.claude-brain` (oculto, no ensucia tu `$HOME`) y corre `install.sh`. **O a mano** (si ya
tienes los prereqs):

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

El instalador **recarga plasmashell al terminar** (para que tome el plasmoide nuevo — actualizar el
paquete no refresca la instancia viva); el panel parpadea ~1 s. Sáltalo con `--no-reload-shell` (p. ej.
por SSH/headless). Luego en Plasma: clic derecho en el panel → **Agregar o administrar widgets…** → busca
**"Claude Brain Widget"** → arrástralo al panel.

**Prerrequisitos:** KDE Plasma 6, `jq` (normalización JSON), y `npm` para instalar `ccusage` (el
instalador corre `npm i -g ccusage`; si ya lo tienes en `PATH` se usa directo; con `--no-ccusage` cae
a `npx -y ccusage@latest` en cada corrida, ~7 s más lento).

## Arquitectura (Linux)

El daemon es un `systemd --user` timer que **impone un piso de refresco de 5 min** (`OnUnitActiveSec=5min`,
`Persistent=true`) — la API de Anthropic avisa si sondeas de más, así que el timer es la única fuente
de cadencia. El plasmoide es vista pura: lee `~/.cache/claude-brain/state.json` cada 10 s y renderiza.

## Ajustar los caps del fallback (solo importa offline)

Con el endpoint OAuth alcanzable los porcentajes son exactos y **no hay que ajustar nada**. Para el
fallback offline, pon cada cap en USD en `~/.config/claude-brain/limits.env` como *"$ usado" del popup
÷ la fracción de `/usage`*, y `systemctl --user restart claude-brain.service`.

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

**Renombrar desde el widget (clic-secundario).** No hace falta editar el JSON a mano: **clic-secundario
sobre una fila de proyecto** abre un menú con **"Renombrar…"** (y **"Restaurar original"** si ya tiene
alias). El widget escribe `~/.claude/proyectos-alias.json` (llaves ordenadas, para diff limpio) y dispara
un refetch, así el nombre nuevo aparece solo. Vacío = revertir al canónico. La llave canónica se resuelve
sola: si la fila ya muestra un alias, se reescribe esa entrada, no se crea una nueva. Respeta
`CLAUDE_CONFIG_DIR` (base = ese dir o `~/.claude`).

Cada fila de proyecto con **sesiones de Claude Code** trae un chevron (▸): despliégala para ver sus
sesiones recientes (de `sessions.json`, máx 12) y **haz clic en una para "resumirla"** — abre una
terminal en su `cwd` y corre `claude --resume <id>`. En Linux se intenta la primera terminal
disponible en cascada: `konsole` (KDE) → `x-terminal-emulator` (default Debian/Ubuntu) →
`gnome-terminal` → `xterm`. **Clic-secundario sobre una sesión** ofrece el mismo "Renombrar…" /
"Restaurar original": escribe `~/.claude/sesiones-alias.json` con llave = `id` de la sesión (estable),
que `sessions-extract.js` lee para sustituir la etiqueta derivada del transcript.

## Filtro de rango {hoy · 7d · 30d · ∞}

Al pie de **Resumen / Modelos / Proyectos / Chats** hay 4 píldoras de rango; la activa va en acento.
Recortan los datos a **hoy**, **últimos 7 días**, **últimos 30 días** o **∞** (todo el histórico,
default). El corte filtra `stats.days[]` por fecha local y recalcula tarjetas, tablas y gráficas
apiladas sobre esos días (reescaladas a su propio máximo). El **heatmap** de Resumen se queda
all-time; **Racha** y **Hora pico** también (son métricas de todo el histórico). A ∞ todo coincide
con lo que se mostraba antes del filtro.

## Toggle 🖥 / ☁️ — esta máquina vs. todas (sync)

A la derecha del footer de rango de **Resumen / Modelos / Proyectos** aparece —**solo si hay sync
activo**— un par de píldoras: **🖥 esta máquina** (default) y **☁️ todas** (con el número de máquinas
si hay más de una). Al elegir ☁️ los recomputes de rango (tarjetas, tablas y gráficas) leen de
`~/.cache/claude-brain/stats-global.json` en vez del `stats.json` local — la vista **combinada de
todas tus máquinas** que produce el bloque *(e) Sync* del fetch al fusionar los snapshots depositados
en la carpeta de nube. **Conteo de sesiones, Chats, heatmap, Racha y Hora pico se quedan siempre
locales.** Si no existe `stats-global.json` (sync apagado) el toggle no se muestra (fail-open), y no
aparece en **Chats**.

## La pestaña "Chats" (solo si hay conversaciones locales)

Lee `~/.cache/claude-brain/chats.json` (lo produce el fetch con `chats-extract.js`, leyendo el caché
local del app de escritorio de Claude **sin red ni cookies**). Muestra el desglose por modelo
(swatch + modelo + conteo + %) y la lista de recientes (título + badge de modelo + fecha relativa);
al pasar el cursor sobre un chat, su resumen sale en el pie. Es **read-only** (no abre el chat: no
hay deep-link fiable). El riel **solo muestra la pestaña si hay chats** (sin app de escritorio o sin
`node` no hay `chats.json` y la pestaña no aparece — fail-open).

## Diagnóstico

```sh
just status   # ¿corre el timer? ¿último fetch?
just logs     # sigue el journal del servicio de fetch
just refresh  # fuerza un fetch ya e imprime el resultado
```

- **Píldora gris con `…`** — el caché aún no se escribe; el primer fetch tarda mientras `ccusage` arranca en frío.
- **`error: cat rc=1`** — el fetch tronó (`journalctl --user -u claude-brain.service`); normalmente falta `jq`/`ccusage`.
- **Porcentajes lejos de `/usage`** — `jq .basis ~/.cache/claude-brain/state.json`: `"cost"` = el endpoint OAuth no es alcanzable (¿credenciales? ¿en línea?) y estás en el fallback; `"oauth"` = viene de Anthropic y debe coincidir.
- **Widget en blanco en el panel** — reinicia plasmashell una vez: `just reload-plasmashell`.

## Desarrollo

```sh
just test-brain           # las 45 pruebas del cerebro (contra un $HOME falso)
just upgrade-plasmoid      # reconstruye + reinstala el plasmoide tras editar main.qml
just reload-plasmashell    # reinicia plasmashell para tomar cambios
just lint                  # shellcheck a los scripts bash
just package               # arma dist/claude-brain-X.Y.Z.plasmoid
```

## Desinstalar

```sh
just uninstall              # widget + daemon
just uninstall-keep-cfg     # conserva ~/.config/claude-brain/limits.env
bash ../brain/uninstall-brain.sh   # el cerebro (idempotente; conserva tus datos)
```
