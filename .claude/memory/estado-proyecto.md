---
name: estado-proyecto
description: Backlog VIVO y compartido de cortex — la fuente de verdad de qué sigue, qué se decidió y qué quejas/sugerencias tienen los claudes. Cualquier sesión (master o no, cualquier máquina) escribe aquí; NO en el panel de to-dos (ese es scratch efímero de sesión). Aquí empiezas siempre.
metadata:
  type: project
---

# Estado del proyecto — cortex (el cerebro compartible)

> ⚠️ **INTERINO (2026-08-09 → reubicar-master):** el backlog de dev VIVO se consolidó en
> **`BACKLOG-UNIFICADO.md`** (el working único). **Empieza AHÍ.** Este archivo (tracked/compartido) conserva
> su contenido hasta que **reubicar-master** lo re-canonice al molde de `estado-proyecto` y resuelva el wart
> "tracked estado-proyecto ↔ BU untracked/local".

> **Aquí empiezas.** Este es el backlog DURABLE del cerebro: qué sigue, qué se decidió, y el buzón donde
> cualquier claude deja sus quejas y sugerencias. El **panel de to-dos de una sesión es scratch efímero**;
> lo que debe sobrevivir a la sesión/compactación vive AQUÍ. Léelo (junto a `MEMORY.md`) antes de tocar nada.
>
> **Cómo se escribe:** los **Pendientes** y **Decisiones** se CURAN (edítalos, muévelos, ciérralos). El
> **📮 Buzón** es append-only: agrega tu línea al FINAL con `>>` (dos append no se pisan; un Edit tropieza
> con "File modified since read" cuando varias sesiones escriben a la vez). Formato de cierre: mueve el ítem
> a **Hecho** anclado a commit+fecha.

## 🔜 Pendientes (backlog vivo)

- **[MEDIO, PLAUSIBLE] M-7 del dictamen de barrido de ramas (`scratchpad/AUDITOR-barrido-ramas.md`,
  2026-09-11) — caps silenciosos en la consulta al foro de `_bz_intentar_gh`/`_bz_intentar_glab`
  (`ramas-zombie.sh`): `gh … --limit 300` y `glab … --per-page 300`. Dos problemas sin cerrar: (1) un
  repo con >300 PRs/MRs mergeados deja los viejos fuera del cache y (d) "no encuentra" el PR/MR de una
  rama vieja → la conserva sin decir que TRUNCÓ la consulta; (2) el `per_page` de la API de GitLab topa
  en 100, así que el 300 pedido no da lo que promete. El auditor NO lo pudo cerrar sin pegarle a un foro
  real (por eso quedó PLAUSIBLE, no CONFIRMADO) — exige rediseño (paginar hasta encontrar la rama, o
  consultar `gh pr list --head <rama>`/`glab mr list` filtrado POR rama en vez de bajar un bulto) y
  verificación contra un repo con volumen real de PRs/MRs cerrados. Dejado explícitamente FUERA de esta
  ronda (fix/barrido-ramas-criticos) — no se improvisó.
