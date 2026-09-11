# `brain/` — el cerebro global compartible de Claude Code (doc interna)

Esta carpeta **es** el cerebro: los guardrails, la gobernanza de costo de delegación, la definición
de "LISTO", las normas de git del equipo y una skill genérica de cierre. Todo es **agnóstico de
stack** (no trae nada de .NET ni de repos de la empresa) para que cualquier proyecto lo adopte.

Doc para **contribuidores del cerebro**. El README de la raíz es para *usuarios* (instalar el widget
+ el cerebro); este explica las piezas por dentro, cómo probarlas y cómo instalar/desinstalar.

Todos los hooks corren bajo **bash** en Mac/Linux/Windows (Git Bash) — un solo juego de `.sh`, sin
drift `.sh`/`.ps1`. Dependen de **`jq`**; sin `jq` fallan **abierto** (no bloquean) y el instalador
no puede cablear `settings.json`.

## Layout

```
brain/
├── install-brain.sh      # instalador GLOBAL idempotente (hooks + cableado + skill + dashboard + normas + aliases-activos)
├── install-brain.ps1     # lanzador Windows: verifica bash+jq, detecta aliases de PowerShell (nativo) y delega en install-brain.sh
├── uninstall-brain.sh    # inverso EXACTO del instalador (idempotente)
├── test-brain.sh         # pruebas versionadas y repetibles (contra un $HOME falso aislado)
├── README.md             # este archivo
├── hooks/                # los hooks .sh + libs sourceables + agentes-costo.json + dashboard_cerebro.template.md
├── lib/                  # libs de INSTALACIÓN (sourceables, NO hooks): detectar-shells.sh (aliases cross-shell)
├── skills/               # skills genéricas: cerrar-slice, orquestar-fanout, checkpoint, rehidratar-hilo, turno-nocturno (SKILL.md c/u)
└── norms/global-claude-md.md  # bloque de normas que se inyecta en ~/.claude/CLAUDE.md
```

**Artefacto LEAN de aliases (`~/.claude/aliases-activos.md`, GENERADO per-máquina).** El instalador detecta,
cross-OS/cross-shell, los aliases/funciones que **sombrean un binario real** (POSIX: `brain/lib/detectar-shells.sh`
enumera zsh/bash/fish instalados; PowerShell: detector nativo en `install-brain.ps1`) y escribe una vista
answer-first (el ESCAPE `command <cmd>` primero) en `~/.claude/aliases-activos.md`. El `CLAUDE.md` global la
importa con `@aliases-activos.md` (@import recursivo → siempre en contexto, sin costar líneas). Es GENERADA y NO
viaja por git (entorno de máquina = global). En Windows los bloques `<!-- shells:posix -->` y `<!-- shells:powershell -->`
coexisten sin pisarse.

## Hooks vs skills — por qué unos bloquean y otros no

La diferencia no es de tema, es de **mecanismo de ejecución**:
- Un **hook** es un `.sh` que el CLI corre AUTOMÁTICAMENTE en un evento (PreToolUse, Stop, SessionStart…),
  **sin turno del modelo**. Es el ÚNICO que puede **DENEGAR/BLOQUEAR** (`deny`/`block`) — su fuerza viene
  de correr FUERA del turno.
- Un **skill** es markdown que **ejecuta el modelo** con su juicio, dentro de un turno. **No puede
  bloquear** nada: es una guía que TÚ (o el modelo) invoca.

De ahí la regla de diseño del cerebro:
- **Enforcement** (los dientes: `deny`/`block`) → SOLO puede ser hook.
- **Lógica/cómputo** (¿empuja a develop? ¿hay un secreto? ¿destino=develop?) → se comparte en una **lib
  `.sh`** (p. ej. `delegacion-comun.sh`) que el hook llama — misma lógica, sin duplicar ni divergir.
- **Nudge/inyección** (recordar el dashboard, rehidratar el hilo) → puede tener un **gemelo skill**
  invocable a mano: `checkpoint` (escribe el hilo) y `rehidratar-hilo` (lo lee, hook + skill gemelo).
  Así sobrevive si un update del CLI rompe el evento/canal del hook.

Escalera de resiliencia: `hook` (auto + puede enforce) → `skill` (manual, sin enforce) → `lib .sh`
invocable como comando → `prompt` a mano (no depende de ninguna feature del CLI).

## Los hooks — qué hace cada uno

Se dividen en dos **tiers** según su alcance:

