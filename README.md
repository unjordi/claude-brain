<sub>CLAUDE CODE · CEREBRO GLOBAL</sub>

# 🧠 claude-brain

[![CI](https://github.com/unjordi/claude-brain/actions/workflows/ci.yml/badge.svg)](https://github.com/unjordi/claude-brain/actions/workflows/ci.yml)
[![test-brain](https://img.shields.io/badge/test--brain-45%20verdes-3aa76d?style=flat-square)](brain/test-brain.sh)
[![plataformas](https://img.shields.io/badge/plataformas-macOS%20%C2%B7%20Linux%20%C2%B7%20Windows-4a90d9?style=flat-square)](#un-cerebro-tres-caras)
[![hooks](https://img.shields.io/badge/hooks-8%20globales%20%C2%B7%204%20por--repo-e8884a?style=flat-square)](#la-jerarqu%C3%ADa--de-inviolable-a-sugerencia-leve)
[![autoupdate](https://img.shields.io/badge/autoupdate-winturbo--style-d1702e?style=flat-square)](#lo-que-lo-hace-vivo--se-refleja-se-cura-se-actualiza)
[![licencia](https://img.shields.io/badge/licencia-MIT-555?style=flat-square)](LICENSE)

Los guardarraíles, la gobernanza y las normas de Claude Code, empaquetados en un cerebro que
**viaja por git** y **aplica en toda máquina** — con la cara de un widget que **se refleja, se cura
y se actualiza solo**.

Un `install-brain.sh` y tu máquina queda con el candado puesto. Idempotente y agnóstico de OS
(todo corre bajo **bash**: macOS, Linux, Windows/Git Bash).

|  |  |  |  |
|:--|:--|:--|:--|
| **8** · hooks globales | **4** · hooks por-repo | **45** · pruebas verdes | **3** · plataformas |

> El cerebro **no es propietario**: no trae skills de proyecto (ni .NET, ni repos de empresa) — solo
> hooks agnósticos, normas y una skill genérica `cerrar-slice` que cualquier proyecto puede adoptar.

## Instalar

```sh
git clone https://github.com/unjordi/claude-brain
cd claude-brain
./install.sh                 # cerebro + daemon de cuota + widget   (instalación maestra)
./install.sh --no-gui        # solo cerebro + daemon  (sin widget)
./install.sh --no-brain      # solo daemon + widget   (sin el cerebro)
```

Puerta de entrada por OS: **Linux / KDE Plasma 6** → `./install.sh` (raíz) · **macOS** →
[`macos/`](macos/) (`./install.sh`, mismos flags) · **Windows** → [`windows/`](windows/)
(`pwsh -File install.ps1`). **Prerrequisito de los guardias: [`jq`](https://jqlang.github.io/jq/)** —
sin él los hooks **fallan abierto** (no bloquean) y el instalador no cablea `settings.json`; en
Windows además necesitas Git for Windows (bash + coreutils).

## La jerarquía — de inviolable a sugerencia leve

El cerebro se ordena por *dureza*: arriba lo que te **bloquea** sin negociar; abajo lo que apenas
**sugiere**. Cada pieza sabe qué evento la dispara. Esta es, tal cual, la pestaña “Cerebro” del widget.

```
🔒 INVIOLABLE — hooks que BLOQUEAN (deny) · no negociables
├─ 🚧 git-branch-guard         push/merge a develop·main → denegado
├─ 🔗 merge-squash-guard       MR a develop sin --squash → denegado
├─ 🕵️  secret-scan             commit/push con un secreto → denegado
├─ ✋ confirmar-merge-develop   merge sin tu OK → denegado                 · por-repo
├─ ✅ dod-verificar            "listo" sin build+tests+memoria → denegado · por-repo
├─ 💸 delegacion-gate          reclutar agente con costo → pide tu OK
└─ 🛑 limite-gasto             gasto sobre el techo → freno duro

🔔 AUTOMÁTICO — inyectan / recuerdan (no bloquean)
├─ 🧭 sesion-inicio            reinyecta rama + norma + memoria al abrir   · por-repo
├─ 💾 precompact-volcar-estado vuelca el avance antes de compactar          · por-repo
├─ 📊 recordar-dashboard       recuerda actualizar el dashboard antes del push
├─ 🕰️  rama-vieja              avisa si la ramita arrastra base vieja
└─ 📝 delegacion-registrar     materializa el "pregunta una sola vez"

📜 NORMAS — reglas que Claude se autoimpone (CLAUDE.md)
├─ 🎯 Definición de LISTO      verde técnico ≠ listo; exige tu QA o tu OK
├─ 🪞 Doc = realidad           cambió algo → su doc se actualiza en la tanda
├─ 🌿 Flujo de git             ramita → MR → develop; main es release-only
└─ 💰 Costo de delegación      gratis / incluido / con costo, según tu cuota

💡 SKILLS — opt-in, las invocas tú
└─ 📦 cerrar-slice             build+tests+memoria al día + MR con resumen curado
```

Los hooks **por-repo** son fuente en [`brain/hooks/`](brain/hooks/) que cada repo copia a su propio
`.claude/` y cablea en su `settings.json` — se cargan solo cuando una sesión *inicia* en ese repo. El
cerebro **se autoprueba**: [`brain/test-brain.sh`](brain/test-brain.sh) corre 45 checks contra un
`$HOME` aislado, y la CI repite `bash -n` + `jq empty` + `shellcheck` en cada push.

## Lo que lo hace vivo — se refleja, se cura, se actualiza

El widget no dibuja un póster estático: **lee tu `~/.claude` real** y actúa sobre lo que encuentra.

<p align="center"><img src="screenshots/cerebro.png" alt="La pestaña Cerebro" width="360"></p>

- **🪞 Se refleja** — lee qué hooks están presentes y cableados, qué normas y skills tienes, y pinta
  el estado real de cada pieza. De cara al usuario, binario: **verde = bien, rojo = falta algo**.
- **🩹 Se cura** — ¿falta una pieza? Un botón corre el `install-brain.sh` empaquetado en la app y
  re-lee — el cerebro se completa solo, sin abrir la terminal.
- **⬆️ Se actualiza** — cada build embebe su versión, consulta `commits/main` en GitHub y ofrece un
  banner que hace **fast-forward y reinstala**. Fail-open, y **nunca te deja sin widget**.

## El widget — la cara del cerebro

Un daemon en segundo plano consulta el endpoint OAuth `/usage` de Anthropic y una GUI nativa muestra
una píldora de color (verde → ámbar → rojo conforme te acercas al tope); clic para el desglose. Los
mismos datos que `/usage`, en tu escritorio, desde cualquier lado. Las pestañas comparten el riel:

| | |
|---|---|
| ![Resumen](screenshots/resumen.png) | ![Límites](screenshots/limites.png) |
| **Resumen** — sesiones, mensajes, tokens, rachas, hora pico, modelo favorito, costo API-equiv y el heatmap diario. | **Límites** — ventana de 5 h y semanal, caps por-modelo, y el **gasto real de bolsillo** (spend / overage). |
| ![Modelos](screenshots/modelos.png) | ![Proyectos](screenshots/proyectos.png) |
| **Modelos** — barras apiladas por día + una fila por modelo (tokens in/out, %). | **Proyectos** — barras apiladas por día + una fila por carpeta de proyecto (tokens in/out, %). |

## Cómo funciona

`./install.sh` es un solo instalador maestro idempotente; el daemon y el widget van
**intencionalmente separados**; la pestaña **Cerebro** es el puente de vuelta al cerebro:

```
  ┌────────────────────────────────────────────────────────────────┐
  │  ./install.sh   —  un solo instalador maestro, idempotente       │
  └──────────────┬─────────────────────────────────┬────────────────┘
                 │ cerebro (install-brain.sh)       │ daemon + widget
                 ▼                                  ▼
  ┌───────────────────────────┐   ┌────────────────────────────────┐
  │  ~/.claude   (EL CEREBRO)  │   │  claude-quota-fetch (daemon)   │
  │  hooks/ · settings.json    │   │  systemd / launchd · piso 5 min │
  │  CLAUDE.md · skills/       │   │  bash + jq + curl(OAuth) +ccusage│
  └───────────▲───────────────┘   └────────────────┬───────────────┘
              │ refleja + cura 🩹                   │ escribe
              │  (install-brain.sh)                 ▼
              │                    ┌────────────────────────────────┐
              │                    │  ~/.cache/claude-quota/         │
              │                    │    state.json · stats.json      │
              │                    └────────────────┬───────────────┘
              │                                     │ lee cada 10 s
  ┌───────────┴─────────────────────────────────────▼──────────────┐
  │  EL WIDGET  (la cara del cerebro)  —  KDE · macOS · Windows      │
  │  píldora  +  popup: Límites · Resumen · Modelos · Proyectos · 🧠  │
  │  🧠 Cerebro refleja el cerebro · 🩹 lo cura · ⬆ se autoactualiza  │
  └─────────────────────────────────────────────────────────────────┘
              ▲ autoupdate:  mira GitHub main  →  git ff + reinstala
```

El **timer impone el piso de 5 min** a nivel del OS (la API de Anthropic avisa si sondeas de más), así
que es la única fuente de cadencia. El widget es una vista pura de `state.json`/`stats.json` (re-leída
cada 10 s), salvo la pestaña Cerebro, que lee `~/.claude` directo para reflejar el cerebro.

**Los porcentajes** salen del endpoint OAuth `/usage` (idénticos a `/usage`, `basis:"oauth"`); sin red
o sin credenciales, caen a una estimación calibrada desde los transcripts locales vía
[ccusage](https://github.com/ryoppippi/ccusage) (`basis:"cost"`). Los montos en dólares son costo
**API-equivalente** (lo que pagarías por token), no tu factura — una señal de "cuánto me ahorra el plan".

## Un cerebro, tres caras

El mismo cerebro y la misma pestaña, nativos en cada sistema — porque los guardarraíles no deben
depender de en qué te toque trabajar.

| OS | GUI | Detalle |
|---|---|---|
| 🍎 **macOS** | app de barra de menú (Swift) | [`macos/README.md`](macos/README.md) — agente `launchd` |
| 🐧 **Linux** | widget KDE Plasma 6 (QML) | [`src/README.md`](src/README.md) — timer `systemd --user`, ajustes y diagnóstico |
| 🪟 **Windows** | app de bandeja (WinForms, .NET) | [`windows/README.md`](windows/README.md) — `.exe` self-contained, sin bash/jq |

## Contribuir al cerebro

Sumar un guardrail o cortar un release está documentado en las skills del repo:
[`agregar-hook-cerebro`](.claude/skills/agregar-hook-cerebro/SKILL.md) y
[`publicar-widget`](.claude/skills/publicar-widget/SKILL.md).

## Desinstalar

```sh
just uninstall                   # widget + daemon
bash brain/uninstall-brain.sh    # el cerebro (idempotente; conserva tus datos)
```

`uninstall-brain.sh` quita los hooks globales, la config, la skill y el bloque de normas de
`~/.claude/CLAUDE.md`, y des-cablea de `settings.json` solo sus propias entradas — nunca toca tu
memoria, dashboard ni registro de consentimiento.

## Créditos

Nació de [`fuziontech/claude-quota-widget`](https://github.com/fuziontech/claude-quota-widget) (MIT),
restyleado según [`FelixDes/claude-kde-usage-widget`](https://github.com/FelixDes/claude-kde-usage-widget),
y luego crecido de "un widget de cuota" a "un cerebro portable de Claude Code con cara de widget".
Licencia **MIT** (ver [LICENSE](LICENSE); copyright original de fuziontech, conservado).
