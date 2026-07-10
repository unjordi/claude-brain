# Debug: el renombrar (c/d) NO surte efecto en Linux (KDE Plasma 6)

**Síntoma (reportado por unjordi, 2026-07-10, tras instalar el widget en su Linux):** el widget
"quedó súper bonito" pero **el renombrado por clic-secundario de proyecto (c) y sesión (d) no funciona**.
En **macOS sí funciona** (QA en vivo ✓). Windows sin QA aún. Esto es para debuggear **directo en la
máquina Linux** con el repo clonado.

## Dónde vive el código (`src/plasmoid/contents/ui/main.qml`)
- **Menús de clic-secundario:** proyecto → `MouseArea acceptedButtons: LeftButton|RightButton` (~1232),
  `if (mouse.button === Qt.RightButton) projMenu.popup()` (~1235), `QQC2.Menu projMenu` (~1239).
  Sesión → equivalente `sessMenu` (~1291-1303).
- **Diálogo:** `Kirigami.PromptDialog { id: renameDialog }` (~949); `startRename()` (~308),
  `applyRenameFromDialog()` (~314).
- **Escritura del alias:** `renameProject`/`renameSession` (~278/289) → `writeAliasMap(file, map)` (~270)
  → `writeAliasSource.connectSource(cmd)` (~274). El engine es **`Plasma5Support.DataSource`
  `engine: "executable"`** (`id: writeAliasSource`, ~130); su `onNewData` (~133) hace
  `disconnectSource(source); root.forceRefresh()`.
- **cmd de escritura (~273):** `mkdir -p "<aliasDir>" && printf '%s' '<json-escapado>' > "<aliasDir>/<file>"`.
- **`aliasDir` (~49):** literal `"${CLAUDE_CONFIG_DIR:-$HOME/.claude}"` — se expande **dentro del shell**
  (el engine executable corre vía `sh -c`), por eso funciona tanto en `cat` (lectura) como en el `printf`
  (escritura). NO es el bug (a menos que el engine no corra por sh).
- **`forceRefresh()` (~257):** `refreshRunner.connectSource("systemctl --user start claude-quota.service")`.
- **Data layer (compartido, NO QML):** el fetch lee `~/.claude/proyectos-alias.json`; **`sessions-extract.js`
  lee `~/.claude/sesiones-alias.json`** (esto último es NUEVO de este release).

## Cómo debuggear — AÍSLA la capa (en orden)
1. **¿Aparece el menú?** Clic-secundario en una fila de proyecto y en una fila de sesión (dropdown
   desplegado). Si NO aparece → capa de UI (QQC2.Menu.popup() / imports en Plasma 6). Corre el plasmoide
   con logs QML: `QT_LOGGING_RULES="qml.debug=true" plasmoidviewer -a <ruta-del-paquete>` o mira
   `journalctl --user -f -t plasmashell` mientras interactúas (busca errores de `projMenu`/`sessMenu`
   sin id, o `Kirigami.PromptDialog`).
2. **¿Se ESCRIBE el archivo de alias?** Tras renombrar, en una terminal:
   `cat ~/.claude/proyectos-alias.json` y `cat ~/.claude/sesiones-alias.json`.
   - **Si NO se escribe** → el `writeAliasSource` (engine executable, WRITE) no corre. Sospechas:
     (a) el engine `executable` de Plasma 6 quizá no ejecuta el redirect `>` / está restringido —
     PERO la LECTURA por `cat` sí funciona (el widget muestra datos), así que el engine corre; confirma
     que un comando con `>` no es un caso distinto. (b) **Dedup del DataSource:** `connectSource` con
     una fuente que ya está conectada NO re-ejecuta; si `onNewData` no dispara (un `printf`/`>` sin
     stdout podría no emitir `newData`), la fuente queda conectada y un 2º intento igual es no-op —
     revisa `writeAliasSource.connectedSources`. Prueba: loguea `cmd` (con `console.log`) y córrelo a
     mano en terminal — ¿escribe el archivo?
   - **Si SÍ se escribe** (contenido correcto) → la escritura está bien; el problema es refresh/extractor
     (ve al 3).
3. **Archivo escrito pero el nombre NO cambia en el widget** → refresh o extractor:
   - Corre el fetch a mano: `just refresh` (o `systemctl --user start claude-quota.service`), luego
     `jq '.projects[].project' ~/.cache/claude-quota/stats.json` (¿cambió el nombre?) y
     `jq '.[].label' ~/.cache/claude-quota/sessions.json` (¿aplicó el alias de sesión?).
   - **CRÍTICO (misma lección que el redeploy del fetch b1a/b2):** el **`sessions-extract.js` DESPLEGADO**
     (junto al fetch instalado, no el del repo) debe ser el que LEE `sesiones-alias.json`. Si el widget
     se instaló de un build viejo, el extractor ignora el alias → **el rename de SESIÓN nunca se ve**
     aunque el JSON se escriba. Reinstala (`./install.sh`) para redesplegar el extractor + el fetch.
   - **Asimetría diagnóstica:** el rename de PROYECTO usa el fetch (que ya leía `proyectos-alias.json`
     desde antes) → podría funcionar; el de SESIÓN depende del extractor nuevo. Si proyecto SÍ y sesión
     NO → casi seguro es el extractor viejo desplegado (reinstalar).
4. **`forceRefresh()` throttled:** `systemctl --user start claude-quota.service` sobre un servicio ya
   activo/recién corrido puede ser no-op inmediato. Si el archivo se escribe y el fetch a mano SÍ
   refleja el cambio, pero el widget tarda ~5 min → es el refresh, no el rename.

## Sospechosos rankeados
1. **Extractor/fetch desplegado viejo** → el alias se escribe pero no se lee (sobre todo SESIÓN).
   *Test:* el JSON se escribe pero el nombre no cambia ni tras `just refresh` → reinstalar.
2. **WRITE por el engine `executable` no dispara en Plasma 6** (dedup / redirect / confinamiento).
   *Test:* el JSON de alias no aparece en `~/.claude/` tras renombrar.
3. **Menú/diálogo no abre** (QQC2.Menu.popup / PromptDialog en Plasma 6). *Test:* no sale el menú.
4. **forceRefresh no-op** (systemctl start sobre servicio activo). *Test:* cambio visible solo tras 5 min.

## Referencia de paridad (cómo lo hace macOS, que SÍ funciona)
`macos/Sources/ClaudeQuota/QuotaModel.swift`: `renameProject`/`renameSession` escriben con `FileManager`
**directo** (sin shell) y `writeMap` (sortedKeys); el refetch es el `onRefresh` que corre el fetch como
`Process`. La NOVEDAD de Linux es escribir vía el **DataSource executable** — esa ruta de ESCRITURA es la
que hay que escrutar (la de lectura ya está probada porque el widget muestra datos).

## Al arreglarlo
Es un slice `fix/...` → ramita → MR → develop (squash). Actualiza esta nota con la causa raíz encontrada,
y si aplica súbelo también a Windows (mismo patrón de escritura). Borra esta nota cuando quede resuelto y
QAeado en Linux.