### Tier GLOBAL (los instala `install-brain.sh` en `~/.claude/hooks/`, aplican a TODOS los repos)

| Hook | Evento | Qué hace |
|---|---|---|
| `git-branch-guard.sh` | PreToolUse/Bash | Bloquea `git push`/merge a `develop`/`main` y redirige al flujo ramita→MR→develop. |
| `merge-squash-guard.sh` | PreToolUse/Bash | Bloquea un `glab mr merge`/`gh pr merge` sin `--squash` **solo si el destino es `develop` CONFIRMADO** (la ramita colapsa a 1 commit limpio); `main` (release), ramas personales y destino indeterminado van libres (fail-safe hacia NO forzar squash — nunca aplasta un release ni estorba el día a día). |
| `confirmar-merge-develop.sh` | PreToolUse/Bash | Exige confirmación EXPRESA antes de integrar a `develop` (en el contexto reciente O como autorización DURABLE en `.claude/memory/autorizaciones-vigentes.local.md` con vencimiento — la escribe `turno-nocturno`, sobrevive compactaciones, JAMÁS cubre `main`); autorización súper-explícita para un release a `main`. |
| `proteger-arbol.sh` | PreToolUse/Bash | Protege el árbol de trabajo compartido: bloquea que un agente de fan-out corra `git reset`/`checkout`/`rebase` en el árbol principal (orfanaría commits del orquestador). |
| `proteger-fuente-cerebro.sh` | PreToolUse/Edit\|Write\|MultiEdit | AVISA (no bloquea, fail-open) al editar la copia INSTALADA de un hook/skill del cerebro cuando existe su FUENTE en el clon canónico (`~/.cortex` o `$CLAUDE_BRAIN_DIR`): la edición a la instalada se perdería en el próximo `install`/sync y no viajaría por git. Redirige a editar la fuente. Escape: `CLAUDE_SKIP_PROTEGER_FUENTE=1`. Su gemelo de detección tardía es el drift-check de `verificar-cerebro`. |
| `secret-scan.sh` | PreToolUse/Bash | Bloquea un `git commit`/`git push` si lo que entra al repo trae un SECRETO (AWS/PEM/Anthropic/OpenAI/GitHub/GitLab/Slack/Google). Escanea también el **1er push de una rama nueva** (sin upstream) vs el merge-base con `develop`/`main`. Escapes: `--no-verify` / `CLAUDE_SKIP_SECRET_SCAN=1`. |
| `rama-vieja.sh` | PreToolUse/Bash | Antes de un `git push`, AVISA (no bloquea) si la ramita está muy atrás de `origin/develop` (base vieja → MR con ruido). Umbral `RAMA_VIEJA_UMBRAL` (def 40). |
| `limite-gasto.sh` | PreToolUse/Task | FRENO DURO: bloquea reclutar agentes cuando el gasto real rebasa un techo (`LIMITE_GASTO_OVERAGE_PCT` def 90 / `LIMITE_GASTO_5H_PCT` def off). Complementa al gate (que pregunta). |
| `recordar-dashboard.sh` | PreToolUse/Bash | Antes de un `git push`, RECUERDA (no bloquea) actualizar el dashboard del cerebro. |
| `entorno-maquina-guard.sh` | PreToolUse/Bash | AVISA (no bloquea) si un `git commit` mete al `.claude/memory/` del repo algo específico-de-esta-máquina (un `entorno-maquina.md`, aliases personales, rutas de un `$HOME`, "Rosetta" sin condicional) — viajaría por git y mentiría al clonar en otra compu/OS. Eso vive SOLO en la memoria GLOBAL per-máquina (`entorno-esta-maquina.md`); el repo deja lo portable/condicional. Mecanismo de la norma dura homónima. |
| `no-bypass-deploy.sh` | PreToolUse/Bash | AVISA (no bloquea, fail-safe) cuando se corre A MANO el instalador/deploy de un proyecto en vez de su HERRAMIENTA OFICIAL: el cerebro/widget se actualiza con el **WIDGET** (su updater ⬆), nunca con `install-brain.sh`/`install.sh` a pelo; generalizado a cualquier install/deploy (`deploy.sh`, `make deploy`…). Correr el script crudo se salta backup/atomicidad/sello-de-versión/re-cableado/verificación. NO dispara en `--dry-run`/`--help`, ni en CI, ni sobre una mención entrecomillada. Mecanismo de la norma dura homónima. |
| `rehidratar-hilo.sh` | SessionStart | **El LECTOR de los DOS artefactos de continuidad.** (1) REINYECTA `.claude/memory/hilo-mental-actual.md` (el hilo mental, que escribe el skill `checkpoint`) con su **gate de frescura**: si es de otra rama —o la rama es indeterminada y pasó de `HILO_STALE_HORAS` (def 12 h)— degrada el encabezado a "⚠️ posiblemente OBSOLETO"; el encabezado reporta **siempre la EDAD** del volcado, porque en una rama PERMANENTE la rama nunca cambia y el gate daría FRESCO por construcción (la edad es DATO, no veredicto). (2) Si `hilo-mental-actual.andamio.md` es **MÁS FRESCO que el hilo** (o no hay hilo), inyecta **también el andamio**, con encabezado propio y etiquetado como EVIDENCIA mecánica — nunca como juicio; acotado a `ANDAMIO_MAX_LINEAS` (def 140) con puntero al resto, y marcado **"DE OTRA SESIÓN"** si su `sid` no es el de esta sesión (tras una mudanza, el andamio del repo destino es del stream que ya vivía ahí). Si el hilo es más fresco, solo lo MENCIONA. Silencioso si no hay ninguno de los dos. El contrato del footer lo comparte con el escritor vía la lib `contrato-hilo.sh`. |
| `contrato-hilo.sh` (lib) | — | **El CONTRATO del hilo, en UNA definición.** El footer `> Última actualización: <AAAA-MM-DD> · rama <rama> · nivel <x>` no es decoración: con él `rehidratar-hilo` decide vigencia. La lib expone `hilo_rama` / `hilo_fecha` / `hilo_edad_legible` / `verificar_hilo`; el hook la SOURCEA (con fallback inline si falta: fail-open) y el skill `checkpoint` la corre al volcar (fail-loud). Medido 2026-09-11: **2 de 9 hilos reales de `~/code` no traían el footer** ⇒ su hilo VIGENTE se degradaba a "OBSOLETO" en cada rehidratado, sin que nada lo detectara. |
| `aviso-contexto.sh` | PostToolUse | **Reportero TONTO del llenado de contexto** (dato, sin veredicto): lee los TOKENS REALES del último `usage` del transcript, ANCLADOS al último `/compact` (un `isCompactSummary` resetea el acumulado → sin falsos "está llenísimo" heredados del tramo anterior) y reporta `ctx`, el % de la ventana y el % libre. **Debounce por escalones RELATIVOS a la ventana** (5% de la ventana; 1% a partir del 85%, que es donde la resolución importa) — con escalones absolutos de 50 K quedaba ~20 puntos CIEGO justo antes del auto-compact en ventanas de 200 K. El % libre va **sin clamp**: puede salir negativo, y eso ES el dato (saturado en 0, el 95% y el 99% eran indistinguibles). No recomienda un curso: la decisión es del lector. |
| `aviso-drift-cerebro.sh` | SessionStart | Anti-drift: al iniciar sesión en un repo brained compara su copia por-repo vs la fuente única (dry-run de `sincronizar-cerebro`, diff por contenido). **Parado en TU mini-develop (`Develop<Usuario>`) con `.claude/` limpio → AUTO-SINCRONIZA (apply+commit+push a tu mini)**; en cualquier otra rama solo AVISA (la propagación va por ramita→MR). Throttle 6h en chequeos limpios. **El cuerpo per-repo vive en la lib `drift-cerebro-comun.sh` (`drift_chequea_repo`)**, compartida con el sweeper de flotilla (abajo) → una sola implementación, cero drift. Punto ciego: solo ve el repo de ARRANQUE → la cobertura de N repos la da el sweeper. |
| `barrer-flotilla-cerebro.sh` (script, no cableado) | cron/LaunchAgent 1×/día | **SWEEPER de la FLOTILLA:** recorre TODOS los repos brained de `~/code` (autodescubrimiento por el sello `.claude/hooks/.brain-version`) y aplica la MISMA `drift_chequea_repo` que el hook — auto-sincroniza los COMPARTIDOS parados en su mini-develop con `.claude/` limpio y fuente no stale; el resto lo deja en un REPORTE (`~/.claude/memory/.drift-cerebro/flotilla-ultimo-reporte.md`) + una línea a la bitácora del dashboard. Lock por-repo (mkdir en `.drift-cerebro/`). Antídoto al punto ciego de cobertura del hook (MegaFlux se pudrió a drift porque nadie abría sesión ahí). Preview: `--dry-run`. Agéndalo con el LaunchAgent de ejemplo `macos/launchd/com.local.drift-flotilla.plist` (NO se instala solo — config de máquina) o la skill `schedule`. **Además** corre al final (best-effort, `--no-residuo` para saltarlo) el script `limpiar-residuo` (housekeeping global, ver abajo) — reusa esta MISMA programación diaria en vez de inventar una nueva. |
| `exportar-sesion-master.sh` | Stop 🔔 Automático · SessionEnd · PreCompact | **Auto-export de las sesiones `*-master`:** exporta el transcript comprimido a la CARPETA DE SESIONES (`~/.claude-sessions` por default; `$CLAUDE_SESSIONS_DRIVE` para apuntarla a una nube y que las sesiones VIAJEN entre máquinas) → sobrevive el cleanup de 30 días de Claude Code. Gatillos Stop(debounce)+SessionEnd+PreCompact; el export corre DETACHED (nohup + lock por-sid) → no se ahoga en los transcripts grandes (caso real cps-master 456 MB). El MOTOR (`session-export.js`) lo aporta el brain; la mitad "sembrar" es `brain/sesiones-master/seed.sh`. |
| `checkpoint-mecanico.sh` | PreCompact 🔔 Automático | **El 80% del checkpoint a CERO tokens de modelo (M2/X2, auditoría 2026-09-11; hallazgos de QA cerrados el mismo día):** en el MISMO evento que `exportar-sesion-master` (mismo `transcript_path`), corre DETACHED (nohup + lock por-sid) el extractor `bin/checkpoint-mecanico.js` — lee el transcript en streaming (memoria acotada, medido ~130-190 MB de pico sobre un transcript de 756 MB) y saca, sin criterio: archivos tocados (Write/Edit/NotebookEdit), skills invocadas, mensajes de **`git commit` en TODAS las formas que la norma del equipo obliga** (`-m`, `-F -`+heredoc, `-F <archivo>` con marca honesta de "no recuperable") **y las integraciones por squash del foro** (`gh pr merge --subject`, `glab mr merge --squash-message`) — deduplicadas, y sin colar como commit real la prosa/código que solo MENCIONA un patrón de commit (exige arrancar tras un separador de shell), ramas/cwds vistos, los archivos escritos **desde Bash** (redirección/`tee`, heurística declarada aparte — en modo auto casi nada pasa por Write/Edit: medido 0 vs 45 en el tramo vivo de un master real; descarta destinos con una variable `$VAR` sin expandir en vez de inventar la ruta) y los últimos mensajes del usuario VERBATIM, **filtrando la plomería del harness** (`<local-command-*>`, `<task-notification>`, `<command-name>`, `<system-reminder>`, `## Context Usage`, `/compact` pelón) para no atribuirle al usuario lo que no dijo. El top de comandos y de escrituras-por-bash **prioriza señal sobre ruido** (navegación/inspección y `/tmp` bajan de prioridad, nunca se ocultan). **Su ventana es el TRAMO VIVO** (desde la última frontera de `/compact`): con el archivo entero, los top-N los ganaba el trabajo VIEJO Y TERMINADO por volumen acumulado; lo histórico se cuenta aparte y etiquetado. Escribe (atómico, tmp+rename) `.claude/memory/hilo-mental-actual.andamio.md` — un SIDECAR que el skill `checkpoint` fusiona; nunca pisa `hilo-mental-actual.md` (eso lo sigue escribiendo el modelo, con juicio). El hook **no es el único productor**: el skill lo regenera con `checkpoint-mecanico.js --self --ensure` (la mayoría de los checkpoints NO vienen de un compact). `--self` YA NO falla cerrado por `CLAUDE_CODE_CHILD_SESSION` (medido: esa variable vale `1` también en el hilo principal, no distingue padre de hijo); en su lugar hace una VERIFICACIÓN POSITIVA por filesystem (sidecar de sub-agente más fresco que el transcript resuelto) y AVISA sin bloquear cuando la encuentra. Antes de este hook, `PreCompact` guardaba los BYTES del transcript (gzip) y tiraba el SIGNIFICADO. |
| `hud-stale.sh` | SessionStart + PostToolUse/Bash | **Detector de staleness del HUD (lista de TODOs):** avisa —NO bloquea— cuando cambiaste de **rama git** o de **proyecto/cwd** y el HUD (el árbol de checkboxes de la terminal) sigue mostrando pendientes de la tarea ANTERIOR (la queja "me muestra tareas de otro proyecto/sesión"). Señal 100% OBJETIVA = `(repo root \| rama)` de AHORA vs. lo observado en ESTA sesión — **nunca lee el contenido del HUD** (el FP semántico es imposible por construcción). Precisión por capas: **stamp per-`session_id`** (sesiones/worktrees concurrentes NO se pisan), **first-sight silencioso** (nunca avisa sin un cambio observado), **debounce por transición**, **gate de backlog durable** (solo en repos con `estado-proyecto.md`), **fail-open**. Sugiere re-sembrar el HUD con `/to-do` del `estado-proyecto.md` de esa rama. Advisory por diseño (additionalContext pasivo, como `rehidratar-hilo`/`aviso-contexto`). Escape `CLAUDE_SKIP_HUD_STALE=1`. |
| `barrer-ramas.sh` | SessionStart + PostToolUse/Bash 🔔 Automático | Da TRIGGER al barrido de ramas locales + worktrees ya integrados por DOS vías que comparten `limpiar-ramas.sh` **y** `limpiar-worktrees.sh` (mismo trigger, mismo detach): **(A) SessionStart** — al abrir sesión, ≤1× por `BARRER_RAMAS_HORAS` (def 24), backstop oportunista; **(B) PostToolUse/Bash AL PUNTO DE MERGE** — justo tras un `glab mr merge\|accept` / `gh pr merge` (lo detecta `acg_es_merge_mr`), que es cuando nace el zombie (squash → remota borrada → local `: gone`); debounce corto `BARRER_RAMAS_MERGE_DEBOUNCE` (def 30s) para no relanzar en una ráfaga. Ambas lanzan EN SEGUNDO PLANO, CONSERVAN todo trabajo sin integrar y NUNCA tocan la actual/base/`develop`/`main`/`Develop*`/`keep/*`; `limpiar-ramas` además borra la **rama REMOTA huérfana** que un squash-merge dejó colgando (fail-open sin red). Vías INDEPENDIENTES (B no toca el throttle de A → A sigue de backstop). Es el MECANISMO que dispara a los `script` `limpiar-ramas`/`limpiar-worktrees` (que nadie más ejecutaba → ramas y worktrees squasheados se acumulaban). |
| `delegacion-gate.sh` | PreToolUse/Task | Pide consentimiento de COSTO al reclutar un agente (ver modelo de costo abajo). En fan-out paralelo **coalesce** los asks (gratis/incluido): el 1er gate del lote pregunta, los hermanos pasan en silencio. |
| `delegacion-registrar.sh` | PostToolUse/Task | Materializa el "pregunta 1×": registra el consentimiento tras un `ask` aprobado. |
| `delegacion-reporte.sh` | PostToolUse/Task | Tras un `Task`, recuerda el auto-reporte del fan-out (append a bitácora + actualizar estado). |
| `recordar-orquestar.sh` | PostToolUse (toda tool) | **ADVISORY (no bloquea):** cuenta las mutaciones consecutivas (edits/commits) de la sesión y, al llegar a **N** (`RECORDAR_ORQUESTAR_N`, def 10) SIN una delegación (`Agent`/`Task`) en medio, sugiere un **fan-out** si el trabajo restante tiene piezas independientes (skill `orquestar-fanout`). Un `Agent`/`Task` **RESETEA** el contador (si delegaste, no regaña); debounce de N en N; contador **per-`session_id`**. Si el trabajo es intrínsecamente secuencial, se ignora. Fail-open; escape `CLAUDE_SKIP_RECORDAR_ORQUESTAR=1`. Empuja la norma `orquestar-fanout` ("delega lo paralelizable"), hermano-EMPUJE del gate de costo `delegacion-gate` (que es el freno). |
| `delegacion-comun.sh` | — (lib) | Librería compartida por el gate y el registrador (`source`). Clasifica el nivel de costo y arma la línea de estado de cuota. **No es un hook por sí sola.** |