- **[BAJO, hallazgo colateral, sin tocar] Tests con `ok`/`bad` dentro de un subshell `( … )` no cuentan
  para el veredicto de la suite.** Descubierto al verificar "falla sin el fix" de los tests nuevos de
  `fix/barrido-ramas-criticos`: `test-brain.sh` corre con `set -u` y cuenta PASS/FAIL en variables
  GLOBALES (`$PASS`/`$FAIL`); los bloques que hacen `( . "$HOOKS/ramas-zombie.sh"; … ok …; … bad … )`
  imprimen la línea `PASS:`/`FAIL:` (stdout es compartido) pero el incremento de `$PASS`/`$FAIL` ocurre
  DENTRO del subshell y se pierde al salir — esas aserciones son decorativas, nunca pueden hacer fallar
  la suite. Confirmado en **`b3d`** (línea ~1969, dos bloques) y **`b3e`** (línea ~1984). El propio
  comentario de `b3g` (línea ~2043) ya documenta el antídoto correcto ("se sourcea en ESTE scope, no en
  subshell, para que ok/bad cuenten"), así que el patrón correcto YA existe en el archivo — solo falta
  aplicarlo a b3d/b3e. Fuera de alcance de esta ronda (no es de los 19 hallazgos del dictamen de ramas);
  encontrado por accidente al blindar los tests nuevos con esta MISMA verificación. Fix: quitar los
  paréntesis en esos dos bloques (igual que se hizo para los tests nuevos b3h/b3j/b3o de esta ronda).

- **Broker de terminal trasladado a cortex (#26i, primera pieza) — CÓDIGO LISTO Y AUDITADO EN RAMA;
  FALTA LA MIGRACIÓN EN VIVO (unjordi presente).** Rama `feat/term-broker`. Quedó en el repo:
  `src/term-broker/` (5 `.ts` vendorizados de axon **`341fb53`** + `SHA256SUMS` + 2 probes),
  `bin/cortex-term-broker`, `bin/migrar-term-broker.sh`, `src/systemd/cortex-term-broker.service`,
  bandera `install.sh --con-term-broker` (opt-in, Linux, token generado 0600), retiro en
  `uninstall.sh`, `docs/term-broker.md`. Del lado de axon, `feat/term-broker-cliente-solo` (`67bdbae`)
  ya trae `origin/develop` fusionado.
  **Segunda pasada (2026-09-07): se atendieron los 10 hallazgos priorizados de la auditoría.**
  Lo sustantivo: se **re-vendorizó desde `341fb53`** (socket unix + `GET /health` + el manejo de
  error de `listen()` que faltaba); la unidad ganó `RuntimeDirectory=axon` +
  `RuntimeDirectoryPreserve=yes` y `StartLimitIntervalSec/Burst` (antes ciclaba para siempre sin
  llegar nunca a `failed`); el instalador valida OS/prereqs en el **paso 0** y decide por el
  **endpoint** (`ss` sobre puerto y socket) en vez de por el nombre de una unidad, sin habilitar
  cuando está ocupado (y deshabilitando lo que una corrida previa habilitó); y la migración es un
  **script** que verifica con el token real. Verificado: `probe-instalador.sh` **49/49 exit 0**,
  `probe-broker-vivo.sh` **35/35 exit 0**, `sha256sum -c` 0, `systemd-analyze --user verify` 0,
  `bash -n` de los 8 scripts. **NO se tocó** el `axon-term-broker.service` que corre (MainPID
  3203989, NRestarts=0 antes y después).
  Lo que falta, por severidad:
  - **[ALTO] la migración en vivo.** Se corre `~/.local/bin/migrar-term-broker.sh` (idempotente,
    adopta el token legacy para que el `.env` del cliente no cambie, verifica con `/health` +
    `/run` real y revierte solo si falla). Requiere `./install.sh --con-term-broker` antes, y a
    unjordi presente porque **cierra sus terminales abiertas**.
  - **[MEDIO] retirar `src/server/term-host-broker.ts` de axon** (ahora 394 líneas). Sigue
    DEPRECADO a propósito: borrarlo antes de la migración rompería el servicio vivo, que arranca
    desde `~/code/axon-run`. MR de follow-up POST-migración.
  - **[BAJO · MENORES de la auditoría, NO atendidos]** — se dejan explícitos para que no se pierdan:
    `I-3` el match de path por prefijo (`url.startsWith("/run")` acepta `/runtime`), `I-4`
    `tokenMatches` usa `Buffer.equals` y no `timingSafeEqual`, `C-5`/`C-6`. Los tres primeros viven
    en el código **vendorizado**: arreglarlos aquí rompería la copia byte-a-byte, así que van en
    **axon** y llegan por re-vendorizado. `C-4` (el claim del `env` falso en modo contenedor) e
    `I-6`/`I-7`/`I-11`/`I-12`/`I-13`/`C-3` SÍ se atendieron.
  - **[CERRADO] licencia del vendorizado.** unjordi confirmó que axon y cortex son suyos y que la
    relicencia MIT no es un bloqueo; el `NOTICE` lo dice ahora sin el "de facto".
  - **[BAJO] el contrato de #26i sigue abierto** para las OTRAS piezas (hwfit, `ollama-ram-pin`,
    `state.json`): archivo vs socket vs HTTP, descubrimiento, versionado. Este traslado no lo cierra
    ni lo prejuzga.

- **Aristas del sync de sesiones (delegadas por `reubicar-master` §9) — EN CURSO `fix/session-infra-aristas`.**
  Las 4 son el subsistema de sync de sesiones (NO del skill; el skill mueve un master, no refactoriza su
  tooling), y son las aristas EXACTAS que el move real de los masters va a pisar. Origen: `SKILL.md §9` —
  estaban SOLO en el texto del skill, nunca en este backlog (lección abajo). Por severidad:
  - **[ALTO · destructivo] #2 freshness-check en `seed.sh --force`** (`brain/sesiones-master/seed.sh:61` →
    `session-import.js`): `--force` pisa lo local con el `.gz` de Drive SIN comparar frescura → un master VIVO
    regresa a una copia vieja (turnos recientes perdidos, mudo). Nace con test en `test-brain.sh`.
  - **[ALTO] #3 auto-registro que ACTUALICE `target`** (`brain/hooks/exportar-sesion-master.sh:139-147`): hoy
    el bloque solo corre si el sid NO está en masters.json y el node solo hace `push` si `!some(id)` → un master
    que se MOVIÓ conserva su `target` viejo → `seed` en otra máquina lo siembra al folder equivocado.
  - **[MEDIO] #1 tie-break determinista en `findSession`** (`bin/session-lib.js:30-41`): devuelve el 1er slug del
    `readdirSync` (orden FS arbitrario) si el id existe en 2 slugs (move a medias) → resume no-determinista.
  - **[BAJO · latente] #4 poda de `~/.claude/session-move-backups/`** (`bin/session-move.js`): sin límite; hoy el
    dir está VACÍO → preventivo (aún no muerde).
  - **Mecanismo (ASENTADO en `cerrar-slice` + corolario en `orquestar-fanout`, con test `s5`):** el paso de cierre ahora EXIGE barrer al backlog,
    con severidad, lo que se DELEGÓ al texto de un artefacto entregable (sección "Pendientes/Delegados/§ fuera de
    alcance" de un skill, un dictamen, un README) ANTES de cerrar — porque eso es log disfrazado de backlog, no
    resolución. Con la pregunta de 2º orden "¿lo empujado fuera del muro tiene casa+dueño+severidad?" (el punto
    ciego de la introspección: el auditor comparte el frame "out of scope = no es mi problema"). Nació porque este
    MISMO §9 dejó las 4 aristas solo en el texto del skill, una de ellas destructiva. · _reubicar-master §9, 2026-08-08._

- **`limpiar-ramas.sh` barre mal las ramas squasheadas (dos fallos, vistos en vivo · axon 2026-08-29).**
  (1) **Base detectada por el cwd de la sesión, no por el repo objetivo:** parado en `plantilladotnet` (cwd de
  la sesión), al barrer `axon` agarró `DevelopUnjordi` como base en vez del `develop` de axon → corrió sobre el
  repo equivocado y no tocó una sola rama del objetivo. Misma raíz que el FN del git-branch-guard por
  `target ≠ CLAUDE_PROJECT_DIR` (abajo). (2) **No ve a través del squash+develop-avanzado:** conservó 6 `fix/*`
  YA integradas (su diff vs develop era "develop que avanzó", no trabajo único) y a la vez marcó `router` (una
  mini) como borrable → under-barre lo rancio Y over-barre lo vivo. Toca `brain/hooks/limpiar-ramas.sh` (+ su
  disparador `barrer-ramas.sh`). Nace con test (sandbox: squash-merge → la rama debe detectarse integrada;
  cwd≠repo-objetivo → base correcta). ⚠️ Se dio por "arreglado" antes (detección de squash-merge) y quedó a
  medias — la limpieza post-merge de hoy lo destapó. · _axon-master, 2026-08-29._

- **Estándar: `conocimiento-propio` por sesión master.** Volver ESTÁNDAR que toda sesión master escriba su
  propio `conocimiento-propio.local.md` (per-repo en su repo-base, gitignored, re-inyectado en cada
  SessionStart por el hook `aviso-drift-cerebro`). Cada master lo escribe desde SU lado (no copia el del
  gemelo), a partir del template `EJEMPLO-conocimiento-propio.md`. Ya lo tienen: `claude-brain-master`
  (Mac, `761c82d9…`) y `claude-brain-cachy-master` (Cachy, `7a6960de…`, 2026-08-03). **Falta:** (a)
  documentar el paso "siembra tu conocimiento-propio" en el setup/checklist de un master; (b) decidir dónde
  vive canónicamente el `EJEMPLO` (hoy en el Drive `claude-sessions/`) — ¿al brain, o se queda personal?;
  (c) ¿lo siembra `install-brain`/`bootstrap` o es paso manual? · _decisión de unjordi 2026-08-03._

- **Endurecer git-branch-guard contra evasión por subshell/`$()`.** `analizar-comando-git.sh` ancla la rama
  con `(main|develop)([[:space:]]|$)`; un `)` de subshell o `$(...)` la evade: `(cd /tmp && git push origin
  develop)` y `x=$(git push origin develop)` PASAN. Confirmado por ejecución en DOS auditorías (cortex
  A-GBG-01 + la DUPLA de cps). **Backstop:** ramas protegidas server-side. Toca un guard de supervisión →
  cambio de PRECISIÓN, exige OK EXPLÍCITO de unjordi para ESE control (con su test adversarial). · _DUPLA 2026-08-03._

- **git-branch-guard: falso NEGATIVO angosto del push PELÓN vía target ≠ `CLAUDE_PROJECT_DIR`.** `acg_rama_actual`
  resuelve la rama del `CLAUDE_PROJECT_DIR`, NO la del repo objetivo → un `git -C <repo-parado-en-develop> push`
  (o un `cd`) desde una sesión cuyo `CLAUDE_PROJECT_DIR` está en una ramita NO se bloquea, aunque el push real toque
  develop. CONFIRMADO por ejecución (DUPLA juez-destino, ronda 1+2, A2). El destino EXPLÍCITO a base SÍ bloquea siempre;
  **backstop:** ramas protegidas server-side. Toca un guard de supervisión → cambio de PRECISIÓN con su test adversarial,
  exige **OK EXPLÍCITO de unjordi para ESE control**. Es OTRO guard: su propia ramita/slice, NO mezclar con el juez-merge. · _DUPLA juez-destino 2026-08-05._

- **Atar `verificar-firma-canonica.sh` al GATE del auditor (#44).** Construido el DETECTOR determinista
  `brain/verificar-firma-canonica.sh` (flaggea drift de la firma-árbol en un cerebro INSTANCIADO: secciones
  ausentes en CLAUDE.md, memorias sin prefijo `dom-/dev-/ux-/qa-`/núcleo, invariante MEMORY↔archivos roto,
  hooks retirados en la prosa; `--strict` = modo gate) + la skill humano-en-el-loop `canonizar-cerebro`
  (destila el prototipo de fluxcore). Batería `g5` en `test-brain.sh` (verde). **Falta (#44):** cablear el
  detector como sub-check del auditor de coherencia y decidir la forma del GATE — ¿lo corre `auditar-coherencia-cerebro`
  sobre cada cerebro instanciado?, ¿un paso de CI con `--strict` antes de un release?, ¿sobre qué set de repos?
  · _feat/reconstruir-firma-canonica, sin mergear · 2026-08-08._

- **QA visual de los 3 tiles de `canonizar-cerebro` en los widgets** (macOS PopoverView.swift · Linux main.qml ·
  Windows PopupForm.cs). Se agregó el tile 📐 + su estado opt-in en las 3 GUIs (5-catálogos en sync, `verificar-arbol-sync.sh`
  verde), pero NO se compiló ni se vio en pantalla — pendiente el QA visual insustituible. · _feat/reconstruir-firma-canonica · 2026-08-08._

- **Extender el parity-check del árbol a hooks/leyendas.** `docs/flowcharts/verificar-arbol-sync.sh` (FASE 1)
  solo cubre la familia 💡 Skills; NO los hooks 🔒/🔔 ni las leyendas → un drift de hook (p. ej.
  `exportar-sesion-master` ausente de CLAUDE.md) pasa CI en verde. Extenderlo a 🔒/🔔 (README↔CLAUDE.md↔MANIFEST)
  + byte-igualdad de las leyendas `.dot` vs `gen-leyenda-arbol.sh`. · _DUPLA 2026-08-03 (H3, BAJO)._

- **Continuidad MULTI-STREAM del hilo** (`rehidratar-hilo` + `checkpoint`). Que `rehidratar-hilo` inyecte TODOS
  los `hilo-*.md` (dueño+frescura) y `checkpoint` escriba `hilo-<rol>.md` por auto-identificación, con
  `hilo-mental-actual.md` como alias legado. Aditivo/retrocompatible → apto para global. Cierra el bug real de
  dos gemelos pisándose el hilo (2 colisiones en un día). Diseño completo + VERBATIM en
  [[propuesta-multi-stream-hilos]]. · _rescatada de potenciaDatabases 2026-07-30, verificada vigente 2026-08-05._

- **Lección cps-master: memorias sin auto-refs por Nº DE LÍNEA.** Prohibir referencias tipo `archivo:87` en
  memorias (se rompen al editar) → usar heading/ancla grepeable; y `desinflar-memorias` debe **REUBICAR** los
  punteros al cortar (en cps los huerfanó). Aplica a mi propio [[juez-empoderamiento]] (tenía refs `:87`/`:139`). · _retro cps-master 2026-08-05._

- **Lección cps-master: `hilo-mental-actual.md` NO hardcodee la máquina** → `rehidratar-hilo`/`checkpoint`
  derivan `uname`/`$HOME` en vivo. Empata con la propuesta multi-stream. · _retro cps-master 2026-08-05._

- **`merge-squash-guard`: FP de detección de destino=main en `gh` (releases).** El fail-safe exigió `--squash`
  en `gh pr merge 267 --merge` (release develop→main del dod) porque NO pudo confirmar que el destino es main
  → un release a main va SIN squash → bloqueo EN FALSO. Sospecha: la exención consulta el destino vía `glab`
  y no cubre GitHub/`gh`. Toca un guard de supervisión → cambio de PRECISIÓN con su test adversarial, exige OK
  EXPLÍCITO de unjordi para ESE control. unjordi: "a la tanda de remakes". · _FP en vivo 2026-08-06 (también en `~/.claude/memory/guards-falsos-positivos.md`)._

- **Mensajes de commit/squash unhelpful.** Revisar por qué los mensajes de commit y —peor— de squash quedan
  poco informativos; definir/forzar un mínimo de mensaje-resumen curado por slice (¿en `cerrar-slice`/un hook?). · _unjordi 2026-08-05._

- **Guard de TOKENS-antes-de-tareas quedó a medias.** El guard que revisa cuánto presupuesto/tokens hay antes de
  lanzar tareas (familia `limite-gasto`/`delegacion-gate`) nunca terminó de quedar; retomarlo y cerrarlo. · _unjordi 2026-08-05._

- **potenciaDatabases — dry-run de consolidación (CONVERGIÓ, decisión de unjordi).** Dry-run no-destructivo sobre
  COPIA: converge en 1 ronda, un solo archivo cambia (`MEMORY.md`, puramente aditivo), cierra 1 hueco ALTO (que un
  db-master nuevo encuentre su propio hilo + caveat de rehidratación). Recomendado aplicar al real (bajo riesgo).
  **Decisiones PARQUEADAS para unjordi (NO ejecutadas):** (a) borrar `db-master.md` de 0 bytes; (b) ¿`rehidratar-hilo`
  elige hilo por rol / renombrar `hilo-mental-actual.md`→`hilo-re-master.md`? (empata con multi-stream); (c) ~20
  `[[wikilinks]]` de concepto: dejarlos como tags o normalizarlos. NO adelgazar CLAUDE.md (front-load intencional).
  Es repo de sus 2 masters (re-master/db-master) → decide él. Reporte: `scratchpad/potenciadb-consolidacion/`. · _2026-08-05._

- **MegaFlux (registros_bats_y_buses) — dry-run de consolidación EN CURSO.** Mismo molde no-destructivo que
  potenciaDB (agente lanzado 2026-08-06). Objetivo: dejar su cerebro sólido/operable para poder **encargarle la
  tarea al Claude de ESE repo** (unjordi hará mañana un push a PRODUCCIÓN pedido hace 1 semana — el alcance de los
  cambios lo define unjordi/Felipe, no este master). Además: registros_bats es COMPARTIDO pero le FALTA la marca
  `.claude/repo-compartido` + sync del brain (ver inventario de cerebros por-repo). · _2026-08-06._

- **Cluster de FP/FN de guards — reconciliado por fan-out axon-local (2026-09-01).** Del fan-out read-only sobre
  los dictámenes (axon `gitguard-2026-08-26`) + el corpus `docs/guards-falsos-positivos.md`, SIGUEN PENDIENTES
  (cada uno = cambio de PRECISIÓN con test adversarial, **exige OK EXPLÍCITO de unjordi para ESE control**):
  - **git-branch-guard / `analizar-comando-git.sh`:** el regex de `acg_push_destino_base` mete `/` en la clase
    separadora → una ramita cuyo NOMBRE termina en `/develop` o `/main` (`feat/develop`, `hotfix/main`,
    `release/main`, `--delete feat/develop`) se BLOQUEA en falso. Test: esos casos → ALLOW; `develop`/`main`/
    `HEAD:develop`/`+develop`/`refs/heads/develop` → siguen DENY; `feat/develop-x`/`developer` → ALLOW.
  - **secret-scan / `detectar-secretos.sh`:** (S1) `AKIA[0-9A-Z]{16}` no caza las STS `ASIA…` → `(AKIA|ASIA)`;
    (S2) faltan las service-account de OpenAI `sk-svcacct-…`; (S3/S4) el patrón connstring `scheme://user:pass@`
    da FP sobre placeholders de README (`postgres://user:password@…`) → añadir a `ds_safe_re`. Cada uno con su test.
  - **dod-verificar:** reconocer un `Read` de imagen `.png/.jpg` RASTERIZADA (pdftoppm) el MISMO turno como
    evidencia de QA visual (hoy solo whitelistea browser/screenshot) — ~10 FP en el corpus, mordida dominante en la Mac.
  - **Ya-en-backlog (arriba):** git-branch-guard subshell `$()` + FN target≠CLAUDE_PROJECT_DIR · merge-squash gh-main · limpiar-ramas squash.
  - _Los axones `dupla-release`/`flowcharts-sesion`/`procesos-fmea` toparon maxturns (sin reconciliar); re-correr con candado de tope-de-lectura o modelo 120b para cerrar su cobertura._

- **Ciclo INSTALL/UPDATE — reconciliación de la auditoría FMEA 2026-07-30 (verificado 2026-09-01).** Los
  hallazgos del ciclo install/update NUNCA se habían migrado a este backlog (vivían solo en
  `docs/auditoria-procesos-fmea-2026-07-30.md` → el doc MENTÍA marcándolos abiertos). Verificado contra el
  código de hoy: **one-stop installer** ✅ (2026-07-23, `docs/autoupdate.md`) · **H1** (puente HOME↔USERPROFILE
  en los `.ps1`) ✅ · **H2** (resolveClonePath con fallback) ✅ en `main.qml`/Swift. **SIGUE ABIERTO (único
  install-cycle vivo):** **H2 en `Updater.cs` (Windows)** — NO tiene el fallback `resolveClonePath` (embedded →
  `$CLAUDE_BRAIN_DIR` → `~/.cortex` → `~/.claude-brain`) → la divergencia del self-update persiste en Windows;
  portar `resolveClonePath` a C#. **Por verificar aún** (no revisados esta pasada): el field-check (verificar
  que un repo real cablee el MANIFEST) + el lote A1-A8/B3/C2 de la FMEA. · _reconciliado por axon-master 2026-09-01._

## ✅ Hecho (anclado a commit+fecha)
<!-- Enuncia en pasado con su ancla. Ej: "X integrado — <commit>, <fecha>". -->
- **Juez de merge decide el destino + PISO DETERMINISTA de main** — `6614220` (PR #262), 2026-08-05. El juez
  (`confirmar-merge-develop.sh`) infiere el destino cuando `acg_destino_de_mr` viene VACÍO en el entorno-hook,
  con FAIL SEGURO (duda + release → main estricto, NUNCA develop); + un piso determinista (main+ALLOW sin
  lenguaje de release del USUARIO → DENY) como defensa en profundidad ante lo poco fiable de Haiku en el
  'mergea' pelón a main. Transporte del juez = curl→api.anthropic.com con token OAuth (NO `claude -p`, ~1.3s).
  Baterías `piso-main` (determinista) + LIVE 28 (merge) verdes.
- **Juez de MERGE EMPODERADO — LIBERADO a main e instalado** — release #265 (`ad0ad68`, v0.2.291), 2026-08-06.
  Desamordazado (`max_tokens` 16→768) + `temperature:0` + CoT/centinela `VEREDICTO: ALLOW|DENY` (parse `tail -1`,
  truncado→UNAVAILABLE→DENY) + **veto de cita** (ALLOW exige `CITA:` = span VERBATIM de una línea `USUARIO:`,
  re-verificado determinista con `grep -Fq`) + hint de PRs abiertos (factual, identifica destino, NUNCA
  autoriza) + piso barato (sin línea USUARIO→DENY sin LLM) + PISO DETERMINISTA de main. **Triple-lever OPT-IN**
  (`CLAUDE_MERGE_JUEZ_VOTES` default 1=byte-idéntico; ≥2=votos paralelos, agregación unánime-para-ALLOW /
  cualquier DENY|UNAVAILABLE gana; `CLAUDE_MERGE_JUEZ_TEMP` default 0). Modelo = **Haiku desamordazado**
  (Sonnet 4.6 no existe; 4.5 lo rate-limitea el canal OAuth). 467/0 determinista + 5/5 adversariales.
  **Primer merge CLI real que pasó por él: plantilladotnet !114** (re-sync de la copia por-repo, supersedió el
  !113 stale que traía el juez amordazado). Diseño+corpus durables en [[juez-empoderamiento]].
- **Juez del DoD EMPODERADO — en develop, release a main PENDIENTE (PR #267 abierto)** — `6f969c0` (#266), 2026-08-06.
  `dod-verificar.sh` desamordazado (`max_tokens` 32→512, temp 0) + 3 centinelas `CIERRE:/MARCA:/VISUAL: si|no`
  (cada uno `tail -1`) + veto de cita sobre `MARCA` + **fail-OPEN preservado** (nunca bloquea en falso por un
  hipo del canal). +batería `djlive`; el caso antes-flaky ahora estable. **El release #267 (develop→main) quedó
  para clic web de unjordi** (lo frenó un FP del `merge-squash-guard`, ver Pendientes).

## 🧭 Decisiones (con su porqué)
- **2026-08-03 · Convención de firma en TODOS los cerebros:** `CLAUDE.md` = firma-TOC (árbol de capacidades →
  skills) que remite al detalle (`MEMORY.md`/`AGENTS.md`). Se audita por el entry-point real pero se
  consolida MIGRANDO a la convención.
- **2026-08-03 · `conocimiento-propio` por sesión master** (ver Pendientes) — la identidad de cada master no
  se copia entre gemelos; cada uno escribe el suyo.

## 📮 Buzón de los claudes — quejas y sugerencias (append-only, con `>>`)
> Cualquier claude (cualquier sesión/máquina): si algo del cerebro te estorbó, te confundió, o se te ocurre
> una mejora, DÉJALO AQUÍ con tu fecha y quién eres. Es la materia prima para afinar el brain (no lo dejes
> solo en el chat). Un ítem que madura → se sube a Pendientes.
- 2026-08-03 · claude-brain-cachy-master · (siembra) el panel de to-dos de una sesión no sobrevive; por eso
  nace este archivo — para que las quejas/sugerencias tengan casa durable y compartida.

## Rescatado del HUD de axon-master (2026-08-30) — PARA TRIAGE de cortex-master
> Estaban SOLO en la lista de TODOs (scratch) de la sesión axon-master, no en este backlog durable.
> Se rescatan verbatim para no perderlos al resetear ese HUD. cortex-master: triar (¿vivo/hecho/stale?).
- [ ] Retomar `cerebro-multi-agente-grok` sobre develop (estaba marcado "NO hoy").
- [ ] Estándar `conocimiento-propio` por sesión master (ya hay rastro en este doc — reconciliar).
- [ ] Propagar molde canónico del CLAUDE.md: árbol gigante→MEMORY + repunte del parity-check.
- [ ] Codificar el molde canónico del CLAUDE.md como ESTÁNDAR del brain.
- [ ] Hook `leer-no-grepear-skills` (grep-guard) con batería de tests.
- [ ] games-master: QA visual final + prueba en vivo del @import (unjordi).
- [ ] cps: integración coordinada DevelopUnjordi→develop (con OK).
- [ ] Aplicar molde canónico a cenam_contnac + fluxcore (fan-out).
- [ ] powerscripts: quitar guards por-repo (es PERSONAL → hereda del global).
- [ ] fluxcore (registros_bats_y_buses): sincronizar brain por el flujo + mini + marca.
- [ ] REDISEÑO del auto-sync (aviso-drift) — el mayor hueco del cerebro (ver diseno-rediseno-auto-sync-46).
