# Auditoría del ciclo de vida del cerebro cortex (INSTALL → LIMPIEZA → UPDATE → AUTOSYNC)

> Dictamen READ-ONLY · 2026-08-29 · repo `unjordi/cortex` · `main` @ `472e9c7`
> Auditor: Ingeniería de Calidad (procesos + análisis de algoritmos). NO se modificó código.
> Insumo verificado contra el CÓDIGO real (no solo los flowcharts) + 2 sub-auditorías paralelas
> (paridad Linux/Windows; flowcharts-vs-código).

---

## 1. Resumen ejecutivo

**El LOOP.** La máquina del screenshot corre una **build vieja del widget (v0.2.351)** cuyo clon de
instalación quedó bajo el **nombre pre-rename `~/.claude-brain`** (nunca migró a `~/.cortex`). En esa
build, `resolveClonePath` **no tiene** el fallback a `~/.claude-brain` (el fix #322 llegó DESPUÉS), así
que no encuentra el clon → `canSelfUpdate=false` → el botón ⬆ es **inerte** y solo muestra "actualiza a
mano". El otro botón, **"Curar cerebro global"**, corre el `install-brain.sh` **empaquetado en el .app
viejo** (sin `git pull`): reinstala el cerebro VIEJO y lo mide contra el **catálogo hardcodeado VIEJO**
→ si ese catálogo drifteaba (backlog #4, real en su día) o falta `jq`, la cuenta de "faltantes" nunca
baja. Resultado: `updateAvailable` sigue `true` (main avanzó) **y** `globalMissing ≥ 1` para siempre.
Curar+actualizar es un **punto fijo de no-convergencia**: ninguno de los dos botones ejecuta jamás la
ÚNICA acción que rompe el loop —traer código nuevo y reinstalar desde él—. Los fixes #322/#323/#317 SÍ
funcionan, pero **solo en máquinas que ya escaparon una vez**; para la población exacta que cayó en el
rename, no hay carril de auto-cura.

**El doble-widget.** Durante el rename #312 un update instaló el app nuevo (`cortex`) **sin barrer** el
app + LaunchAgent viejos (`claude-brain`); ambos tienen `RunAtLoad` → dos íconos en la barra. El barrido
que lo cierra (#317) vive DENTRO del `install.sh` nuevo → **solo corre cuando el install.sh nuevo corre**
→ una máquina atascada (que no puede self-update) nunca lo ejecuta y conserva los dos widgets. Mismo
chicken-and-egg que el clon: arreglado hacia adelante, no retroactivamente.

**Paridad (buena noticia):** en `main` @ `472e9c7`, los 3 OS están a la par — #322/#323 presentes en
macOS, Linux y Windows; los catálogos de hooks de los 3 widgets son **idénticos entre sí y al
`brain/hooks/MANIFEST`** (21 global + 4 repo), y **ninguno** lista ya `precompact-volcar-estado`. Es
decir: **backlog #4 (catálogo) ya está resuelto en HEAD** — el drift solo vive en la build vieja
instalada. Lo que sí sigue roto en HEAD es la **asimetría bash-vs-widget** (los scripts bash del cerebro
NO tienen el fallback #322), el **stamp de versión que regresa al curar**, el **acoplamiento al asset
precompilado** y las **mentiras del flowchart 01**.

---

## 2. Explicación de raíz del LOOP — máquina de estados

### 2.1 Variables de estado

| Variable | Valores |
|---|---|
| **CLON** | ausente · viejo (`~/.claude-brain`) · nuevo (`~/.cortex`) |
| **BUILD** widget | vieja (`< #322/#323`, p.ej. v0.2.351) · nueva (`≥ #329`) |
| **CEREBRO** global | sano · incompleto |

La **acción de convergencia** (única que lleva a `CLON=nuevo ∧ BUILD=nueva ∧ CEREBRO=sano`) es:
*traer `main`, migrar el clon a `~/.cortex`, bajar/rebuild el .app nuevo y re-correr `install-brain`
desde el clon real*. La realiza `bootstrap.sh` (one-liner) o el `runUpdate` de una build **nueva**.

### 2.2 El fixed-point que NO converge

Estado del screenshot: **CLON=viejo, BUILD=vieja, CEREBRO=incompleto(2)**.

Qué ofrece la build **vieja**:

- **Botón ⬆ "Actualizar":** `canSelfUpdate` en la build vieja = `¿existe embedded? ¿$CLAUDE_BRAIN_DIR?
  ¿~/.cortex?` — todos NO (el embedded apunta al runner de CI; `CLAUDE_BRAIN_DIR` no se exporta en
  mac/linux; `~/.cortex` no existe) y **sin** el fallback a `~/.claude-brain` (#322 no está en esa build)
  → `false`. `runUpdate()` cortocircuita en `guard canSelfUpdate` (`Updater.swift:110`) → escribe
  "actualiza a mano" y **no hace nada**. ⇒ *inerte* (explica el "— actualiza a mano" del screenshot,
  `Updater.swift`/`PopoverView.swift:249-251`).
- **Botón 🩹 "Curar cerebro global (2)":** `healBrain()` corre el `install-brain.sh` **del bundle**
  (`Bundle.main/brain/install-brain.sh`, `PopoverView.swift:1134-1145`). **No hay git.** Reinstala el
  cerebro VIEJO empaquetado y re-inspecciona con el `BrainInspector.knownGlobalHooks` **VIEJO**. Si ese
  catálogo esperaba 2 hooks que el instalador viejo no cableaba (drift #4) o falta `jq` (cableado se
  omite, `install-brain.sh:111`), `globalMissing` **no baja de 2**. Peor: re-estampa `.brain-version`
  con `COUNT=0` (§3, C3).

Conclusión: en `(CLON=viejo, BUILD=vieja)` **ningún botón alcanza la acción de convergencia**.
`updateAvailable` se mantiene `true` (GitHub main = `472e9c7` ≠ `version.json` viejo) y
`globalMissing ≥ 1`. **Curar → actualizar → mismo estado. Ese es el loop.**

### 2.3 La ÚNICA acción que rompe el loop (y por qué el sistema no la ofrece)

Romper el loop exige **intervención MANUAL externa**:

```
curl -fsSL https://raw.githubusercontent.com/unjordi/cortex/main/bootstrap.sh | bash
```

`bootstrap.sh` **migra** `~/.claude-brain → ~/.cortex` + reapunta el remote (`bootstrap.sh:25-41`),
**alinea a origin/main** (`:80-88`) y corre `macos/install.sh` (`:91-97`) que **baja el .app nuevo** +
re-corre el `install-brain` nuevo. Tras eso `BUILD=nueva` → `canSelfUpdate=true` (el nuevo
`resolveClonePath` sí halla el clon) → converge en adelante.

El sistema **NO surface-a esta acción**: el tooltip "a mano" dice `git pull && ./install.sh`
(`PopoverView.swift:251`) pero **no dice DÓNDE** está el clon (`~/.claude-brain`, oculto) ni que hay que
pasar por **bootstrap** para migrarlo (un `git pull && install.sh` manual actualiza pero **deja el clon
con el nombre viejo** — ni `install.sh` ni el `install-brain.sh` migran; solo `bootstrap.sh` y el
`runUpdate` **nuevo** lo hacen). El escape existe pero es invisible → el usuario razonablemente concluye
"curé y actualicé y sigue igual".

---

## 3. Hallazgos INDIVIDUALES (por eslabón / widget)

> Formato: **[SEV] · qué · dónde · por qué · recomendación**

### INSTALL

- **[MEDIO] `install-brain.sh` NO siembra ni migra el clon.** `brain/install-brain.sh` (todo el
  archivo). El clon `~/.cortex` (y su migración desde `~/.claude-brain`) lo hace **solo** `bootstrap.sh:16-41,
  80-88`. *Por qué:* el modelo mental (y el prompt de esta auditoría) asume que "install-brain siembra el
  clon" — es falso. Correr `install-brain` a secas (o el botón Curar, que corre justo ese script) **nunca**
  establece el clon → el update-por-widget y el autosync-por-clon quedan sin fuente. No hay un
  "ensure-clone" idempotente en ningún `install.sh`. *Rec:* añadir un `ensure_clone()` idempotente (clona/
  migra si falta) al `install.sh`/`macos/install.sh`, o documentar explícito que el clon es responsabilidad
  exclusiva de `bootstrap.sh`.

- **[BAJO] El barrido de PATH en rc's asume marcadores de eras concretas.** `install.sh:56-76`,
  `macos/install.sh:104-127`. *Por qué:* el comentario admite que el rename #312 renombró
  mecánicamente un marcador que **nunca se escribió** → el bloque real de la era `claude-brain` quedaba
  sin barrer (ya corregido con `old_markers`). Riesgo residual bajo pero es deuda de "adivinar el string
  histórico". *Rec:* barrer por patrón (`grep -E 'cortex|claude-(brain|quota).*\.local/bin'`) en vez de
  strings exactos.

### LIMPIEZA (#317 + uninstall)

- **[MEDIO] El barrido de artefactos viejos es forward-only y por nombre-adivinado.**
  `macos/install.sh:75-99` (borra `Claude Brain Widget.app`, labels `io.github.unjordi.claude-brain[.widget]`,
  cachés `claude-brain`), `install.sh:141-154` (Linux: `OLD_PLASMOID_ID_BRAIN`, units `claude-brain.*`).
  *Por qué:* (1) **solo corre cuando el install.sh nuevo corre** → una máquina atascada (§2) nunca lo
  ejecuta y conserva el doble-widget; (2) barre por **nombres históricos adivinados** — si el app/label
  intermedio real difería, el barrido lo pierde y el doble-widget sobrevive **incluso** tras un install
  nuevo exitoso. *Rec:* además del barrido por-nombre, un barrido por-**patrón** de LaunchAgents/plasmoides
  (`io.github.unjordi.*` que no sea el ID canónico) con confirmación; y ejecutarlo de forma independiente
  del resto del install (ver Wave 1).

### UPDATE — macOS (`Updater.swift`)

- **[CRÍTICO] En la build vieja, `canSelfUpdate=false` + heal-sin-git = fixed-point.** (Núcleo del loop,
  §2.) `Updater.swift:59-68` (resolveClonePath sin fallback en la build vieja), `:109-114` (guard inerte),
  `PopoverView.swift:1134-1168` (heal corre el bundle, sin git). *Rec:* ver Wave 1 (escape discoverable +
  no depender de que la build vieja se auto-cure, que es imposible).

- **[ALTO] `healBrain` REGRESA el sello de versión.** `install-brain.sh:245-252`
  (`COUNT=$(git -C "$SCRIPT_DIR" rev-list --count HEAD || echo 0)`). Cuando el heal corre el
  `install-brain.sh` **del bundle**, `SCRIPT_DIR` = `…/Cortex Widget.app/Contents/Resources/brain`, que
  **no es un repo git** → `COUNT=0` → estampa `~/.claude/.brain-version = "0.2.0"` + fecha de hoy,
  **regresando** el `v0.2.351` real y mintiendo (0 commits). El widget muestra ese sello
  (`PopoverView.swift:1070-1071`, `BrainInspector.swift:144-150`). *Por qué:* corrompe el único indicador
  de "qué versión del brain tengo" y cualquier comparación futura basada en él. *Rec:* estampar la versión
  desde el **clon real** (`$CLAUDE_BRAIN_DIR`/`~/.cortex`/`~/.claude-brain`), o si `SCRIPT_DIR` no es git,
  **no re-estampar** (conservar el sello previo) en vez de escribir `.0`. Mapea a backlog **#5**.

- **[MEDIO] `runUpdate` usa `merge --ff-only` mientras `bootstrap` fuerza-alinea.** `Updater.swift:126`
  (`git merge --ff-only origin/main`) vs `bootstrap.sh:84` (`checkout -B main origin/main`). *Por qué:* un
  clon que quedó en una rama leftover o con commits locales (dev/QA) hace **fallar el ff-only para siempre**
  → el botón ⬆ "no completa" (log a `/tmp/cortex-update.log`, mensaje genérico a los 60 s,
  `Updater.swift:135-139`) sin diagnóstico visible, mientras que un `bootstrap` lo arregla. *Rec:* alinear
  el widget a `origin/main` como bootstrap (o al menos surface-ar la causa del ff fallido).

- **[MEDIO] Apply acoplado al asset PRECOMPILADO (ventana de staleness).** `runUpdate` hace `git ff` sobre
  `~/.cortex` y luego `macos/install.sh` (`Updater.swift:126-127`), que por DEFAULT **baja el .app
  precompilado** de `releases/download/macos-latest/...` (`macos/install.sh:276-291`), **no** compila el
  fuente recién jalado. `release-macos.yml` reconstruye en cada push a main (ya cerraron el bug del
  filtro de paths, comentario `:6-13`), pero entre el push y la publicación del asset —o si el CI falla— el
  .app instalado **queda atrás de main** → `updateAvailable` sigue `true` → loop residual. Además el `git
  ff` avanza el CLON más allá del .app instalado → `.brain-version` (cuenta del clon) y `version.json` (del
  asset) **divergen aún más**. *Rec:* que `install.sh` verifique `build-sha(asset) == HEAD(clon)`; si no,
  caer a `--build`; o que `runUpdate` pase `--build` cuando detecta que avanzó el ff. Mapea a **#5**.

### UPDATE — Linux (`main.qml`) y Windows (`Updater.cs` / `install.ps1`)

- **[INFO] Paridad COMPLETA en HEAD.** (Sub-auditoría de paridad.) #322 (fallback old-name) y #323
  (rename del clon on-apply) **presentes en los 3 OS**: `main.qml:1120-1150` (`mv → $HOME/.cortex`,
  fallback `$HOME/.claude-brain`), `Updater.cs:100-111` (fallback `%LOCALAPPDATA%\claude-brain-repo`),
  `Updater.cs:249-259` (Move-Item → `cortex-repo`). Catálogos de hooks idénticos entre sí y al MANIFEST.
  Asimetría **intencional** de método de apply: macOS/Windows bajan binario precompilado como primario;
  Linux hace `git ff + install.sh` (el plasmoide vive dentro de plasmashell, no hay binario que swappear).
  *No requiere acción* salvo la deuda compartida de §4 (C2/C3/C4).

### AUTOSYNC (`aviso-drift-cerebro.sh`, `drift-cerebro-comun.sh`)

- **[ALTO] El autosync bash está MUERTO en la máquina en limbo del rename.** `drift-cerebro-comun.sh:51`
  y `:197` (`BRAIN_DIR="${CLAUDE_BRAIN_DIR:-$HOME/.cortex}"`, **sin** fallback a `~/.claude-brain`). En la
  máquina del screenshot `~/.cortex` no existe y `CLAUDE_BRAIN_DIR` no está exportada (bootstrap.sh **no**
  la exporta en mac/linux; solo `bootstrap.ps1` lo hace en Windows) → `SYNC` no existe → `STATUS=no-source`
  → **silencio** (fail-open). *Por qué:* justo el eslabón que debería detectar/curar drift está ciego en la
  población afectada. Es la **asimetría** con los widgets, que sí recibieron el fallback #322. *Rec:* dar al
  resolver bash el MISMO fallback (ver §4 C2). Misma deuda en `verificar-cerebro.sh:26`,
  `proteger-fuente-cerebro.sh:39`, `exportar-sesion-master.sh:105`, `sesiones-master/install-hook.sh:19`.

- **[MEDIO] No existe ningún auto-updater del cerebro GLOBAL ni del clon.** `aviso-drift-cerebro.sh`
  solo sincroniza la **copia por-repo** en repos con marca `.claude/repo-compartido`
  (`drift-cerebro-comun.sh:57-77`), y `drift_skills_global` **solo AVISA** de drift de skills global
  (`:195-236`). *Por qué:* la frescura del cerebro GLOBAL y del clon depende 100% del update-por-widget o
  del bootstrap manual → no hay red automática que rescate una instalación global vieja. *Rec:* un chequeo
  SessionStart que, si el clon está atrás de origin/main, AVISE con el one-liner exacto (aprovechando que
  este hook ya corre en cada resume/compact).

### VERSIÓN / IDENTIFICADORES

- **[ALTO] Tres identificadores de versión sin reconciliar.** `~/.claude/.brain-version`
  (`install-brain.sh:245-249`, cuenta de commits del clon), `version.json.sha`/`version`
  (`make-app.sh:38-45`, del asset con que se buildeó el .app) y el SHA de `commits/main` de GitHub. La UI
  **muestra** `.brain-version` (`PopoverView.swift:1070`), pero la **detección de update usa** `version.json`
  vs GitHub (`Updater.swift:87-104`). *Por qué:* el usuario "actualiza" y `.brain-version` no lo refleja (y
  viceversa: cura y la versión del widget no cambia) → la UI cuenta dos historias distintas de "qué tan al
  día estoy". *Rec:* reconciliar: mostrar los 3 con su rol, o derivar `.brain-version` del mismo commit que
  el `version.json` instalado. Mapea a **#5**.

---

## 4. Hallazgos COLECTIVOS / de costura

- **[CRÍTICO · C1] Chicken-and-egg sin carril de auto-cura para la población del rename.** Los fixes
  #322 (`resolveClonePath` fallback), #323 (rename on-apply) y #317 (barrido) **solo ayudan a máquinas
  que ya escaparon la build vieja una vez**. La build vieja no puede self-update (no tiene #322) y el heal
  nunca trae código → **no hay acción in-app que rompa el loop**. Confluencia de: `Updater.swift:59-68`
  (build vieja sin fallback) + `PopoverView.swift:1134` (heal sin git) + `macos/install.sh:75-99` (barrido
  forward-only). *Rec (Wave 1):* (a) surface-ar el one-liner de bootstrap como el escape real, con la ruta
  del clon **descubierta** (no `git pull && ./install.sh` a ciegas); (b) blindar la build NUEVA para que
  esto no recurra (ensure-clone + no depender del asset stale). Ver plan.

- **[ALTO · C2] Asimetría bash-vs-widget en la resolución del clon.** Los 3 widgets tienen el fallback
  `~/.claude-brain`; **todo el tooling bash del cerebro NO** (`drift-cerebro-comun.sh:51,197`,
  `verificar-cerebro.sh:26`, `proteger-fuente-cerebro.sh:39`, `exportar-sesion-master.sh:105`,
  `sesiones-master/install-hook.sh:19`). En una máquina en limbo, autosync + verificación + protección de
  fuente quedan ciegos (fail-open silencioso). *Rec:* una función compartida `resolve_brain_dir()` (en
  `drift-cerebro-comun.sh` o una lib) con el orden `$CLAUDE_BRAIN_DIR → ~/.cortex → ~/.claude-brain`, y que
  todos la usen. **1 lib + N sustituciones mecánicas.**

- **[ALTO · C3] `.brain-version` se corrompe al curar (COUNT=0 desde un dir no-git).** Cruce de
  `install-brain.sh:245-252` con `PopoverView.swift:1134` (heal corre el bundle no-git). Ver hallazgo
  individual UPDATE-macOS. *Rec:* estampar desde el clon real o no re-estampar si `SCRIPT_DIR` no es git.

- **[MEDIO · C4] Update acoplado al asset precompilado (ventana de staleness).** Ver hallazgo
  UPDATE-macOS. Cross-OS (macOS + Windows bajan asset; Linux no). *Rec:* verificar `build-sha == HEAD` en
  el install, fallback a `--build`.

- **[MEDIO · C6] El flowchart 01 MIENTE respecto al código.** (Sub-auditoría flowcharts.)
  `docs/flowcharts/01-instalacion-actualizacion-del-cerebro.dot`:
  - Nodo `WID` (`:135-136`): dice que el widget **lee `~/.claude/.brain-version`** para detectar updates.
    **Falso** — usa `version.json.sha` vs GitHub `commits/main` (`Updater.swift:87-104`,
    `docs/autoupdate.md:8-10`). Conflaciona 2 de los 3 identificadores y **contradice el doc hermano**.
  - La migración `~/.claude-brain → ~/.cortex` on-apply (#322/#323) **no aparece en ningún nodo**.
  - `resolveClonePath` + `canSelfUpdate=false → "a mano"` (y que el fix solo corre ON update) **no está
    documentado** en el diagrama ni en `autoupdate.md`; ambos asumen que el clon siempre está en `~/.cortex`.
  - El rol de `bootstrap.sh` como **sembrador/migrador del clon** no se muestra (nodo `BOOT` sub-descrito
    en 01 y 02).
  - La ruta **Heal** falta del diagrama 01 (sí está en `autoupdate.md:20-21`).
  - Único `precompact-volcar-estado` (en `mapa-cerebro.md:84`) está bien enmarcado como **retirado** — no
    es stale. *Rec:* corregir el nodo `WID`, agregar migración de clon + bootstrap-siembra-clon +
    resolveClonePath/canSelfUpdate + Heal; sincronizar `autoupdate.md` y `mapa-cerebro.md`. Mapea a la norma
    doc=realidad y complementa **#4** (mitad-doc; el catálogo en sí ya está sano en HEAD).

- **[BAJO · C7] Backlog #4 (catálogo del widget) ya está resuelto en HEAD, pero sigue HARDCODEADO.** Los
  3 catálogos casan hoy con el MANIFEST, pero son 3 listas manuales (`BrainInspector.swift:54-66`,
  `main.qml:1067-1068`, `BrainInspector.cs:37-52`) que **volverán a driftar** en el próximo cambio de
  MANIFEST (fue exactamente lo que produjo el "OTROS" + `precompact` de la build vieja). *Rec:* derivar el
  catálogo del MANIFEST (embebido en el bundle) en vez de hardcodearlo — y extender el parity-check
  (**#7**) a hooks 🔒/🔔, no solo skills, para que un drift de hook falle CI.

---

## 5. Plan de implementación — ordenado por prioridad y dependencia

Notación: **[1f]** = un archivo, mecánico, paralelizable por agente aislado. **[3OS]** = toca los 3
widgets a la vez → riesgo de asimetría, un solo agente o revisión conjunta.

### OLA 1 — Escape + saneo de la resolución del clon (RAÍZ, desbloquea el resto)

1. **[CRÍTICO] Escape discoverable para máquinas atascadas (C1).** *No hay parche que alcance la build
   vieja ya instalada* → el entregable es (a) que el tooltip/panel "a mano" y `docs/autoupdate.md` den el
   **one-liner de bootstrap** exacto como el escape real, y (b) que el mensaje **descubra y muestre la ruta
   del clon** (`~/.claude-brain` si existe). Toca `PopoverView.swift:251` + strings equivalentes en KDE/
   Windows **[3OS]** + `docs/autoupdate.md` **[1f]**. *Depende de nada; desbloquea la salida del loop.*
2. **[ALTO] Fallback `~/.claude-brain` en el resolver BASH (C2).** Una `resolve_brain_dir()` compartida +
   sustituir los 5 usos. **[1f lib + N mecánicos]**, bash-only, sin riesgo de asimetría OS. *Reactiva
   autosync/verificación/protección en máquinas en limbo; habilita que la OLA-AUTOSYNC detecte el atasco.*

Las dos de la OLA 1 son independientes entre sí → **en paralelo**.

### OLA 2 — Que la build NUEVA converja limpio (depende de que el clon se resuelva bien)

3. **[ALTO] `.brain-version` no debe regresar al curar (C3/#5).** `install-brain.sh:245-252`: estampar
   desde el clon real o no re-estampar si `SCRIPT_DIR` no es git. **[1f]**.
4. **[ALTO] Widget alinea a `origin/main` (o surface-a el ff fallido) (U3).** `Updater.swift:126` +
   `main.qml` + `Updater.cs`. **[3OS]**.
5. **[MEDIO] Cerrar la ventana de staleness del asset (C4/#5).** `macos/install.sh:276-291` +
   `windows/install.ps1`: verificar `build-sha == HEAD`, fallback `--build`. **[3OS parcial]** (Linux ya
   compila/ff).

Las 3, 4 y 5 tocan zonas distintas → **paralelizables** entre sí, pero DESPUÉS de la OLA 1 (necesitan que
el clon se resuelva bien).

### OLA 3 — Verdad de la doc + higiene (hojas, todo paralelizable)

6. **[MEDIO] Corregir flowchart 01 + `autoupdate.md` + `mapa-cerebro.md` (C6/#4-doc).** docs-only. **[1f
   c/u]**.
7. **[MEDIO] Catálogo del widget DERIVADO del MANIFEST + parity-check de hooks (C7/#4/#7).**
   `BrainInspector.{swift,cs}` + `main.qml` leen el MANIFEST embebido; extender
   `docs/flowcharts/verificar-arbol-sync.sh` a hooks. **[3OS + 1f CI]**.
8. **[BAJO] Barrido de artefactos por patrón + independiente del install (C5/#317).**
   `macos/install.sh:75-99`, `install.sh:141-154`. **[1f c/u]**.
9. **[BAJO] Resto de backlog:** #6 (env vars `CLAUDE_SESSIONS_DRIVE` — ya implementado vía
   `persist_env_active`, `install-brain.sh:217-236`; solo verificar), #12 (skills drift — `sincronizar` +
   `drift_skills_global` ya cubren; falta el auto-apply de skills), #5 (mostrar/reconciliar las 3
   versiones — se completa con 3+5). **[varios 1f]**.

### DAG resumido

```
OLA1: [1 escape]───┐        (paralelas)
      [2 bash fb]──┤
                   ▼
OLA2: [3 stamp] [4 ff-align] [5 asset]   (paralelas, tras OLA1)
                   ▼
OLA3: [6 docs] [7 catálogo←MANIFEST] [8 barrido] [9 backlog]  (hojas, paralelas)
```

---

## 6. Riesgos y no-goals

- **NO "arreglar" la build vieja ya instalada.** Es imposible por código; cualquier fix es *forward-only*.
  El objetivo real es (a) el escape discoverable y (b) blindar la build nueva. No prometer auto-cura
  retroactiva.
- **NO romper la propagación a clones sin brain global.** Los hooks `both` viajan por-repo con su cláusula
  de dedupe (`brain/hooks/MANIFEST:9,23`); al tocar el catálogo/MANIFEST, respetar el modelo de tiers o se
  rompe el "correo" a repos COMPARTIDOS.
- **`resolveClonePath`/resolver bash es fail-open a propósito** — un fix que lo haga fail-closed (bloquear
  cuando no halla clon) rompería máquinas sanas sin clon (p. ej. `--no-brain`). Mantener fail-open; el
  fallback solo AMPLÍA los candidatos, no endurece.
- **El asset precompilado como primario es intencional** (instalar sin Xcode/Swift, paridad con Windows).
  El fix C4 debe **preferir** el asset y solo caer a `--build` cuando el `build-sha` no casa — no eliminar
  la descarga.
- **`aviso-drift-cerebro` NO debe escribir al árbol de un repo compartido fuera de la mini-develop**
  (`drift-cerebro-comun.sh:127-172`): cualquier auto-cura global nueva debe AVISAR, no auto-commitear en
  ramas que no sean `Develop<Usuario>`.
- **`main` es release-only** — nada de este plan justifica un push directo; cada fix va por ramita → MR a
  `develop` con OK explícito (norma del repo).

---

### Anexo — inventario de lo leído (evidencia)

INSTALL: `install.sh`, `macos/install.sh`, `brain/install-brain.sh`, `bootstrap.sh`, `brain/install-brain.ps1`,
`windows/install.ps1`, `macos/make-app.sh`. UPDATE: `macos/Sources/Cortex/Updater.swift`,
`BrainInspector.swift`, `PopoverView.swift` (fragmentos 240-315, 1088-1194), `src/plasmoid/contents/ui/main.qml`,
`windows/src/Cortex/Updater.cs`, `BrainInspector.cs`, `PopupForm.cs`. LIMPIEZA: bloques #317 en los
`install.sh` + `uninstall.sh`. AUTOSYNC: `brain/hooks/aviso-drift-cerebro.sh`, `drift-cerebro-comun.sh`.
FUENTE DE VERDAD: `brain/hooks/MANIFEST`, `brain/hooks/RETIRED`, `brain/VERSION`. CI: `.github/workflows/release-macos.yml`.
FLOWCHARTS/DOC: `docs/flowcharts/01-…`, `02-…`, `CONVENCIONES.md`, `docs/autoupdate.md`, `docs/mapa-cerebro.md`.