Config del gate: **`hooks/agentes-costo.json`** (se copia a `~/.claude/`). Clasifica agentes por
regex y fija el umbral de ventana (`umbral_ventana_pct`, def 95).

### Tier REPO-SCOPED (fuente en `hooks/`; NO se instalan globales)

Cada repo los copia a su propio `.claude/` y los cablea en su `settings.json` — se cargan **solo si
la sesión INICIA en ese repo**.

| Hook | Evento | Qué hace |
|---|---|---|
| `sesion-inicio.sh` | SessionStart | Reinyecta rama + norma de git + orden de leer la memoria al abrir/retomar sesión o tras compactar. (Complementa al global `rehidratar-hilo`: éste hace el hilo, aquél el ritual del proyecto.) |
| `dod-verificar.sh` | Stop | Hace cumplir la **definición de LISTO**: bloquea declarar algo "listo/terminado/funciona" tras tocar código sin una marca CITADA de (1) QA confirmado por el usuario o (2) su OK expreso. Distingue estatus/pregunta de cierre (una pregunta co-ubicada NO salva un claim afirmado); cuenta como "código tocado" también la edición por Bash (`sed -i`/`patch`/redirección); detecta la tool de navegador por estructura del transcript (no por la palabra "screenshot"). Precisión (P2): un paso MECÁNICO del proceso ("checkpoint hecho", "push hecho", "MR abierto", "memoria actualizada") y la celebración sin entregable (🎉 standalone, interjecciones) NO disparan; fail-safe: si la frase mezcla paso mecánico y claim de entregable ("push hecho y la feature ya funciona"), el claim manda y bloquea. |
| `recordar-cosechar.sh` | Stop | Dos cosas, nunca bloquea: **(1) ESPEJO automático e idempotente** — vuelca los PENDIENTES del TaskList vivo de la sesión a un bloque fenced `<!-- espejo-tasklist -->` dentro de `.claude/memory/estado-proyecto.md` (determinista, lee `~/.claude/tasks/<sid>/*.json` con jq → markdown; SIN LLM; solo si el .md ya existe, no lo crea; solo toca ese bloque). **(2) NUDGE gentil (1×/día/repo)** — si hubo trabajo sustantivo y no se tocó `aprendizajes.md` (→ `/cosechar-sesion`) o el backlog durable POR UN HUMANO (`estado-proyecto.md` FUERA del bloque espejo, o `bitacora.md`), lo recuerda. El espejo NO auto-suprime el nudge (el chequeo humano ignora el bloque). Mitad "recuérdame" del par con `cosechar-sesion`. |
| `recordar-unificar-cerebro.sh` | SessionStart | Gemelo HACIA ARRIBA de `aviso-drift-cerebro`: aquél avisa cuando la copia por-repo quedó ATRÁS de la fuente (hay que BAJAR); éste avisa cuando TU mini acumuló aprendizajes+memorias sin UNIFICAR a `develop` (hay que SUBIR). Cuenta el delta de `.claude/` de la rama actual vs `origin/develop` y, si supera el umbral, sugiere `/unificar-cerebro`. NO escribe nada al árbol (integrar es deliberado, por MR): solo DETECTA y AVISA. |

> **`precompact-volcar-estado.sh` se RETIRÓ** (PreCompact no puede inyectar contexto ni pedir acción): compactar sin perder el hilo lo cubren el skill `checkpoint` (escribe el hilo) + `rehidratar-hilo` (lo relee, con gate de frescura) + el watermark `aviso-contexto` (avisa antes del auto-compact).

## Modelo de costo de delegación (3 niveles + ventana + consentimiento)

Reclutar un agente (`Task`) cuesta según su nivel, que resuelve `delegacion-comun.sh`:

- **gratis** — modelo local (regla `clase:"local"`), sin costo por token.
- **incluido** — Claude **dentro** de tu ventana de 5h (uso < `umbral_ventana_pct`): sin costo
  marginal (ya cubierto por la suscripción).
- **metered** — Claude en **overage** (ventana agotada), API externa de pago, o agente **desconocido**
  (default conservador → se trata como con costo).

El nivel es **window-aware**: se lee el `state.json` del daemon de cuota (fresco, < 30 min). El `ask`
muestra el estado real de tus ventanas, p. ej.
`Ventana 5h: 19% ($2.48 de $45; 3.7M tokens) · Semanal: 57% ($401/$4800)` (la semanal se omite si el
snapshot no la trae).

Cadencia del consentimiento:

- **gratis / incluido** → se pregunta **1× por computadora**, luego silencioso (registro en
  `~/.claude/delegacion-consentimiento.json`, clave `maquina`). Si la ventana se agota, el mismo
  agente pasa a `metered` (cambia la clave `nivel:firma`) → se vuelve a preguntar.
- **metered** → se pregunta **1× por workflow** (`session_id`), luego silencioso el resto del workflow.

Si el usuario NIEGA el `ask`, el `Task` no corre → `delegacion-registrar` no dispara → no se registra
nada (la próxima vez vuelve a preguntar). Sin `jq` o sin snapshot fresco → se trata como `metered`
(pregunta): fail-safe de gasto.

## Cómo probar

```sh
bash brain/test-brain.sh      # o: just test-brain
```

`test-brain.sh` NO toca tu `~/.claude`: corre todo contra un `$HOME` FALSO aislado (`mktemp`, se borra
al salir). Cubre: (a) `bash -n` de todos los hooks + `jq empty` de los JSON; (b) el gate de delegación
(gratis/incluido/metered/desconocido, el ciclo gate→registrar→gate-silencioso y la transición
dentro/fuera de la ventana, y el **coalescing de asks en fan-out** paralelo); (b1c) `merge-squash-guard`
develop-only con `glab` mockeado; (b2) `secret-scan` (incluido el 1er push de rama nueva); (b3b)
`limpiar-worktrees` (base configurable + detección por `git cherry`); (b4) `dod-verificar` (cierre/QA-visual
a ciegas, evasión por pregunta, edición por Bash); (b5) compactación: que `precompact` esté **RETIRADO** +
`rehidratar-hilo` (inyección + gate de frescura); (b6) el watermark `aviso-contexto`; (b7) el dedupe del
doble-cableado; (b8) `recordar-dashboard` con fallback a `origin/develop`; (c) idempotencia de
`install-brain.sh` corrido 2× (cada hook 1× en `settings.json`, 1 solo bloque de normas) y limpieza por
`uninstall-brain.sh`.

Los **jueces-Haiku** (`confirmar-merge-develop`, `dod-verificar`) se prueban en **dos capas**: (1)
**DETERMINISTA**, corre SIEMPRE — el veredicto se mockea con `CLAUDE_MERGE_JUEZ_MOCK`/`CLAUDE_DOD_JUEZ_MOCK`
(el MOCK cae al **PISO DETERMINISTA de main**, batería `piso-main`, que verifica el override sin red); (2)
**LIVE opt-in** contra el Haiku real —el JUICIO de qué frase autoriza—, que **requiere `curl` + `jq` + el token
OAuth de suscripción** (`$CLAUDE_CODE_OAUTH_TOKEN` → `~/.claude/.credentials.json` → keychain macOS):
```sh
CLAUDE_MERGE_JUEZ_LIVE=1 CLAUDE_DOD_JUEZ_LIVE=1 bash brain/test-brain.sh   # baterías LIVE de FP/FN (merge + dod)
```
Sin las env vars, las baterías LIVE se SALTAN (la suite queda verde sin gastar tokens).

La **CI** (`.github/workflows/ci.yml`) repite en cada push/PR el `bash -n` de todos los `.sh`, el
`jq empty` de los `.json` y `shellcheck --severity=error`. El cerebro se auto-valida antes de
distribuirse.

## Instalar / desinstalar

```sh
# Instalar (idempotente; re-correr es seguro)
bash brain/install-brain.sh                 # Mac/Linux
pwsh -File brain\install-brain.ps1          # Windows (delega en bash brain/install-brain.sh)

# … o por el instalador maestro de la raíz (widget + cerebro):
./install.sh                # todo
./install.sh --no-brain     # solo el widget/daemon, sin el cerebro

# Desinstalar (idempotente; inverso EXACTO del instalador)
bash brain/uninstall-brain.sh
./uninstall.sh              # widget + cerebro
./uninstall.sh --no-brain   # solo el widget, deja el cerebro
```

`uninstall-brain.sh` quita los hooks globales, `agentes-costo.json`, la skill y el bloque de normas
de `~/.claude/CLAUDE.md`, y **des-cablea de `settings.json` solo las entradas que apuntan a esos
hooks** (deja intactas las demás, vía `jq`). **NO borra datos del usuario**: conserva el dashboard,
el registro de consentimiento de delegación y toda la memoria de proyectos.

## Con `just` (desde la raíz)

```sh
just install-brain      # bash brain/install-brain.sh
just uninstall-brain    # bash brain/uninstall-brain.sh
just test-brain         # bash brain/test-brain.sh
```
