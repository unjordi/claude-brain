import QtCore
import QtQuick
import QtQuick.Layouts
import QtQuick.Controls as QQC2
import org.kde.plasma.plasmoid
import org.kde.plasma.plasma5support as P5Support
import org.kde.plasma.core as PlasmaCore
import org.kde.kirigami as Kirigami
import org.kde.plasma.components as PC3

PlasmoidItem {
    id: root

    // ---------- Data: límites (state.json) ----------
    property var snapshot: null
    property string snapshotError: ""
    // ---------- Data: stats locales de ccusage (stats.json) ----------
    property var stats: null
    // ---------- Data: vista sincronizada entre máquinas (stats-global.json) — feature (e) ----------
    // Producida por el bloque "(e) Sync" del fetch (fusión de los snapshots de cada máquina vía la
    // carpeta de nube). null si el sync no está activo / no existe el archivo (fail-open: el toggle
    // "todas las máquinas" no se ofrece). Espeja QuotaModel.statsGlobal del PopoverView.swift.
    property var statsGlobal: null
    // (e) Toggle "todas las máquinas": cuando está activo y hay stats-global.json, los recomputes de
    // rango (rDays y lo derivado) leen de la vista combinada en vez del stats local. Espeja @State useGlobal.
    property bool useGlobal: false
    // Fuente de stats ACTIVA según el toggle (e). Si se pidió global pero no hay sync, cae a local.
    // Espeja `activeStats` del PopoverView.swift. rSessionCount/chats se quedan SIEMPRE locales.
    readonly property var activeStats: (useGlobal && statsGlobal) ? statsGlobal : stats
    // ¿Hay vista sincronizada con datos? (gobierna si se ofrece el par de píldoras 🖥/☁️).
    readonly property bool hasGlobal: statsGlobal && statsGlobal.machines && statsGlobal.machines.length > 0
    // Cuántas máquinas aportaron a la vista combinada (para el conteo en la píldora ☁️).
    readonly property int globalMachineCount: hasGlobal ? statsGlobal.machines.length : 0
    // ---------- Data: chats del app de escritorio (chats.json) y sesiones de Claude Code
    // (sessions.json), ambos producidos por el fetch (chats-extract.js / sessions-extract.js). null
    // = aún no leído / no existe (fail-open: la pestaña Chats se oculta, el dropdown de sesiones sale vacío).
    property var chats: null
    property var sessions: null

    // ---------- Alias de renombrado (clic-secundario) ----------
    // Copias EN MEMORIA de los mapas que el data layer lee: proyectos-alias.json (lo lee el fetch)
    // y sesiones-alias.json (lo lee sessions-extract.js). Se releen en cada reload() (cat, fail-open a
    // {}). El widget los ESCRIBE al renombrar; escribir + refetch = el nombre nuevo se propaga. La
    // semántica espeja QuotaModel.swift (renameProject/renameSession/aliasMap). Base = CLAUDE_CONFIG_DIR
    // o ~/.claude, resuelta por el shell al leer/escribir (aliasDir).
    property var projAliasMap: ({})
    property var sessAliasMap: ({})
    // ¿La última escritura de alias fue de una SESIÓN? La fija writeAliasMap por el nombre de archivo y
    // la lee writeAliasSource para decidir el refresh: sesión → rápido (sessions-extract.js), proyecto
    // → fetch completo (afecta la agregación de tokens). Espeja el applyRename kind-aware del macOS.
    property bool lastAliasWasSession: false
    // Expresión de shell para la base de los mapas (idéntica a claude-brain-fetch / sessions-extract.js).
    readonly property string aliasDir: "${CLAUDE_CONFIG_DIR:-$HOME/.claude}"

    // ---------- Filtro de rango {hoy·7d·30d·∞} (Resumen/Modelos/Proyectos/Chats) ----------
    // rangeIdx: 0=hoy (daysBack 0), 1=7d (6), 2=30d (29), 3=∞ (sin recorte). Default ∞ (todo el histórico).
    // Espeja el enum TimeRange de PopoverView.swift. A ∞ todo coincide con lo que ya se mostraba.
    property int rangeIdx: 3
    readonly property var rangeLabels: ["hoy", "7d", "30d", "∞"]
    // Resumen del chat bajo el cursor (pie de la pestaña Chats).
    property string hoveredChatSummary: ""
    // Proyecto expandido en la pestaña Proyectos (muestra sus sesiones para resumir).
    property string expandedProject: ""

    property int currentTab: 0
    // Al abrir/volver a la pestaña Cerebro (idx 5) re-lee el estado real de ~/.claude (doc = realidad)
    // y chequea si hay versión nueva del widget (throttle 15 min dentro de checkUpdate).
    onCurrentTabChanged: if (currentTab === 5) { scanBrain(); checkUpdate() }

    readonly property string cacheDir: {
        const raw = "" + StandardPaths.writableLocation(StandardPaths.GenericCacheLocation)
        const stripped = raw.startsWith("file://") ? raw.substring("file://".length) : raw
        return stripped + "/claude-brain"
    }

    P5Support.DataSource {
        id: catSource
        engine: "executable"
        connectedSources: []
        onNewData: function(source, data) {
            if (source.indexOf("stats-global.json") !== -1) {
                // (e) Sync: presente solo si el sync está activo. Fail-open: ausente/roto -> se queda
                // null -> el toggle "todas las máquinas" no se ofrece. (Se chequea ANTES que stats.json.)
                if (data["exit code"] === 0 && data.stdout) {
                    try { root.statsGlobal = JSON.parse(data.stdout) } catch (e) {}
                }
            } else if (source.indexOf("stats.json") !== -1) {
                if (data["exit code"] === 0 && data.stdout) {
                    try { root.stats = JSON.parse(data.stdout) } catch (e) {}
                }
            } else if (source.indexOf("chats.json") !== -1) {
                // Fail-open: sin chats.json (rc!=0 / sin app de escritorio) -> se queda null (pestaña oculta).
                if (data["exit code"] === 0 && data.stdout) {
                    try { root.chats = JSON.parse(data.stdout) } catch (e) {}
                }
            } else if (source.indexOf("sessions.json") !== -1) {
                // Fail-open: sin sessions.json -> se queda null (el dropdown de sesiones sale vacío).
                if (data["exit code"] === 0 && data.stdout) {
                    try { root.sessions = JSON.parse(data.stdout) } catch (e) {}
                }
            } else if (source.indexOf("proyectos-alias.json") !== -1) {
                // Fail-open: sin archivo / JSON roto -> mapa vacío (no hay alias activo).
                var pm = {}
                if (data["exit code"] === 0 && data.stdout) { try { pm = JSON.parse(data.stdout) || {} } catch (e) { pm = {} } }
                root.projAliasMap = pm
            } else if (source.indexOf("sesiones-alias.json") !== -1) {
                var sm = {}
                if (data["exit code"] === 0 && data.stdout) { try { sm = JSON.parse(data.stdout) || {} } catch (e) { sm = {} } }
                root.sessAliasMap = sm
            } else {
                if (data["exit code"] === 0 && data.stdout) {
                    try { root.snapshot = JSON.parse(data.stdout); root.snapshotError = "" }
                    catch (e) { root.snapshotError = "parse: " + e }
                } else {
                    root.snapshotError = "cat rc=" + data["exit code"] + (data.stderr ? " " + data.stderr : "")
                }
            }
            disconnectSource(source)
        }
    }

    P5Support.DataSource {
        id: refreshRunner
        engine: "executable"
        connectedSources: []
        onNewData: function(source, data) { disconnectSource(source); reload() }
    }

    // Escritura de los mapas de alias (proyectos-alias.json / sesiones-alias.json). Reusa el engine
    // "executable" (igual que catSource lee con `cat`). Al TERMINAR la escritura dispara el refresh
    // — así el refetch relee el archivo YA escrito (evita la carrera write-vs-refetch). El refresh es
    // KIND-AWARE (espeja el applyRename de PopoverView.swift): renombrar una SESIÓN solo cambia su
    // etiqueta → refresh RÁPIDO (solo sessions-extract.js, sin red); renombrar un PROYECTO afecta la
    // agregación de tokens → fetch completo. lastAliasWasSession lo fija writeAliasMap por el archivo.
    P5Support.DataSource {
        id: writeAliasSource
        engine: "executable"
        connectedSources: []
        onNewData: function(source, data) {
            disconnectSource(source)
            if (root.lastAliasWasSession) root.refreshSessions()
            else root.forceRefresh()
        }
    }

    // Refresh RÁPIDO de la lista de sesiones: corre SOLO `sessions-extract.js` (sin red) y vuelca su
    // stdout (JSON array [{id,project,cwd,updated_at,label}]) a root.sessions. Es el MISMO helper que el
    // fetch corre para poblar sessions.json, pero aquí lo invocamos directo (via `bash -lc`, PATH de
    // login donde install.sh lo deja junto al fetch — igual que session-move.js/claude) SIN pasar por el
    // fetch completo (lento, con red, "uno a la vez"). Espeja QuotaModel.refreshSessions() del macOS.
    // Fail-safe: sin JSON de array parseable NO toca root.sessions (deja la lista previa).
    P5Support.DataSource {
        id: sessionsExtractSource
        engine: "executable"
        connectedSources: []
        onNewData: function(source, data) {
            disconnectSource(source)
            if (data["exit code"] === 0 && data.stdout) {
                try {
                    var arr = JSON.parse(data.stdout)
                    if (Array.isArray(arr)) root.sessions = arr
                } catch (e) { /* fail-safe: deja la lista previa */ }
            }
        }
    }

    // Lanzador de terminal para "resumir" una sesión de Claude Code (pestaña Proyectos). Corre el
    // comando en la primera terminal disponible; fire-and-forget (disconnect al terminar).
    P5Support.DataSource {
        id: resumeSource
        engine: "executable"
        connectedSources: []
        onNewData: function(source, data) { disconnectSource(source) }
    }

    // (A) "Sugerir nombre" al renombrar una SESIÓN: shell-out NO interactivo a `claude -p` (print mode)
    // vía el engine "executable" + `bash -lc`, para heredar el PATH de login donde vive `claude`
    // (~/.local/bin) — la MISMA resolución que usamos para `claude --resume`. Lo dispara el usuario:
    // cuesta tokens. OJO SCOPE (Plasma 6): renameField vive en fullRepresentation → el root NO lo ve;
    // por eso aquí solo depositamos el resultado en root.suggestedName y un Connections de
    // fullRepresentation lo vuelca a renameField.text (editable, no guarda solo).
    P5Support.DataSource {
        id: suggestSource
        engine: "executable"
        connectedSources: []
        onNewData: function(source, data) {
            disconnectSource(source)
            if (data["exit code"] === 0 && data.stdout && ("" + data.stdout).trim() !== "") {
                root.suggestedName = root.cleanSuggestion(data.stdout)
                root.suggestState = ""
            } else {
                root.suggestState = "error"
            }
        }
    }

    // (B) "Mover a…" una sesión a otro slug: corre el helper node `session-move.js` vía `bash -lc`
    // (PATH de login, mismo criterio que `claude`/`claude-brain-fetch`, ambos en ~/.local/bin). El
    // helper escribe JSON a stdout SIEMPRE (ok:true | ok:false+error, con exit 1 en error) → parseamos
    // stdout pase lo que pase. ok → refreshSessions() (la lista refleja el move YA, rápido y sin red) +
    // forceRefresh() (reconcilia después los conteos por proyecto / agregación); !ok → depositamos el
    // error y un Connections de fullRepresentation abre el diálogo de aviso (scope gotcha de Plasma 6).
    P5Support.DataSource {
        id: sessionMoveSource
        engine: "executable"
        connectedSources: []
        onNewData: function(source, data) {
            disconnectSource(source)
            root.sessionMoveBusy = false
            var res = null
            if (data.stdout) { try { res = JSON.parse(data.stdout) } catch (e) {} }
            if (res && res.ok) {
                root.refreshSessions()   // instantáneo: la lista refleja el move YA (sin red)
                root.forceRefresh()      // reconcilia conteos por proyecto / agregación después
            } else {
                root.sessionMoveError = (res && res.error) ? res.error
                    : "no se pudo mover la sesión (rc=" + data["exit code"] + ")"
            }
        }
    }

    // Lectura del estado real del cerebro (brain-scan.sh scan → JSON). Reusa el engine "executable"
    // que ya usamos para state.json/stats.json (evita depender de binarios raros o de XHR a file://).
    P5Support.DataSource {
        id: brainSource
        engine: "executable"
        connectedSources: []
        onNewData: function(source, data) {
            if (data["exit code"] === 0 && data.stdout) {
                try {
                    root.brainState = JSON.parse(data.stdout)
                    root.brainScannedAt = Qt.formatTime(new Date(), "hh:mm")
                } catch (e) { /* deja el estado previo si el parse falla */ }
            }
            disconnectSource(source)
        }
    }

    // Curita self-healing: corre brain-scan.sh heal (que localiza y ejecuta install-brain.sh).
    P5Support.DataSource {
        id: healSource
        engine: "executable"
        connectedSources: []
        onNewData: function(source, data) {
            root.brainHeal = (data["exit code"] === 0) ? "ok" : "error"
            disconnectSource(source)
            root.scanBrain()   // re-lee el estado tras curar
        }
    }

    // Autoupdate (1/3): lee la versión EMBEBIDA (contents/version.json, escrita por install.sh al
    // empaquetar). Reusa el engine "executable" con `cat`, igual que state.json/stats.json.
    P5Support.DataSource {
        id: versionSource
        engine: "executable"
        connectedSources: []
        onNewData: function(source, data) {
            if (data["exit code"] === 0 && data.stdout) {
                try {
                    var o = JSON.parse(data.stdout)
                    root.updLocalShort = o.sha ? o.sha : "?"
                    root.updRepoPath = o.repo ? o.repo : ""
                    root.updLocalDate = o.date ? o.date : ""
                    // Auto-update posible solo si version.json trae un repo (clon en disco); si no,
                    // el botón invita a hacerlo a mano. FAIL-OPEN.
                    root.updCanSelfUpdate = root.updRepoPath !== ""
                } catch (e) { /* fail-open: build sin version.json → no molesta */ }
            }
            disconnectSource(source)
            root.updLocalLoaded = true
            root.checkUpdateRemote()   // encadena la consulta a GitHub
        }
    }

    // Autoupdate (2/3): consulta commits/main de claude-brain en GitHub (curl está en Linux). GitHub
    // exige User-Agent. FAIL-OPEN: sin red / rc!=0 / parse fallido → no muestra nada.
    P5Support.DataSource {
        id: updateCheckSource
        engine: "executable"
        connectedSources: []
        onNewData: function(source, data) {
            disconnectSource(source)
            if (data["exit code"] !== 0 || !data.stdout) return   // sin red → fail-open
            try {
                var o = JSON.parse(data.stdout)
                var fullSha = o.sha
                if (!fullSha) return
                var rDateIso = (o.commit && o.commit.committer) ? o.commit.committer.date : ""
                root.updRemoteShort = ("" + fullSha).substring(0, 7)
                // Novedad = el sha remoto NO empieza con el local Y (si hay fechas) el remoto es más nuevo.
                var differs = ("" + fullSha).indexOf(root.updLocalShort) !== 0
                var newer = true
                if (root.updLocalDate && rDateIso) {
                    var lt = Date.parse(root.updLocalDate), rt = Date.parse(rDateIso)
                    if (!isNaN(lt) && !isNaN(rt)) newer = rt > lt + 2000
                }
                root.updateAvailable = differs && newer
            } catch (e) { /* fail-open */ }
        }
    }

    // Autoupdate (3/3): corre el update. DIFERENCIA CLAVE CON macOS: en KDE el applet vive DENTRO de
    // plasmashell (no es un proceso propio que se pueda matar/relanzar como el .app), así que NO se
    // mata plasmashell: el update = git ff + install.sh (kpackagetool6 -u actualiza el paquete) y el
    // applet toma la versión nueva al RECARGAR el plasmoide. `nohup` lo blinda de un SIGHUP si
    // plasmashell recargara el applet a media instalación; sin `&` para que el exit code vuelva aquí.
    P5Support.DataSource {
        id: updateRunSource
        engine: "executable"
        connectedSources: []
        onNewData: function(source, data) {
            disconnectSource(source)
            root.updating = false
            if (data["exit code"] === 0) {
                root.updateMessage = "✓ actualizado (recarga el widget)"
                root.updateAvailable = false
            } else {
                root.updateMessage = "✗ error (revisa /tmp/claude-brain-update.log)"
            }
        }
    }

    function reload() {
        catSource.connectSource("cat " + cacheDir + "/state.json")
        catSource.connectSource("cat " + cacheDir + "/stats.json")
        // (e) Sync: fail-open (2>/dev/null) — ausente si el sync no está activo -> statsGlobal null.
        catSource.connectSource("cat " + cacheDir + "/stats-global.json 2>/dev/null")
        catSource.connectSource("cat " + cacheDir + "/chats.json")
        catSource.connectSource("cat " + cacheDir + "/sessions.json")
        // Mapas de alias (fail-open): para la lógica de "canónico" y "Restaurar original".
        catSource.connectSource("cat \"" + aliasDir + "/proyectos-alias.json\" 2>/dev/null")
        catSource.connectSource("cat \"" + aliasDir + "/sesiones-alias.json\" 2>/dev/null")
    }
    function forceRefresh() {
        refreshRunner.connectSource("systemctl --user start claude-brain.service")
    }
    // Refresh RÁPIDO de la lista de sesiones (sin red): corre SOLO sessions-extract.js y su stdout
    // repobla root.sessions vía sessionsExtractSource. Úsalo tras mover/renombrar una sesión para que
    // la lista refleje el cambio al instante, SIN esperar al fetch completo (que se descarta si ya hay
    // uno en vuelo → por eso mover no se reflejaba). Espeja QuotaModel.refreshSessions() del macOS.
    function refreshSessions() {
        sessionsExtractSource.connectSource("bash -lc " + shq("sessions-extract.js"))
    }

    // ---------- Renombrado por clic-secundario (espeja QuotaModel.swift) ----------
    // Serializa un mapa {clave:valor} con LLAVES ORDENADAS + pretty (2 espacios) → diff limpio si el
    // archivo se versiona/sincroniza. (JSON.stringify con array-replacer respeta el orden del array.)
    function serializeAliasMap(map) {
        var keys = Object.keys(map).sort()
        return JSON.stringify(map, keys, 2)
    }
    // Escribe el mapa en <aliasDir>/<file> y, al terminar, refetch. Contenido single-quoted y escapado
    // ('->'\'') para blindar cualquier carácter; `printf '%s'` NO interpreta % ni \ del argumento.
    function writeAliasMap(file, map) {
        // Gobierna el refresh KIND-AWARE de writeAliasSource: sesiones-alias.json → sesión (rápido),
        // proyectos-alias.json → proyecto (fetch completo). Se fija aquí, el ÚNICO embudo de escritura
        // (así también cubre el "Restaurar original" directo, que no pasa por prepRename/renameKind).
        root.lastAliasWasSession = (("" + file).indexOf("sesiones-alias") !== -1)
        var json = serializeAliasMap(map)
        var esc = json.replace(/'/g, "'\\''")
        var cmd = "mkdir -p \"" + aliasDir + "\" && printf '%s' '" + esc + "' > \"" + aliasDir + "/" + file + "\""
        writeAliasSource.connectSource(cmd)
    }
    // (c) Proyecto: la lista muestra el nombre YA aliaseado. La llave canónica = la entrada cuyo VALOR
    // == mostrado; si no hay, el mostrado ES el canónico. Nuevo vacío o == canónico → BORRA (revierte).
    function renameProject(shown, newName) {
        var map = {}; for (var k in projAliasMap) map[k] = projAliasMap[k]
        var canonical = shown
        for (var kk in map) if (map[kk] === shown) { canonical = kk; break }
        var v = ("" + newName).trim()
        if (v === "" || v === canonical) delete map[canonical]
        else map[canonical] = v
        projAliasMap = map
        writeAliasMap("proyectos-alias.json", map)
    }
    // (d) Sesión: llave = id (estable). Vacío → borra (revierte a la etiqueta derivada del transcript).
    function renameSession(id, newName) {
        var map = {}; for (var k in sessAliasMap) map[k] = sessAliasMap[k]
        var v = ("" + newName).trim()
        if (v === "") delete map[id]
        else map[id] = v
        sessAliasMap = map
        writeAliasMap("sesiones-alias.json", map)
    }
    // ¿El proyecto mostrado tiene alias activo? (es llave O valor del mapa) — para "Restaurar original".
    function projectAliased(shown) {
        if (projAliasMap[shown] !== undefined) return true
        for (var k in projAliasMap) if (projAliasMap[k] === shown) return true
        return false
    }
    function sessionAliased(id) { return sessAliasMap[id] !== undefined && sessAliasMap[id] !== null }

    // Estado del diálogo de renombrado (compartido por proyecto y sesión).
    // OJO SCOPE (Plasma 6): el `fullRepresentation` se instancia como scope APARTE → `renameDialog` y
    // `renameField` (que viven dentro) NO son visibles desde funciones del root. Por eso el root SOLO
    // siembra propiedades; ABRIR/CERRAR el diálogo y leer el campo se hace desde el scope del MENÚ/DIÁLOGO
    // (que sí los ve). renameProject/renameSession y estas props son del root → accesibles vía `root.`.
    property string renameKind: ""   // "project" | "session"
    property string renameKey: ""    // (c) nombre mostrado del proyecto · (d) id de la sesión
    property string renameSeed: ""   // texto inicial; el diálogo lo carga en su onOpened (ahí está en scope)
    property string renameSummary: ""   // (A) contexto de la sesión (summary); "" oculta el bloque de contexto
    // (A) "Sugerir nombre": "" = idle/listo · "running" = generando · "error". El resultado va a
    // suggestedName; un Connections de fullRepresentation lo vuelca a renameField (scope gotcha).
    property string suggestState: ""
    property string suggestedName: ""
    // (B) "Mover a…": destino sembrado por prepMove + estado del movimiento. El error lo muestra un diálogo.
    property string moveSessionId: ""
    property string moveSessionLabel: ""
    property string moveTargetCwd: ""
    property string moveTargetName: ""
    property bool   sessionMoveBusy: false
    property string sessionMoveError: ""
    // Solo prepara el estado; el .open() lo hace el menú (que SÍ ve renameDialog). NO toca renameDialog aquí.
    // `summary` solo aplica a sesión (el proyecto pasa undefined → se limpia). Resetea el estado de sugerir.
    function prepRename(kind, key, current, summary) {
        renameKind = kind; renameKey = key; renameSeed = current
        renameSummary = summary ? summary : ""
        suggestState = ""; suggestedName = ""
    }
    // Aplica el alias. newText lo pasa el handler del diálogo (donde renameField está en scope). El
    // .close() lo hace el propio diálogo; aquí NO se toca renameDialog (root no lo ve).
    function applyRename(newText) {
        if (renameKind === "project") renameProject(renameKey, newText)
        else if (renameKind === "session") renameSession(renameKey, newText)
    }

    // epoch ms del último forceRefresh disparado por un reset ya pasado (guard anti-bucle).
    property double lastResetRefresh: 0

    Timer {
        interval: 10000
        repeat: true
        running: true
        triggeredOnStart: true
        onTriggered: {
            reload()   // re-lee state.json/stats.json local (barato)
            // Anti-"% pegado": si una ventana (5h/semanal) YA pasó su reset pero el snapshot es
            // viejo (>60s), el % mostrado sería el de la ventana anterior hasta el próximo fetch.
            // Disparamos forceRefresh() para adelantarlo. Acotado por lastResetRefresh (≥60s) para
            // NO machacar systemctl/API cada tick de 10s; el piso anti-abuso de ~5 min lo aplica
            // claude-brain.service por dentro (un forceRefresh de más ahí es no-op). Espeja el
            // `(anyResetPassed && age > 60)` de AppDelegate.swift.
            var age = root.snapshotAgeSec()
            if (root.anyResetPassed && age > 60 && (Date.now() - root.lastResetRefresh) > 60000) {
                root.lastResetRefresh = Date.now()
                root.forceRefresh()
            }
        }
    }

    // ---------- Color / estado ----------
    readonly property string statusKey: {
        if (snapshotError !== "" || snapshot === null) return "error"
        if (snapshot.status) return snapshot.status
        return "error"
    }
    // Acento naranja; rojo solo >90% (aviso de throttle).
    function pctColor(p) {
        if (p === undefined || p === null) return "#777777"
        if (p > 90) return "#dc3545"
        return "#e8884a"
    }

    readonly property real fivePct: snapshot && snapshot.five_hour ? snapshot.five_hour.percent : -1
    readonly property real weekPct: snapshot && snapshot.weekly    ? snapshot.weekly.percent    : -1

    // true si el reset de la ventana 5h o semanal YA pasó (el % que se ve puede estar pegado en el
    // de la ventana anterior). Espeja QuotaModel.anyResetPassed del macOS.
    readonly property bool anyResetPassed: {
        if (!snapshot) return false
        var a = snapshot.five_hour ? isPast(snapshot.five_hour.resets_at) : false
        var b = snapshot.weekly    ? isPast(snapshot.weekly.resets_at)    : false
        return a || b
    }

    // Límites semanales acotados a UN modelo (weekly_scoped con scope.model).
    // Efímeros y cambiantes → se renderizan dinámicamente, sin hardcodear modelos.
    readonly property var scopedLimits: {
        if (!snapshot || !snapshot.limits) return []
        var out = []
        for (var i = 0; i < snapshot.limits.length; i++) {
            var l = snapshot.limits[i]
            if (l.kind === "weekly_scoped" && l.model) out.push(l)
        }
        return out
    }
    // Formatea dinero (used/cap ya vienen divididos por 10^exponent).
    function fmtMoney(v, cur) {
        if (v === undefined || v === null) return "—"
        var sym = cur === "USD" ? "$" : (cur ? cur + " " : "$")
        return sym + v.toFixed(2)
    }

    // Paleta para modelos (distinta por modelo, cohesiva con el acento).
    readonly property var modelPalette: ["#e8884a", "#5b9bd5", "#9b6dd6", "#5fb98e", "#d6a15b", "#c96daa"]
    function modelColorFor(name) {
        if (!stats || !stats.models) return modelPalette[0]
        for (var i = 0; i < stats.models.length; i++)
            if (stats.models[i].model === name) return modelPalette[i % modelPalette.length]
        return modelPalette[0]
    }
    // Color por proyecto — mismo esquema que modelColorFor (índice en la lista → paleta).
    function projectColorFor(name) {
        if (!stats || !stats.projects) return modelPalette[0]
        for (var i = 0; i < stats.projects.length; i++)
            if (stats.projects[i].project === name) return modelPalette[i % modelPalette.length]
        return modelPalette[0]
    }
    function prettyModel(id) {
        if (!id) return "—"
        var parts = id.replace(/^claude-/, "").split("-")
        var fam = parts[0].charAt(0).toUpperCase() + parts[0].slice(1)
        // "claude-opus-4-8"->"Opus 4.8"; "gemini-3.1-pro-preview"->"Gemini 3.1 Pro".
        // Enteros consecutivos se unen con "." (estilo Claude); un segmento ya
        // punteado ("3.1") se toma tal cual; palabras (pro/flash) se capitalizan;
        // se descarta ruido (preview/exp/latest) y sellos de fecha (>=6 dígitos).
        var noise = { "preview": 1, "exp": 1, "latest": 1 }
        var tokens = [], nums = []
        function flush() { if (nums.length) { tokens.push(nums.join(".")); nums = [] } }
        for (var i = 1; i < parts.length; i++) {
            var p = parts[i]
            if (/^\d+$/.test(p)) {
                if (p.length >= 6) break   // sello de fecha tipo 20251001
                nums.push(p)
            } else if (/^\d+\.\d+$/.test(p)) {
                flush(); tokens.push(p)                 // versión ya punteada, p.ej. 3.1
            } else if (p && !noise[p.toLowerCase()]) {
                flush(); tokens.push(p.charAt(0).toUpperCase() + p.slice(1))
            }
        }
        flush()
        return tokens.length ? fam + " " + tokens.join(" ") : fam
    }
    function fmtTok(n) {
        if (n === undefined || n === null) return "—"
        if (n >= 1e6) return (n / 1e6).toFixed(1) + "M"
        if (n >= 1e3) return (n / 1e3).toFixed(1) + "k"
        return "" + Math.round(n)
    }
    function fmtInt(n) {
        if (n === undefined || n === null) return "—"
        return ("" + Math.round(n)).replace(/\B(?=(\d{3})+(?!\d))/g, ",")
    }
    function fmtHour(h) {
        if (h === undefined || h === null || h < 0) return "—"
        var ampm = h < 12 ? "a.m." : "p.m."
        var hh = h % 12; if (hh === 0) hh = 12
        return hh + " " + ampm
    }

    readonly property real maxDayTokens: {
        if (!stats || !stats.days || !stats.days.length) return 1
        var m = 1
        for (var i = 0; i < stats.days.length; i++) m = Math.max(m, stats.days[i].tokens)
        return m
    }

    // La gráfica de PROYECTOS se normaliza con SU propio máximo (suma de proyectos por día), no con
    // maxDayTokens: los tokens por-modelo (con caché) y por-proyecto (in+out crudos) se cuentan
    // distinto, así que un día puede sumar más en proyectos que el max por-modelo -> desbordaría.
    readonly property real maxDayProjectTokens: {
        if (!stats || !stats.days || !stats.days.length) return 1
        var m = 1
        for (var i = 0; i < stats.days.length; i++) {
            var ps = stats.days[i].projects, s = 0
            if (ps) for (var j = 0; j < ps.length; j++) s += ps[j].tokens
            m = Math.max(m, s)
        }
        return m
    }

    // ---------- Recompute por rango {hoy·7d·30d·∞} ----------
    // Espeja rangeCutoff/rangedDays/rangedModels/rangedProjects/rangedChats/rangedSessionCount del
    // PopoverView.swift. Cada readonly-property lee root.rangeIdx (+ stats/chats/sessions), así que se
    // recalcula sola al cambiar el rango; las gráficas y tablas se enganchan a estas.

    // Fecha de corte local "yyyy-MM-dd" = hoy − daysBack; "" si ∞ (sin recorte).
    function rangeCutoff() {
        var back = [0, 6, 29, -1][rangeIdx]
        if (back < 0) return ""
        var d = new Date(); d.setDate(d.getDate() - back)
        return dayKey(d)
    }

    // Días de days[] dentro del rango (todos si ∞). Compara por prefijo de fecha (string).
    // Lee de la fuente ACTIVA (local o combinada según el toggle (e)); todo lo que deriva de rDays
    // —rModels/rProjects/rTokens/rMessages/rCost/rActiveDays/rMaxDay*— hereda esa fuente sin más cambios.
    // (rSessionCount y rChats se quedan LOCALES a propósito.)
    readonly property var rDays: {
        var src = activeStats
        if (!src || !src.days) return []
        var cut = rangeCutoff()
        if (cut === "") return src.days
        var out = []
        for (var i = 0; i < src.days.length; i++)
            if ((src.days[i].date || "") >= cut) out.push(src.days[i])
        return out
    }

    // Agrega in_tok/out_tok por clave (model/project) sobre los días del rango → filas
    // {<nameKey>, in_tok, out_tok, tot, pct} ordenadas desc por total.
    function aggBy(days, listKey, nameKey) {
        var acc = {}, order = []
        for (var i = 0; i < days.length; i++) {
            var list = days[i][listKey]
            if (!list) continue
            for (var j = 0; j < list.length; j++) {
                var k = list[j][nameKey] || "?"
                if (!(k in acc)) { acc[k] = { inTok: 0, outTok: 0 }; order.push(k) }
                acc[k].inTok += list[j].in_tok || 0
                acc[k].outTok += list[j].out_tok || 0
            }
        }
        var grand = 0
        for (var m in acc) grand += acc[m].inTok + acc[m].outTok
        var rows = []
        for (var n = 0; n < order.length; n++) {
            var kk = order[n], tot = acc[kk].inTok + acc[kk].outTok
            var row = { in_tok: acc[kk].inTok, out_tok: acc[kk].outTok, tot: tot,
                        pct: grand > 0 ? tot * 100 / grand : 0 }
            row[nameKey] = kk
            rows.push(row)
        }
        rows.sort(function(a, b) { return b.tot - a.tot })
        return rows
    }
    readonly property var rModels:   aggBy(rDays, "models", "model")
    readonly property var rProjects: aggBy(rDays, "projects", "project")

    // Máximos por-día del rango (para reescalar las gráficas apiladas): total-por-día (modelos) y
    // suma-de-proyectos-por-día (proyectos), igual que maxDayTokens / maxDayProjectTokens all-time.
    readonly property real rMaxDayTokens: {
        var m = 1
        for (var i = 0; i < rDays.length; i++) m = Math.max(m, rDays[i].tokens || 0)
        return m
    }
    readonly property real rMaxDayProjectTokens: {
        var m = 1
        for (var i = 0; i < rDays.length; i++) {
            var ps = rDays[i].projects, s = 0
            if (ps) for (var j = 0; j < ps.length; j++) s += ps[j].tokens || 0
            m = Math.max(m, s)
        }
        return m
    }

    // Agregados del Resumen recalculados sobre los días del rango (a ∞ = summary all-time).
    readonly property real rTokens:   { var s = 0; for (var i = 0; i < rDays.length; i++) s += rDays[i].tokens   || 0; return s }
    readonly property real rMessages: { var s = 0; for (var i = 0; i < rDays.length; i++) s += rDays[i].messages || 0; return s }
    readonly property real rCost:     { var s = 0; for (var i = 0; i < rDays.length; i++) s += rDays[i].cost     || 0; return s }
    readonly property int  rActiveDays: { var n = 0; for (var i = 0; i < rDays.length; i++) if ((rDays[i].tokens || 0) > 0) n++; return n }

    // Chats dentro del rango (por updated_at, fallback created_at). Sesiones: conteo dentro del rango.
    readonly property var rChats: {
        if (!chats) return []
        var cut = rangeCutoff()
        if (cut === "") return chats
        var out = []
        for (var i = 0; i < chats.length; i++) {
            var d = ("" + (chats[i].updated_at || chats[i].created_at || "")).substring(0, 10)
            if (d >= cut) out.push(chats[i])
        }
        return out
    }
    readonly property int rSessionCount: {
        if (!sessions) return 0
        var cut = rangeCutoff()
        if (cut === "") return sessions.length
        var n = 0
        for (var i = 0; i < sessions.length; i++)
            if (("" + (sessions[i].updated_at || "")).substring(0, 10) >= cut) n++
        return n
    }

    // Desglose de chats por modelo (conteo + % del total), ordenado desc. Espeja chatsByModel del Swift.
    function chatsByModel(cs) {
        var total = cs.length
        if (total === 0) return []
        var counts = {}, order = []
        for (var i = 0; i < cs.length; i++) {
            var k = cs[i].model || "?"
            if (!(k in counts)) { counts[k] = 0; order.push(k) }
            counts[k]++
        }
        var rows = []
        for (var n = 0; n < order.length; n++)
            rows.push({ model: order[n], count: counts[order[n]], pct: counts[order[n]] * 100 / total })
        rows.sort(function(a, b) { return b.count - a.count })
        return rows
    }

    // Sesiones de un proyecto (sessions.json ya viene ordenado por updated_at desc): las más recientes,
    // máx 12; y su conteo (para saber si la fila es expandible). Espeja sessionsList/projectRow del Swift.
    function sessionsForProject(name) {
        if (!sessions) return []
        var out = []
        for (var i = 0; i < sessions.length && out.length < 12; i++)
            if (sessions[i].project === name) out.push(sessions[i])
        return out
    }
    function sessionCountForProject(name) {
        if (!sessions) return 0
        var n = 0
        for (var i = 0; i < sessions.length; i++) if (sessions[i].project === name) n++
        return n
    }

    // Fecha relativa (granularidad de día) desde el prefijo YYYY-MM-DD de un ISO. Espeja relDate del Swift.
    function relDate(iso) {
        if (!iso || ("" + iso).length < 10) return ""
        var d = Date.parse(("" + iso).substring(0, 10) + "T00:00:00Z")
        if (isNaN(d)) return ""
        var days = Math.floor((Date.now() - d) / 86400000)
        if (days <= 0) return "hoy"
        if (days === 1) return "ayer"
        if (days < 7)  return "hace " + days + "d"
        if (days < 30) return "hace " + Math.floor(days / 7) + "sem"
        return "hace " + Math.floor(days / 30) + "mes"
    }

    // Alpha sobre un color en string (#RRGGBB de la paleta) → color con transparencia (badges de modelo).
    function withAlpha(colStr, a) {
        var c = Qt.color(colStr)
        return Qt.rgba(c.r, c.g, c.b, a)
    }

    // Escapado POSIX de un token para pasarlo entre comillas simples a la shell (cwd/id de sesión).
    function shq(s) { return "'" + ("" + s).replace(/'/g, "'\\''") + "'" }

    // "Resumir" una sesión: abre una terminal en su cwd y corre `claude --resume <id>`. En Linux no hay
    // un lanzador único como el osascript de macOS, así que se intenta en cascada: konsole (KDE) →
    // x-terminal-emulator (default de Debian/Ubuntu) → gnome-terminal → xterm. `; exec bash` deja la
    // terminal abierta al terminar. cwd/id van entre comillas simples (shq) para no romper con espacios.
    function resumeSession(cwd, id) {
        var inner = "cd " + shq(cwd) + " && claude --resume " + shq(id) + "; exec bash"
        var arg = shq(inner)   // vuelve a escapar: inner ya trae comillas simples
        var cmd = "konsole -e bash -lc " + arg
                + " || x-terminal-emulator -e bash -lc " + arg
                + " || gnome-terminal -- bash -lc " + arg
                + " || xterm -e bash -lc " + arg
        resumeSource.connectSource(cmd)
    }

    // (A) Pide a `claude -p` un nombre corto para la sesión, SOLO a partir del summary (prompt barato).
    // `bash -lc` para heredar el PATH de login donde vive `claude` (misma resolución que resumeSession).
    // `--no-session-persistence`: `claude -p` ES una sesión de Claude Code y por defecto la guarda en
    // disco; lanzada desde la GUI queda con cwd=/ → aparecía un proyecto fantasma "/" que consumía
    // cuota. Con la bandera la sugerencia NO deja rastro (solo aplica con --print). Espeja QuotaModel.swift.
    // No guarda: el resultado cae en renameField (editable) vía el Connections de fullRepresentation.
    function suggestName() {
        var ctx = ("" + root.renameSummary).trim()
        if (ctx === "") return
        root.suggestState = "running"
        root.suggestedName = ""
        var prompt = "Genera un nombre corto (de 3 a 6 palabras) en español para esta sesión de Claude Code, "
                   + "a partir de su contexto. Responde SOLO con el nombre, sin comillas ni puntuación final.\n\n"
                   + "Contexto: " + ctx
        var inner = "claude -p --no-session-persistence " + shq(prompt)
        var cmd = "bash -lc " + shq(inner)
        suggestSource.connectSource(cmd)
    }
    // Limpia la salida de `claude -p`: primera línea no vacía, sin comillas/asteriscos/punto envolventes.
    function cleanSuggestion(raw) {
        var s = ("" + raw).trim()
        var lines = s.split("\n")
        for (var i = 0; i < lines.length; i++) { if (lines[i].trim() !== "") { s = lines[i].trim(); break } }
        return s.replace(/^["'`*\s]+/, "").replace(/["'`*.\s]+$/, "")
    }

    // (B) Proyectos conocidos DISTINTOS del actual, derivados de las sesiones cargadas (uno por proyecto,
    // con su cwd real). Excluye el proyecto pasado. Ordenado por nombre. Es la fuente del submenú "Mover a…".
    function otherProjects(excludeProject) {
        if (!sessions) return []
        var seen = {}, out = []
        for (var i = 0; i < sessions.length; i++) {
            var s = sessions[i]
            var p = s.project ? s.project : "?"
            if (p === excludeProject || !s.cwd || seen[p]) continue
            seen[p] = true
            out.push({ name: p, cwd: s.cwd })
        }
        out.sort(function(a, b) { return a.name < b.name ? -1 : (a.name > b.name ? 1 : 0) })
        return out
    }
    // (B) Siembra el destino del "Mover a…" (el diálogo de confirmación lee estas props). Como prepRename,
    // solo prepara: el .open() del diálogo lo hace el menú (que SÍ ve moveDialog). No toca moveDialog aquí.
    function prepMove(id, label, toCwd, toName) {
        moveSessionId = id; moveSessionLabel = label
        moveTargetCwd = toCwd; moveTargetName = toName
    }
    // (B) Ejecuta el movimiento vía session-move.js. Ver la nota de resolución de PATH en sessionMoveSource.
    function moveSession(id, toCwd) {
        root.sessionMoveBusy = true
        root.sessionMoveError = ""
        var inner = "session-move.js " + shq(id) + " --to-cwd " + shq(toCwd)
        var cmd = "bash -lc " + shq(inner)
        sessionMoveSource.connectSource(cmd)
    }

    // ---------- Pestaña Cerebro: ESTRUCTURA curada + ESTADO real ----------
    // La ESTRUCTURA (qué piezas hay, su explicación, su evento y detalle) es curada y espeja el
    // BrainItem de PopoverView.swift; el ESTADO de instalación de cada pieza se LEE de la realidad
    // (~/.claude vía brain-scan.sh) y se resuelve con brainStatus(). Textos en español, literales del Swift.
    // De más duro (arriba) a más leve (abajo).
    readonly property var brainTiers: [
        {
            emoji: "🔒", title: "Hooks Forzosos", color: "#cf5a49",
            subtitle: "hooks que bloquean (deny) — no negociables",
            items: [
                { emoji: "🚧", name: "git-branch-guard",       desc: "push/merge a develop·main → denegado, te redirige a ramita→MR",
                  event: "PreToolUse · Bash",
                  detail: "Escanea cada comando: si ve un `git push` o un merge que apunte a develop/main, lo deniega y te recuerda el flujo ramita→MR. Sin jq falla ABIERTO (no bloquea)." },
                { emoji: "🔗", name: "merge-squash-guard",     desc: "MR a develop sin --squash → denegado (1 commit limpio)",
                  event: "PreToolUse · Bash",
                  detail: "Un `gh pr merge`/`glab mr merge` a develop sin --squash se deniega, para que la ramita colapse a un commit curado. Los releases a main quedan exentos (conservan historia)." },
                { emoji: "🕵️", name: "secret-scan",            desc: "commit/push con un secreto → denegado",
                  event: "PreToolUse · Bash",
                  detail: "Escanea lo que ENTRA al repo (staged en commit, saliente en push) buscando llaves/tokens/claves privadas de formato inconfundible (AWS, PEM, Anthropic, OpenAI, GitHub, GitLab, Slack, Google). Si aparece uno → bloquea: una credencial pusheada queda comprometida aunque la borres. Escape: --no-verify." },
                { emoji: "✋", name: "confirmar-merge-develop", desc: "merge a develop sin tu OK → denegado; a main exige OK súper-explícito",
                  event: "PreToolUse · Bash",
                  detail: "Antes de integrar por MR busca tu OK explícito en el chat reciente; a main exige lenguaje de release ('hasta main', 'libera'). Un 'sigue/avanza' NO cuenta como autorización." },
                { emoji: "✅", name: "dod-verificar",          desc: "Def. of Done (ver Norma 🎯 DoD) sin build+tests+memoria → denegado",
                  event: "Stop",
                  detail: "Al cerrar el turno, si dijiste 'listo/en producción' tras tocar código fuente, exige evidencia de build+tests verdes y memoria al día, o bloquea el cierre." },
                { emoji: "💸", name: "delegacion-gate",        desc: "reclutar agente con costo → pide tu consentimiento (puede negar)",
                  event: "PreToolUse · Task",
                  detail: "Al reclutar un agente calcula su nivel de costo (gratis/incluido/con costo, según tu ventana de 5h) y pide consentimiento mostrando tu cuota real. Puedes negar y el agente no corre." },
                { emoji: "🛑", name: "limite-gasto",           desc: "reclutar agente con el gasto pasado del techo → denegado",
                  event: "PreToolUse · Task",
                  detail: "Freno DURO (distinto del gate que pregunta): si el gasto real ya rebasó un techo configurable (sobreuso o ventana 5h), bloquea reclutar más agentes para que un workflow desbocado no siga quemando dinero. Techo por env (LIMITE_GASTO_OVERAGE_PCT / LIMITE_GASTO_5H_PCT)." }
            ]
        },
        {
            emoji: "🔔", title: "Automático", color: "#e8884a",
            subtitle: "hooks que inyectan / recuerdan — no bloquean",
            items: [
                { emoji: "🧭", name: "sesion-inicio",             desc: "al abrir/retomar reinyecta rama + norma de git + orden de leer memoria",
                  event: "SessionStart",
                  detail: "Al abrir/retomar sesión o tras compactar, reinyecta la rama actual, la norma de git y la orden de leer MEMORY/estado. Antídoto a 'se me va la onda al cambiar de sesión o compu'." },
                { emoji: "📊", name: "recordar-dashboard",        desc: "antes de un push, recuerda actualizar el dashboard del cerebro",
                  event: "PreToolUse · Bash",
                  detail: "Antes de un `git push` recuerda (no bloquea) actualizar el dashboard del cerebro: una línea a la bitácora + ajustar el mapa si cambió el layout de repos/proyectos." },
                { emoji: "🕰️", name: "rama-vieja",                desc: "push de ramita muy atrás de develop → aviso (no bloquea)",
                  event: "PreToolUse · Bash",
                  detail: "Antes de un push, si la ramita está muchos commits detrás de origin/develop (base vieja → el MR trae ruido/conflictos), avisa —no bloquea— y sugiere rebasar. Umbral configurable (RAMA_VIEJA_UMBRAL, def 40)." },
                { emoji: "📝", name: "delegacion-registrar",      desc: "registra el consentimiento (materializa el “pregunta 1×”)",
                  event: "PostToolUse · Task",
                  detail: "Tras un consentimiento aprobado lo registra para no volver a preguntar (1× por máquina o por workflow, según el nivel de costo). Materializa el 'pregunta una sola vez'." },
                { emoji: "📮", name: "delegacion-reporte",        desc: "un agente de fan-out terminó → recuerda bitácora + estado, sin niñera",
                  event: "PostToolUse · Task",
                  detail: "Cuando un subagente (Task) termina, recuerda al orquestador registrar su avance sin niñera: appendar una línea a bitacora.md (append-only, parallel-safe), cerrar el ítem en estado-proyecto.md y limpiar su worktree. No bloquea." },
                { emoji: "🧵", name: "rehidratar-hilo",           desc: "al retomar/tras compactar reinyecta el hilo mental de la tarea",
                  event: "SessionStart",
                  detail: "Al abrir/retomar sesión o tras compactar, relee .claude/memory/hilo-mental-actual.md y lo reinyecta por additionalContext (canal fiable de SessionStart). Es la mitad 'leer' del par con el skill checkpoint (la mitad 'escribir'). Silencioso si el archivo no existe." },
                { emoji: "♻️", name: "aviso-drift-cerebro",       desc: "la copia del cerebro por-repo quedó atrás de la fuente → aviso",
                  event: "SessionStart",
                  detail: "Al iniciar sesión en un repo con el cerebro por-repo instalado, compara esa copia contra la fuente única (sincronizar-cerebro.sh en dry-run, diff por contenido) y, si quedó atrás, avisa para que Claude proponga propagar por el flujo (ramita→MR). No escribe al árbol en repos compartidos. Throttle 6h si salió limpio." },
                { emoji: "🧹", name: "barrer-ramas",            desc: "barre ramas locales ya integradas (zombies squash-safe) en 2º plano",
                  event: "SessionStart",
                  detail: "Al iniciar sesión en un repo con remoto, y como mucho cada 24h, lanza limpiar-ramas.sh en segundo plano para borrar las ramas locales ya integradas (MR mergeado con --squash → remota borrada, o commits ya en la base por equivalencia de parche). Conserva todo trabajo sin integrar; nunca toca la actual/base/develop/main/Develop*/keep/*." },
                { emoji: "🧺", name: "recordar-cosechar",       desc: "trabajaste y no cosechaste aprendizajes → sugiere /cosechar-sesion",
                  event: "Stop",
                  detail: "Al terminar un turno, si hubo trabajo sustantivo reciente en el repo (commits en las últimas horas o cambios de código sin commitear) pero .claude/memory/aprendizajes.md no se tocó, sugiere —no bloquea— correr /cosechar-sesion antes de cerrar si aprendiste algo durable. Throttle fuerte: 1×/día por repo. Fail-open." },
                { emoji: "🪢", name: "recordar-unificar-cerebro", desc: "tu mini acumuló aprendizajes sin unificar a develop → aviso",
                  event: "SessionStart",
                  detail: "Gemelo hacia arriba de aviso-drift-cerebro: al iniciar sesión cuenta el delta de .claude/ (sobre todo aprendizajes.md) de tu rama vs origin/develop y, si supera el umbral (≥5 archivos o >7 días, tunable por env), avisa —no bloquea— para correr /unificar-cerebro cuando quieras integrarlos. No escribe al árbol. Throttle 1×/día por repo." },
                { emoji: "⏳", name: "aviso-contexto",            desc: "el contexto se está llenando → ordena checkpoint y propón /compact",
                  event: "PostToolUse",
                  detail: "Vigila cuánto creció el contexto desde el último /compact y, al cruzar bandas por debajo del auto-compact, inyecta un aviso escalado (heads-up → checkpoint ahora → inminente) para volcar el hilo con checkpoint y compactar proactivamente. Convierte el auto-compact-sorpresa en caso raro." },
                { emoji: "🌳", name: "proteger-arbol",            desc: "git destructivo que orfanaría commits sin pushear → aviso (no bloquea)",
                  event: "PreToolUse · Bash",
                  detail: "Antes de un git destructivo (reset --hard, rebase, checkout -f, branch -D) que podría orfanar commits sin pushear en el árbol de trabajo, avisa —no bloquea. Antídoto a un caso real: un agente de fan-out reseteó HEAD en el árbol compartido y dejó huérfano un commit del orquestador." }
            ]
        },
        {
            emoji: "📜", title: "Normas", color: "#4a90d9",
            subtitle: "reglas que Claude se autoimpone (CLAUDE.md)",
            items: [
                { emoji: "🎯", name: "Definition of Done",    desc: "verde técnico ≠ Done/Listo/Ya Quedó; exige QA o un OK explícito",
                  event: "CLAUDE.md · norma",
                  detail: "Algo es LISTO solo si tú lo validaste (QA) o autorizaste el cierre. 'Verde técnico' es necesario pero insuficiente; la autorización es acotada y NO transitiva." },
                { emoji: "🪞", name: "Doc <= realidad",       desc: "cambió algo → actualiza su doc en la misma tanda, sin preguntar",
                  event: "CLAUDE.md · norma",
                  detail: "Cuando cambia algo (config, ruta, comportamiento) se actualiza su doc en la misma tanda, sin preguntar. Primero revisar el estado real, luego editar: una doc que miente es peor que nada. Y con iniciativa: ¿vive en MÁS de un lugar (un README y su UI, varias plataformas, un ejemplo)? rastréalas (grep del valor viejo) y actualízalas todas — una copia desincronizada ya miente." },
                { emoji: "🌿", name: "Flujo de git",          desc: "ramita → MR → develop (squash); main es release-only",
                  event: "CLAUDE.md · norma",
                  detail: "Todo push va a ramitas; se integra por MR a develop con squash; main es release-only (decisión humana deliberada). 1–3 devs → auto-merge; ≥4 devs → se revisa." },
                { emoji: "💰", name: "Costo de delegación",   desc: "gratis / incluido / con costo — window-aware, lee tu cuota",
                  event: "CLAUDE.md · norma",
                  detail: "Reclutar agentes cuesta según nivel: gratis (local), incluido (Claude dentro de la ventana 5h) o con costo (overage / API externa / desconocido). La cadencia del permiso depende del nivel." }
            ]
        },
        {
            emoji: "💡", title: "Skills", color: "#3aa76d",
            subtitle: "herramientas opt-in — las invocas tú",
            items: [
                { emoji: "💾", name: "checkpoint", desc: "vuelca el hilo mental a disco para compactar sin perderlo",
                  event: "skill · opt-in",
                  detail: "Vuelca lo efímero del chat (el hilo: qué haces ahora, la decisión abierta, el siguiente paso) a hilo-mental-actual.md, para poder compactar cuanto quieras sin perder el hilo. Es la mitad 'escribir' del par con el hook rehidratar-hilo (la mitad 'leer'). Córrelo antes de un /compact o en una pausa natural." },
                { emoji: "📦", name: "cerrar-slice", desc: "build+tests+memoria al día + MR con resumen curado por slice",
                  event: "skill · opt-in",
                  detail: "Ritual de cierre de un slice: build+tests verdes, memoria al día (bitácora), MR con resumen curado en prosa, y el Paso 5 de cosechar lo genérico de vuelta al cerebro global." },
                { emoji: "📐", name: "diagramar", desc: "diagrama según su DESTINO: yEd editable (.dot→graphml) o Mermaid versionado",
                  event: "skill · opt-in",
                  detail: "Produce un diagrama eligiendo el flujo según su destino: para EDITAR a mano, modela en .dot (Graphviz) → .graphml de yEd; para VERSE en GitHub/docs, Mermaid en un .md versionado. Regla dura: un diagrama entregable nunca queda solo como artefacto local gitignorado ni widget efímero del chat." },
                { emoji: "🐝", name: "orquestar-fanout", desc: "fan-out de agentes sin niñera (estado en 2 archivos + contrato de reporte)",
                  event: "skill · opt-in",
                  detail: "Orquestar trabajo paralelizable en varios agentes SIN niñera: asigna ítems autocontenidos del backlog y, al terminar cada agente, su avance queda registrado (bitácora) y su worktree limpio automáticamente. Modelo de estado sin redundancia: estado-proyecto = backlog vivo, bitácora = pasado append-only." },
                { emoji: "🌙", name: "turno-nocturno", desc: "Claude trabaja solo de noche: contrato medible, decide-o-parquea, checkpoint c/2h",
                  event: "skill · opt-in",
                  detail: "Protocolo para dejar a Claude trabajando SOLO de noche: eco del contrato antes de empezar (alcance, criterio de cierre MEDIBLE, lo intocable, dónde queda visible el resultado), preflight de herramientas/quota, regla de decisión (dentro del alcance decide y sigue; fuera, parquea y brinca), autorización durable a disco y checkpoint cada ~2h." },
                { emoji: "🌾", name: "cosechar-sesion", desc: "cosecha local: extrae aprendizajes de tu sesión al inbox del equipo",
                  event: "skill · opt-in",
                  detail: "Al cerrar el día, revisa TU propio transcript y appendea los aprendizajes durables (feedback del usuario, lecciones de proceso, gotchas) al FINAL de .claude/memory/aprendizajes.md con atribución (aportó: handle). Separa el grano de la paja (no cosecha trivialidades). Alimenta el inbox append-only (merge=union). NO cierra slice ni hace git." },
                { emoji: "🧩", name: "unificar-cerebro", desc: "reconciliación semanal del cerebro del equipo mini→develop",
                  event: "skill · opt-in",
                  detail: "Hermana de cerrar-slice: junta aprendizajes+memorias de las minis hacia develop sin perder atribución/voz ni tocar guardrails. Inventaría el delta, baja primero el brain canónico, resuelve por clase, CURA el log (trenza solapes acreditando a ambos + gradúa lo maduro), verifica test-brain+lint, integra por el carril existente (OK explícito, sin auto-merge, con squash) y anota bitácora." }
            ]
        }
    ]

    // ---------- Cerebro VIVO: estado real leído de ~/.claude ----------
    // Espeja BrainInspector.swift. brainState = { present:[], wired:[], hasNorms, skills:[], version } o null.
    property var brainState: null
    property string brainScannedAt: ""        // hora de la última lectura (hh:mm)
    // Versión INSTALADA del brain: sello ~/.claude/.brain-version (lo estampa install-brain.sh, lo
    // emite brain-scan.sh). "" si no hay sello (instalación vieja) → la UI no muestra versión.
    readonly property string brainVersion: (brainState && brainState.version) ? ("" + brainState.version) : ""
    property string brainHeal: ""             // "", "running", "ok", "error" (estado del botón-curita)
    property string brainExpandedKey: ""      // "<tier>-<idx>" de la hoja expandida (solo una a la vez)

    // Catálogo conocido (mismos conjuntos que BrainState.knownGlobalHooks / knownRepoHooks del Swift).
    // DEBE coincidir con brain/hooks/MANIFEST; lo verifica el drift-check del widget (test-brain.sh).
    readonly property var brainGlobalHooks: ["git-branch-guard","merge-squash-guard","confirmar-merge-develop","recordar-dashboard","secret-scan","rama-vieja","proteger-arbol","limite-gasto","delegacion-gate","delegacion-registrar","delegacion-reporte","rehidratar-hilo","aviso-contexto","aviso-drift-cerebro","barrer-ramas"]
    readonly property var brainRepoHooks:   ["sesion-inicio","dod-verificar","recordar-cosechar","recordar-unificar-cerebro"]

    // Ruta del helper bash, resuelta relativa a este main.qml (…/contents/ui/ → …/contents/brain-scan.sh).
    readonly property string brainScript: {
        var u = "" + Qt.resolvedUrl("../brain-scan.sh")
        if (u.startsWith("file://")) u = u.substring("file://".length)
        return u
    }
    function scanBrain()  { brainSource.connectSource("bash '" + brainScript + "' scan") }
    function healBrainGlobal() {
        root.brainHeal = "running"
        healSource.connectSource("bash '" + brainScript + "' heal")
    }

    // ---------- Autoupdate LIGERO (winturbo-style) del widget ----------
    // Espeja Updater.swift: la versión con que se empaquetó el plasmoid (sha/fecha/repo/branch) va
    // embebida en contents/version.json (la escribe install.sh al empaquetar). Al abrir la pestaña
    // Cerebro se compara contra commits/main de claude-brain en GitHub; si el repo avanzó, se ofrece un
    // botón que hace git ff + install.sh. FAIL-OPEN: sin red / sin version.json / sin repo → no molesta.
    property bool updateAvailable: false
    property bool updating: false
    property string updateMessage: ""       // "", "✓ actualizado…", "✗ error…" (resultado del update)
    property string updLocalShort: "?"      // sha corto embebido ("?" si no hay version.json)
    property string updRemoteShort: "?"     // sha corto remoto (commits/main)
    property string updRepoPath: ""         // ruta del clon en disco (de version.json)
    property string updLocalDate: ""        // ISO del commit embebido ("" si no hay)
    property bool updLocalLoaded: false     // version.json ya leído (una sola vez)
    property bool updCanSelfUpdate: false   // hay repo en disco → botón auto; si no, "a mano"
    property double updLastCheck: 0         // epoch ms del último chequeo remoto (throttle 15 min)
    readonly property string updSlug: "unjordi/claude-brain"

    // Ruta del version.json embebido, relativa a este main.qml (…/contents/ui/ → …/contents/version.json).
    readonly property string versionFile: {
        var u = "" + Qt.resolvedUrl("../version.json")
        if (u.startsWith("file://")) u = u.substring("file://".length)
        return u
    }

    // Chequea como mucho 1×/15 min (evita el rate-limit anónimo de GitHub). Primero carga version.json
    // (una sola vez); su onNewData encadena la consulta remota. Fire-and-forget desde la vista.
    function checkUpdate() {
        var now = Date.now()
        if (root.updLastCheck > 0 && (now - root.updLastCheck) < 900000) return   // < 15 min → no reconsulta
        root.updLastCheck = now
        if (!root.updLocalLoaded) {
            versionSource.connectSource("cat '" + root.versionFile + "'")
        } else {
            root.checkUpdateRemote()
        }
    }
    function checkUpdateRemote() {
        if (root.updLocalShort === "?") return   // sin version.json (build viejo) → no molesta
        var url = "https://api.github.com/repos/" + root.updSlug + "/commits/main"
        updateCheckSource.connectSource("curl -fsSL -H 'User-Agent: claude-brain' '" + url + "'")
    }
    // Jala lo último (fast-forward) y reinstala el plasmoid. NO mata plasmashell (el applet vive dentro).
    // El applet toma la versión nueva al recargar el plasmoide. FAIL-OPEN: sin repo → invita a hacerlo a mano.
    function runUpdate() {
        if (!root.updCanSelfUpdate || root.updRepoPath === "") {
            root.updateMessage = "actualiza a mano: git pull && ./install.sh"
            return
        }
        root.updating = true
        root.updateMessage = ""
        var repo = root.updRepoPath
        var inner = "cd '" + repo + "' && git fetch origin --quiet && git merge --ff-only origin/main"
                  + " && bash '" + repo + "/install.sh'"
        var cmd = "nohup bash -lc \"" + inner + "\" >/tmp/claude-brain-update.log 2>&1"
        updateRunSource.connectSource(cmd)
    }

    function inArr(a, x) { return a && a.indexOf(x) !== -1 }

    // Estado real de una pieza por nombre; espeja status(_:_:) del Swift. "" si aún no hay lectura.
    function brainStatus(name) {
        var st = root.brainState
        if (!st) return ""
        if (inArr(root.brainGlobalHooks, name)) {
            var p = inArr(st.present, name), w = inArr(st.wired, name)
            return p && w ? "installed" : (p ? "presentNotWired" : "absent")
        }
        if (inArr(root.brainRepoHooks, name)) return "repoScoped"
        if (["cerrar-slice","checkpoint","diagramar","orquestar-fanout","turno-nocturno","cosechar-sesion","unificar-cerebro"].indexOf(name) !== -1)
            return inArr(st.skills, name) ? "installed" : "absent"
        if (name === "Definition of Done" || name === "Doc <= realidad"
            || name === "Flujo de git" || name === "Costo de delegación")
            return st.hasNorms ? "installed" : "absent"
        return "absent"
    }
    // Símbolo/color de cara al usuario COLAPSADOS a binario (los 4 estados se conservan por dentro
    // para el matiz fino del detalle al tocar, vía brainStatusLabel). Espeja BrainStatus.symbol/.color
    // del Swift: installed → ✓ verde; presentNotWired Y absent → ！ rojo (se ven igual: "faltante");
    // repoScoped → ◈ azul discreto (al 60%). "" (aún sin lectura) → sin punto.
    function brainDot(s) {
        if (s === "installed") return "✓"
        if (s === "repoScoped") return "◈"
        if (s === "") return ""
        return "！"   // presentNotWired / absent / desconocido → faltante
    }
    function brainDotColor(s) {
        if (s === "installed") return "#3aa76d"
        if (s === "repoScoped") return Qt.rgba(0.290, 0.565, 0.851, 0.6)   // #4a90d9 @ 60%
        return "#dc3545"   // faltante (sin cablear / ausente / desconocido)
    }
    function brainStatusLabel(s) {
        if (s === "installed") return "instalado + cableado en tu ~/.claude"
        if (s === "presentNotWired") return "el script existe pero NO está cableado en settings.json"
        if (s === "repoScoped") return "viaja por repo: se copia al .claude/ de cada proyecto"
        return "no instalado en tu ~/.claude"
    }

    // Nombres de todas las piezas del catálogo (para el recuadro de salud).
    readonly property var brainAllNames: {
        var out = []
        for (var t = 0; t < brainTiers.length; t++)
            for (var i = 0; i < brainTiers[t].items.length; i++)
                out.push(brainTiers[t].items[i].name)
        return out
    }
    // Globales = todas menos las repo-scoped. Activas = installed.
    readonly property int brainTotal: {
        if (!brainState) return 0
        var n = 0
        for (var i = 0; i < brainAllNames.length; i++)
            if (brainStatus(brainAllNames[i]) !== "repoScoped") n++
        return n
    }
    readonly property int brainActive: {
        if (!brainState) return 0
        var n = 0
        for (var i = 0; i < brainAllNames.length; i++) {
            var s = brainStatus(brainAllNames[i])
            if (s !== "repoScoped" && s === "installed") n++
        }
        return n
    }
    // Hooks cableados fuera del catálogo (sección "➕ OTROS" — doc = realidad completa).
    readonly property var brainExtras: {
        if (!brainState || !brainState.wired) return []
        var known = brainGlobalHooks.concat(brainRepoHooks)
        var out = []
        for (var i = 0; i < brainState.wired.length; i++)
            if (known.indexOf(brainState.wired[i]) === -1) out.push(brainState.wired[i])
        out.sort()
        return out
    }

    Plasmoid.status: PlasmaCore.Types.ActiveStatus
    Plasmoid.icon: "speedometer"

    // ---------- Compact (panel/bandeja): 2 filas con mini-barras ----------
    compactRepresentation: MouseArea {
        id: compactRoot
        hoverEnabled: true
        onClicked: root.expanded = !root.expanded
        implicitWidth: col.implicitWidth + Kirigami.Units.largeSpacing * 2
        implicitHeight: Kirigami.Units.iconSizes.medium
        Layout.minimumWidth: implicitWidth
        Layout.preferredWidth: implicitWidth
        Layout.maximumWidth: implicitWidth

        readonly property real rowH: height / 2
        readonly property real fs: Math.max(9, rowH * 0.62)

        ColumnLayout {
            id: col
            anchors.centerIn: parent
            spacing: Math.max(1, compactRoot.rowH * 0.1)
            CompactRow {
                label: "5h"; pct: root.fivePct; fontPx: compactRoot.fs
                resetIso: root.snapshot && root.snapshot.five_hour ? root.snapshot.five_hour.resets_at : ""
            }
            CompactRow {
                label: "7d"; pct: root.weekPct; fontPx: compactRoot.fs
                resetIso: root.snapshot && root.snapshot.weekly ? root.snapshot.weekly.resets_at : ""
            }
        }
    }

    component CompactRow: RowLayout {
        property string label: ""
        property real pct: -1
        property string resetIso: ""
        property real fontPx: 11
        spacing: Kirigami.Units.smallSpacing
        PC3.Label { text: label; opacity: 0.7; font.pixelSize: fontPx }
        Rectangle {
            Layout.minimumWidth: fontPx * 3
            Layout.preferredWidth: fontPx * 4
            Layout.alignment: Qt.AlignVCenter
            height: Math.max(3, fontPx * 0.42)
            radius: height / 2
            visible: pct >= 0
            color: Qt.rgba(Kirigami.Theme.textColor.r, Kirigami.Theme.textColor.g, Kirigami.Theme.textColor.b, 0.15)
            Rectangle {
                anchors.left: parent.left; anchors.verticalCenter: parent.verticalCenter
                height: parent.height; radius: parent.radius
                width: parent.width * Math.max(0, Math.min(1, pct / 100))
                color: root.pctColor(pct)
            }
        }
        PC3.Label {
            text: pct >= 0 ? Math.round(pct) + "%" : (root.snapshotError ? "!" : "…")
            color: root.pctColor(pct); font.bold: true; font.pixelSize: fontPx
            Layout.minimumWidth: fontPx * 2.4; horizontalAlignment: Text.AlignRight
        }
        PC3.Label {
            visible: resetIso !== ""
            text: resetIso !== "" ? "⟳" + root.compactReset(resetIso) : ""
            opacity: 0.55; font.pixelSize: fontPx * 0.9
        }
    }

    // ---------- Full: riel de pestañas a la IZQUIERDA + contenido ----------
    fullRepresentation: RowLayout {
        Layout.preferredWidth: Kirigami.Units.gridUnit * 27
        Layout.preferredHeight: Kirigami.Units.gridUnit * 17
        spacing: 0

        // Diálogo de renombrado (compartido por proyecto y sesión). Se abre desde el menú de
        // Se abre desde el menú de clic-secundario (root.prepRename siembra + renameDialog.open() en el
        // scope del menú, que sí ve el diálogo). Vacío → "Restaurar original" (borra el alias).
        Kirigami.PromptDialog {
            id: renameDialog
            title: root.renameKind === "session" ? "Renombrar sesión" : "Renombrar proyecto"
            subtitle: root.renameKind === "session"
                ? "Nueva etiqueta para esta sesión. Vacío para restaurar la original."
                : "Nuevo nombre para este proyecto. Vacío para restaurar el original."
            standardButtons: QQC2.Dialog.NoButton
            // Al abrir, el contenido del diálogo ya está instanciado -> renameField SÍ existe aquí;
            // cargamos el texto sembrado. (Antes se hacía desde startRename, donde renameField aún no
            // existía -> ReferenceError que abortaba el open y por eso el diálogo nunca aparecía.)
            onOpened: {
                renameField.text = root.renameSeed
                renameField.selectAll()
                renameField.forceActiveFocus()
            }
            customFooterActions: [
                Kirigami.Action {
                    text: "Guardar"
                    icon.name: "dialog-ok-apply"
                    onTriggered: { root.applyRename(renameField.text); renameDialog.close() }
                },
                Kirigami.Action {
                    text: "Restaurar original"
                    icon.name: "edit-undo"
                    visible: root.renameKind === "session"
                        ? root.sessionAliased(root.renameKey)
                        : root.projectAliased(root.renameKey)
                    onTriggered: { root.applyRename(""); renameDialog.close() }
                },
                Kirigami.Action {
                    text: "Cancelar"
                    icon.name: "dialog-cancel"
                    onTriggered: renameDialog.close()
                }
            ]
            // (A) Contexto de la sesión (summary), solo lectura. Solo sesión y solo si hay summary.
            PC3.Label {
                Layout.fillWidth: true
                visible: root.renameKind === "session" && root.renameSummary !== ""
                text: root.renameSummary
                wrapMode: Text.WordWrap
                opacity: 0.7
                font.pointSize: Kirigami.Theme.smallFont.pointSize
            }
            PC3.TextField {
                id: renameField
                Layout.fillWidth: true
                onAccepted: { root.applyRename(text); renameDialog.close() }
            }
            // (A) "Sugerir nombre" (solo sesión): propone un nombre con `claude -p`. Avisa que cuesta tokens;
            // async con estado "generando…"/error, sin romper el diálogo. El resultado cae en renameField.
            RowLayout {
                Layout.fillWidth: true
                visible: root.renameKind === "session"
                spacing: Kirigami.Units.smallSpacing
                PC3.Button {
                    text: root.suggestState === "running" ? "generando…" : "Sugerir nombre"
                    enabled: root.suggestState !== "running" && root.renameSummary !== ""
                    icon.name: "tools-wizard"
                    onClicked: root.suggestName()
                    PC3.ToolTip.text: "Propone un nombre con `claude -p` a partir del contexto. Cuesta tokens."
                    PC3.ToolTip.visible: hovered
                    PC3.ToolTip.delay: 500
                }
                PC3.Label {
                    Layout.fillWidth: true
                    wrapMode: Text.WordWrap
                    font.pointSize: Kirigami.Theme.smallFont.pointSize
                    opacity: 0.6
                    color: root.suggestState === "error" ? "#dc3545" : Kirigami.Theme.textColor
                    text: root.suggestState === "running" ? "generando… (cuesta tokens)"
                        : (root.suggestState === "error" ? "no se pudo generar (¿claude en el PATH?)"
                        : (root.renameSummary === "" ? "sin contexto para sugerir" : "propone un nombre con IA · cuesta tokens"))
                }
            }
        }

        // (B) Confirmación de "Mover a…": reubica el transcript de la sesión al slug del proyecto destino.
        // Se abre desde el submenú (que SÍ ve moveDialog); lee el destino sembrado por root.prepMove.
        Kirigami.PromptDialog {
            id: moveDialog
            title: "Mover sesión"
            subtitle: "Reubica el transcript de esta sesión a otro proyecto."
            standardButtons: QQC2.Dialog.NoButton
            customFooterActions: [
                Kirigami.Action {
                    text: "Mover"
                    icon.name: "dialog-ok-apply"
                    enabled: !root.sessionMoveBusy
                    onTriggered: { root.moveSession(root.moveSessionId, root.moveTargetCwd); moveDialog.close() }
                },
                Kirigami.Action {
                    text: "Cancelar"
                    icon.name: "dialog-cancel"
                    onTriggered: moveDialog.close()
                }
            ]
            PC3.Label {
                Layout.fillWidth: true
                wrapMode: Text.WordWrap
                text: "«" + (root.moveSessionLabel !== "" ? root.moveSessionLabel : "(sesión)")
                    + "» se moverá a «" + root.moveTargetName + "».\n"
                    + "Se reescribe el cwd interno del transcript y se respalda el original (reversible)."
            }
        }

        // (B) Aviso de error al mover. Lo abre el Connections de abajo cuando root.sessionMoveError cambia.
        Kirigami.PromptDialog {
            id: moveErrorDialog
            title: "No se pudo mover la sesión"
            subtitle: root.sessionMoveError
            standardButtons: QQC2.Dialog.Ok
            onClosed: root.sessionMoveError = ""
        }

        // (A) Vuelca el nombre sugerido por IA a renameField (editable). Vive AQUÍ, no en el root, por el
        // scope gotcha de Plasma 6 (el root no ve renameField, pero fullRepresentation sí).
        Connections {
            target: root
            function onSuggestedNameChanged() {
                if (root.suggestedName !== "") renameField.text = root.suggestedName
            }
        }
        // (B) Abre el aviso de error de "Mover a…" sin romper el flujo (mismo motivo de scope).
        Connections {
            target: root
            function onSessionMoveErrorChanged() {
                if (root.sessionMoveError !== "") moveErrorDialog.open()
            }
        }

        // riel vertical de pestañas
        ColumnLayout {
            Layout.fillHeight: true
            Layout.preferredWidth: Kirigami.Units.gridUnit * 6
            Layout.margins: Kirigami.Units.smallSpacing
            spacing: Kirigami.Units.smallSpacing
            TabRailButton { idx: 0; icon: "speedometer";        label: "Límites" }
            TabRailButton { idx: 1; icon: "view-statistics";    label: "Resumen" }
            TabRailButton { idx: 2; icon: "office-chart-bar";   label: "Modelos" }
            TabRailButton { idx: 3; icon: "folder";             label: "Proyectos" }
            // Chats: solo si hay conversaciones locales (espeja `if !model.chats.isEmpty` del riel macOS).
            // Sin ícono de chat fiable en Breeze → emoji 💬 como glifo, igual que 🧠 para Cerebro.
            TabRailButton { idx: 4; emoji: "💬";                label: "Chats"; visible: root.chats && root.chats.length > 0 }
            // Sin ícono "cerebro" nativo bueno en Breeze → emoji 🧠 como glifo del riel.
            TabRailButton { idx: 5; emoji: "🧠";                label: "Cerebro" }
            Item { Layout.fillHeight: true }
            PC3.ToolButton {
                icon.name: "view-refresh"; flat: true
                Layout.alignment: Qt.AlignHCenter
                onClicked: root.forceRefresh()
                PC3.ToolTip.text: "Actualizar ahora"; PC3.ToolTip.visible: hovered; PC3.ToolTip.delay: 500
            }
        }

        Rectangle {
            Layout.fillHeight: true; Layout.preferredWidth: 1
            color: Qt.rgba(Kirigami.Theme.textColor.r, Kirigami.Theme.textColor.g, Kirigami.Theme.textColor.b, 0.12)
        }

        // contenido
        StackLayout {
            Layout.fillWidth: true; Layout.fillHeight: true
            Layout.margins: Kirigami.Units.largeSpacing
            currentIndex: root.currentTab

            // ===== Tab 0: Límites =====
            ColumnLayout {
                spacing: Kirigami.Units.largeSpacing
                Kirigami.Heading { level: 3; text: "Límites de uso"; Layout.fillWidth: true }
                UsageSection { Layout.fillWidth: true; title: "Sesión (5 h)"; block: root.snapshot ? root.snapshot.five_hour : null }
                UsageSection { Layout.fillWidth: true; title: "Semanal (7 d)"; block: root.snapshot ? root.snapshot.weekly : null }

                // Límites semanales por modelo (dinámicos): una fila por modelo.
                PC3.Label {
                    visible: root.scopedLimits.length > 0
                    text: "Por modelo (semanal)"; opacity: 0.6
                    font.pointSize: Kirigami.Theme.smallFont.pointSize
                }
                Repeater {
                    model: root.scopedLimits
                    delegate: UsageSection {
                        Layout.fillWidth: true
                        title: modelData.model
                        block: modelData
                    }
                }

                // Gasto REAL (dinero de bolsillo) — distinto del "Costo API-equiv".
                SpendSection {
                    Layout.fillWidth: true
                    spend: root.snapshot ? root.snapshot.spend : null
                    extra: root.snapshot ? root.snapshot.extra_usage : null
                }

                Item { Layout.fillHeight: true }
                PC3.Label {
                    Layout.fillWidth: true; font.pointSize: Kirigami.Theme.smallFont.pointSize
                    readonly property bool mismatch: root.snapshot && root.snapshot.account_mismatch === true
                    opacity: mismatch ? 1.0 : 0.5
                    font.bold: mismatch
                    color: mismatch ? "#dc3545" : Kirigami.Theme.textColor
                    text: {
                        if (root.snapshotError) return "error: " + root.snapshotError
                        if (!root.snapshot) return "cargando…"
                        const account = root.snapshot.account_email
                            ? root.snapshot.account_email
                            : (root.snapshot.basis === "oauth" ? "datos reales" : "estimado local")
                        if (root.snapshot.account_mismatch === true)
                            return "⚠ " + account + " no es la cuenta fijada · ⟳ 5 min + al reset 5h · act. " + root.relativeTime(root.snapshot.updated_at)
                        return account + " · ⟳ 5 min + al reset 5h · act. " + root.relativeTime(root.snapshot.updated_at)
                    }
                }
            }

            // ===== Tab 1: Resumen =====
            ColumnLayout {
                spacing: Kirigami.Units.largeSpacing
                Kirigami.Heading { level: 3; text: "Resumen"; Layout.fillWidth: true }
                GridLayout {
                    Layout.fillWidth: true; columns: 3; rowSpacing: Kirigami.Units.smallSpacing; columnSpacing: Kirigami.Units.smallSpacing
                    // Recalculadas sobre los días del rango (a ∞ coinciden con summary). Sesiones a ∞ =
                    // summary.sessions (conteo exacto); en rango = sessions.json con updated_at en rango.
                    // Racha/Hora pico se quedan all-time. Espeja resumenTab de PopoverView.swift.
                    StatCard { label: "Sesiones";        value: root.stats ? (root.rangeIdx === 3 ? root.fmtInt(root.stats.summary.sessions) : ("" + root.rSessionCount)) : "—" }
                    StatCard { label: "Mensajes";        value: root.stats ? root.fmtInt(root.rMessages) : "—" }
                    StatCard { label: "Tokens totales";  value: root.stats ? root.fmtTok(root.rTokens) : "—" }
                    StatCard { label: "Días activos";    value: root.stats ? "" + root.rActiveDays : "—" }
                    StatCard { label: "Racha actual";    value: root.currentStreak + "d" }
                    StatCard { label: "Racha más larga"; value: root.longestStreak + "d" }
                    StatCard { label: "Hora pico";       value: root.stats ? root.fmtHour(root.stats.summary.peak_hour) : "—" }
                    StatCard { label: "Modelo favorito"; value: root.stats ? (root.rModels.length ? root.prettyModel(root.rModels[0].model) : "—") : "—" }
                    StatCard { label: "Costo API-equiv"; value: root.stats ? "$" + root.rCost.toFixed(0) : "—" }
                }
                PC3.Label { text: "Actividad diaria (local)"; opacity: 0.6; font.pointSize: Kirigami.Theme.smallFont.pointSize }
                // heatmap tipo GitHub
                Item {
                    Layout.fillWidth: true; Layout.fillHeight: true
                    Grid {
                        id: heatGrid
                        rows: 7; flow: Grid.TopToBottom
                        rowSpacing: 3; columnSpacing: 3
                        readonly property real cell: Math.max(8, Math.min(16, (height - 6 * 3) / 7))
                        Repeater {
                            model: root.heatmapCells()
                            delegate: Rectangle {
                                width: heatGrid.cell; height: heatGrid.cell; radius: 3
                                color: modelData.tokens <= 0
                                       ? Qt.rgba(Kirigami.Theme.textColor.r, Kirigami.Theme.textColor.g, Kirigami.Theme.textColor.b, 0.08)
                                       : Qt.rgba(0.91, 0.53, 0.29, 0.25 + 0.75 * Math.min(1, modelData.tokens / root.maxDayTokens))
                            }
                        }
                    }
                }
                // El heatmap se queda all-time (histórico completo); el footer solo recorta las tarjetas.
                RangeFooter { machineToggle: true }
            }

            // ===== Tab 2: Modelos =====
            ColumnLayout {
                spacing: Kirigami.Units.largeSpacing
                Kirigami.Heading { level: 3; text: "Uso por modelo"; Layout.fillWidth: true }
                // gráfico de barras apiladas por día
                Item {
                    id: chartArea
                    Layout.fillWidth: true; Layout.preferredHeight: Kirigami.Units.gridUnit * 7
                    RowLayout {
                        anchors.fill: parent; spacing: 2
                        Repeater {
                            model: root.rDays
                            delegate: Item {
                                Layout.fillWidth: true; Layout.fillHeight: true
                                property var day: modelData
                                ColumnLayout {
                                    anchors.bottom: parent.bottom; anchors.left: parent.left; anchors.right: parent.right
                                    spacing: 0
                                    Repeater {
                                        model: day.models
                                        delegate: Rectangle {
                                            Layout.fillWidth: true
                                            Layout.preferredHeight: chartArea.height * (modelData.tokens / root.rMaxDayTokens)
                                            color: root.modelColorFor(modelData.model)
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
                // tabla de modelos — scrolleable: muchos modelos → scroll interno,
                // popup de tamaño estable (no crece ni se corta la lista).
                PC3.ScrollView {
                    id: modelsScroll
                    Layout.fillWidth: true; Layout.fillHeight: true
                    contentWidth: availableWidth   // sin scroll horizontal
                    clip: true
                    ColumnLayout {
                        width: modelsScroll.availableWidth
                        spacing: Kirigami.Units.smallSpacing
                        Repeater {
                            model: root.rModels
                            delegate: RowLayout {
                                Layout.fillWidth: true; spacing: Kirigami.Units.smallSpacing
                                Rectangle { width: 10; height: 10; radius: 2; color: root.modelColorFor(modelData.model) }
                                PC3.Label { text: root.prettyModel(modelData.model); font.bold: true }
                                Item { Layout.fillWidth: true }
                                PC3.Label {
                                    opacity: 0.7
                                    text: root.fmtTok(modelData.in_tok) + " in · " + root.fmtTok(modelData.out_tok) + " out"
                                }
                                PC3.Label {
                                    text: modelData.pct.toFixed(1) + "%"; font.bold: true
                                    color: root.modelColorFor(modelData.model)
                                    Layout.minimumWidth: Kirigami.Units.gridUnit * 2.5; horizontalAlignment: Text.AlignRight
                                }
                            }
                        }
                    }
                }
                RangeFooter { machineToggle: true }
            }

            // ===== Tab 3: Proyectos =====
            // Uso de Claude Code por carpeta de proyecto (subconjunto de Modelos). Espeja el
            // proyectosTab del Swift / PaintProyectos de Windows: gráfica apilada por día + lista.
            ColumnLayout {
                spacing: Kirigami.Units.largeSpacing
                Kirigami.Heading { level: 3; text: "Uso por proyecto"; Layout.fillWidth: true }
                // gráfico de barras apiladas por día (mismo eje que Modelos: normalizado por maxDayTokens)
                Item {
                    id: projChartArea
                    Layout.fillWidth: true; Layout.preferredHeight: Kirigami.Units.gridUnit * 7
                    RowLayout {
                        anchors.fill: parent; spacing: 2
                        Repeater {
                            model: root.rDays
                            delegate: Item {
                                Layout.fillWidth: true; Layout.fillHeight: true
                                property var day: modelData
                                ColumnLayout {
                                    anchors.bottom: parent.bottom; anchors.left: parent.left; anchors.right: parent.right
                                    spacing: 0
                                    Repeater {
                                        model: day.projects
                                        delegate: Rectangle {
                                            Layout.fillWidth: true
                                            Layout.preferredHeight: projChartArea.height * (modelData.tokens / root.rMaxDayProjectTokens)
                                            color: root.projectColorFor(modelData.project)
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
                // tabla de proyectos — scrolleable (muchos proyectos → scroll interno, popup estable)
                PC3.ScrollView {
                    id: projScroll
                    Layout.fillWidth: true; Layout.fillHeight: true
                    contentWidth: availableWidth   // sin scroll horizontal
                    clip: true
                    ColumnLayout {
                        width: projScroll.availableWidth
                        spacing: Kirigami.Units.smallSpacing
                        Repeater {
                            model: root.rProjects
                            // Fila de proyecto: swatch + nombre (+ chevron si tiene sesiones) + in/out + %.
                            // Si tiene sesiones de Claude Code, es expandible → lista sus sesiones (máx 12);
                            // click en una lanza una terminal con `claude --resume`. Espeja projectRow/sessionsList.
                            delegate: ColumnLayout {
                                Layout.fillWidth: true
                                spacing: 2
                                readonly property string projName: modelData.project ? modelData.project : "—"
                                readonly property int nSess: root.sessionCountForProject(projName)
                                readonly property bool expanded: root.expandedProject === projName

                                MouseArea {
                                    Layout.fillWidth: true
                                    implicitHeight: prow.implicitHeight
                                    hoverEnabled: true
                                    acceptedButtons: Qt.LeftButton | Qt.RightButton
                                    cursorShape: nSess > 0 ? Qt.PointingHandCursor : Qt.ArrowCursor
                                    onClicked: function(mouse) {
                                        if (mouse.button === Qt.RightButton) projMenu.popup()
                                        else if (nSess > 0) root.expandedProject = expanded ? "" : projName
                                    }
                                    // Clic-secundario → renombrar el proyecto (y restaurar si tiene alias).
                                    QQC2.Menu {
                                        id: projMenu
                                        QQC2.MenuItem {
                                            text: "Renombrar…"
                                            // prep en root + open en ESTE scope (el menú SÍ ve renameDialog).
                                            onTriggered: { root.prepRename("project", projName, projName); renameDialog.open() }
                                        }
                                        QQC2.MenuItem {
                                            text: "Restaurar original"
                                            visible: root.projectAliased(projName)
                                            height: visible ? implicitHeight : 0
                                            onTriggered: root.renameProject(projName, "")
                                        }
                                    }
                                    RowLayout {
                                        id: prow
                                        anchors.left: parent.left; anchors.right: parent.right
                                        anchors.verticalCenter: parent.verticalCenter
                                        spacing: Kirigami.Units.smallSpacing
                                        Rectangle { width: 10; height: 10; radius: 2; color: root.projectColorFor(modelData.project) }
                                        PC3.Label {
                                            text: projName; font.bold: true
                                            elide: Text.ElideRight; Layout.maximumWidth: Kirigami.Units.gridUnit * 8
                                        }
                                        PC3.Label {
                                            visible: nSess > 0
                                            text: expanded ? "▾" : "▸"; opacity: 0.5
                                            font.pointSize: Kirigami.Theme.smallFont.pointSize
                                        }
                                        Item { Layout.fillWidth: true }
                                        PC3.Label {
                                            opacity: 0.7
                                            text: root.fmtTok(modelData.in_tok) + " in · " + root.fmtTok(modelData.out_tok) + " out"
                                        }
                                        PC3.Label {
                                            text: modelData.pct.toFixed(1) + "%"; font.bold: true
                                            color: root.projectColorFor(modelData.project)
                                            Layout.minimumWidth: Kirigami.Units.gridUnit * 2.5; horizontalAlignment: Text.AlignRight
                                        }
                                    }
                                }
                                // Sesiones del proyecto (al desplegar): cada una resume en su cwd.
                                ColumnLayout {
                                    Layout.fillWidth: true
                                    Layout.leftMargin: Kirigami.Units.gridUnit
                                    visible: expanded
                                    spacing: 2
                                    Repeater {
                                        model: expanded ? root.sessionsForProject(projName) : []
                                        delegate: MouseArea {
                                            Layout.fillWidth: true
                                            implicitHeight: srow.implicitHeight
                                            hoverEnabled: true
                                            acceptedButtons: Qt.LeftButton | Qt.RightButton
                                            cursorShape: Qt.PointingHandCursor
                                            onClicked: function(mouse) {
                                                if (mouse.button === Qt.RightButton) sessMenu.popup()
                                                else root.resumeSession(modelData.cwd, modelData.id)
                                            }
                                            PC3.ToolTip.text: "Resumir en " + modelData.cwd
                                            PC3.ToolTip.visible: containsMouse
                                            PC3.ToolTip.delay: 500
                                            // Clic-secundario → renombrar la sesión (llave = id estable).
                                            QQC2.Menu {
                                                id: sessMenu
                                                QQC2.MenuItem {
                                                    text: "Renombrar…"
                                                    onTriggered: { root.prepRename("session", modelData.id, modelData.label ? modelData.label : "", modelData.summary ? modelData.summary : ""); renameDialog.open() }
                                                }
                                                QQC2.MenuItem {
                                                    text: "Restaurar original"
                                                    visible: root.sessionAliased(modelData.id)
                                                    height: visible ? implicitHeight : 0
                                                    onTriggered: root.renameSession(modelData.id, "")
                                                }
                                                // (B) "Mover a…": submenú con los OTROS proyectos conocidos
                                                // (deriva de las sesiones cargadas; excluye el actual). Al
                                                // elegir, siembra el destino y abre el diálogo de confirmación.
                                                // OJO: dentro del Repeater `modelData` es el PROYECTO destino,
                                                // así que la sesión (id/label/project) se captura ANTES, en las
                                                // props de sessMoveMenu, donde `modelData` aún es la sesión.
                                                QQC2.Menu {
                                                    id: sessMoveMenu
                                                    title: "Mover a…"
                                                    readonly property string sessId: modelData.id
                                                    readonly property string sessLabel: modelData.label ? modelData.label : ""
                                                    readonly property string sessProject: modelData.project ? modelData.project : ""
                                                    readonly property var others: root.otherProjects(sessMoveMenu.sessProject)
                                                    // Ítems dinámicos por el patrón oficial de QQC2 (Instantiator
                                                    // + insertItem/removeItem); un Repeater directo en Menu no es
                                                    // fiable entre versiones de Qt6.
                                                    Instantiator {
                                                        model: sessMoveMenu.others
                                                        delegate: QQC2.MenuItem {
                                                            text: modelData.name
                                                            onTriggered: {
                                                                root.prepMove(sessMoveMenu.sessId, sessMoveMenu.sessLabel, modelData.cwd, modelData.name)
                                                                moveDialog.open()
                                                            }
                                                        }
                                                        onObjectAdded: (index, object) => sessMoveMenu.insertItem(index, object)
                                                        onObjectRemoved: (index, object) => sessMoveMenu.removeItem(object)
                                                    }
                                                    QQC2.MenuItem {
                                                        text: "(no hay otros proyectos)"
                                                        enabled: false
                                                        visible: sessMoveMenu.others.length === 0
                                                        height: visible ? implicitHeight : 0
                                                    }
                                                }
                                            }
                                            RowLayout {
                                                id: srow
                                                anchors.left: parent.left; anchors.right: parent.right
                                                anchors.verticalCenter: parent.verticalCenter
                                                spacing: Kirigami.Units.smallSpacing
                                                PC3.Label { text: "↺"; color: "#e8884a" }
                                                PC3.Label {
                                                    text: modelData.label ? modelData.label : "(sesión)"
                                                    font.pointSize: Kirigami.Theme.smallFont.pointSize
                                                    elide: Text.ElideRight; Layout.fillWidth: true
                                                }
                                                PC3.Label {
                                                    text: root.relDate(modelData.updated_at)
                                                    opacity: 0.5; font.pointSize: Kirigami.Theme.smallFont.pointSize * 0.9
                                                }
                                            }
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
                RangeFooter { machineToggle: true }
            }

            // ===== Tab 4: Chats =====
            // Conversaciones recientes del app de escritorio (chats.json, leído sin red ni cookies).
            // READ-ONLY (sin abrir el chat: no hay deep-link fiable). Desglose por modelo + lista de
            // recientes + pie con el resumen del chat bajo el cursor. Espeja chatsTab de PopoverView.swift.
            // El riel solo muestra esta pestaña si hay chats (ver TabRailButton idx 4).
            ColumnLayout {
                spacing: Kirigami.Units.largeSpacing
                Kirigami.Heading { level: 3; text: "Chats"; Layout.fillWidth: true }

                PC3.Label {
                    visible: root.rChats.length === 0
                    Layout.fillWidth: true; opacity: 0.6; wrapMode: Text.WordWrap
                    font.pointSize: Kirigami.Theme.smallFont.pointSize
                    text: root.rangeIdx === 3
                          ? "Sin conversaciones locales.\nAbre el app de escritorio de Claude y espera al próximo refresco."
                          : "Sin conversaciones en este rango."
                }

                // Desglose por modelo (swatch + modelo + conteo + %).
                ColumnLayout {
                    Layout.fillWidth: true
                    visible: root.rChats.length > 0
                    spacing: Kirigami.Units.smallSpacing
                    Repeater {
                        model: root.chatsByModel(root.rChats)
                        delegate: RowLayout {
                            Layout.fillWidth: true; spacing: Kirigami.Units.smallSpacing
                            Rectangle { width: 10; height: 10; radius: 2; color: root.modelColorFor(modelData.model) }
                            PC3.Label { text: root.prettyModel(modelData.model); font.bold: true }
                            Item { Layout.fillWidth: true }
                            PC3.Label { opacity: 0.7; text: "" + modelData.count }
                            PC3.Label {
                                text: modelData.pct.toFixed(0) + "%"; font.bold: true
                                color: root.modelColorFor(modelData.model)
                                Layout.minimumWidth: Kirigami.Units.gridUnit * 2.5; horizontalAlignment: Text.AlignRight
                            }
                        }
                    }
                }

                Rectangle {
                    visible: root.rChats.length > 0
                    Layout.fillWidth: true; Layout.preferredHeight: 1
                    color: Qt.rgba(Kirigami.Theme.textColor.r, Kirigami.Theme.textColor.g, Kirigami.Theme.textColor.b, 0.12)
                }
                PC3.Label {
                    visible: root.rChats.length > 0
                    text: "recientes"; opacity: 0.5; font.pointSize: Kirigami.Theme.smallFont.pointSize
                }

                // Lista de recientes (título + badge de modelo + fecha relativa). Hover → resumen en el pie.
                PC3.ScrollView {
                    id: chatsScroll
                    visible: root.rChats.length > 0
                    Layout.fillWidth: true; Layout.fillHeight: true
                    contentWidth: availableWidth   // sin scroll horizontal
                    clip: true
                    ColumnLayout {
                        width: chatsScroll.availableWidth
                        spacing: Kirigami.Units.smallSpacing
                        Repeater {
                            model: root.rChats.slice(0, 20)
                            delegate: MouseArea {
                                Layout.fillWidth: true
                                implicitHeight: crow.implicitHeight
                                hoverEnabled: true
                                onEntered: root.hoveredChatSummary = modelData.summary ? modelData.summary : ""
                                onExited: root.hoveredChatSummary = ""
                                RowLayout {
                                    id: crow
                                    anchors.left: parent.left; anchors.right: parent.right
                                    anchors.verticalCenter: parent.verticalCenter
                                    spacing: Kirigami.Units.smallSpacing
                                    PC3.Label {
                                        text: modelData.title ? modelData.title : "(sin título)"
                                        elide: Text.ElideRight; Layout.fillWidth: true
                                    }
                                    Rectangle {   // badge de modelo (cápsula tenue en el color del modelo)
                                        visible: !!modelData.model
                                        radius: height / 2
                                        implicitHeight: badgeLbl.implicitHeight + 2
                                        implicitWidth: badgeLbl.implicitWidth + Kirigami.Units.smallSpacing * 2
                                        color: root.withAlpha(root.modelColorFor(modelData.model), 0.22)
                                        PC3.Label {
                                            id: badgeLbl
                                            anchors.centerIn: parent
                                            text: root.prettyModel(modelData.model)
                                            color: root.modelColorFor(modelData.model)
                                            font.bold: true; font.pointSize: Kirigami.Theme.smallFont.pointSize * 0.9
                                        }
                                    }
                                    PC3.Label {
                                        text: root.relDate(modelData.updated_at ? modelData.updated_at : modelData.created_at)
                                        opacity: 0.6; font.pointSize: Kirigami.Theme.smallFont.pointSize
                                        Layout.minimumWidth: Kirigami.Units.gridUnit * 3; horizontalAlignment: Text.AlignRight
                                    }
                                }
                            }
                        }
                    }
                }

                // Pie: resumen del chat bajo el cursor (hover).
                Rectangle {
                    visible: root.rChats.length > 0
                    Layout.fillWidth: true; Layout.preferredHeight: 1
                    color: Qt.rgba(Kirigami.Theme.textColor.r, Kirigami.Theme.textColor.g, Kirigami.Theme.textColor.b, 0.12)
                }
                PC3.Label {
                    visible: root.rChats.length > 0
                    Layout.fillWidth: true; Layout.minimumHeight: Kirigami.Units.gridUnit * 3
                    wrapMode: Text.WordWrap; maximumLineCount: 4; elide: Text.ElideRight
                    font.pointSize: Kirigami.Theme.smallFont.pointSize
                    opacity: root.hoveredChatSummary === "" ? 0.4 : 0.75
                    text: root.hoveredChatSummary === "" ? "Pasa el cursor sobre un chat para ver su resumen." : root.hoveredChatSummary
                }

                // Cuando la lista está vacía, empuja el footer al fondo (la ScrollView invisible no llena).
                Item { Layout.fillHeight: true; visible: root.rChats.length === 0 }

                RangeFooter {}
            }

            // ===== Tab 5: Cerebro (VIVO) =====
            // Infografía del cerebro global de Claude Code: la ESTRUCTURA es curada (refleja `brain/`),
            // pero el ESTADO de cada pieza se LEE de la realidad (~/.claude vía brain-scan.sh) y se pinta
            // con un punto de estado por hoja + un recuadro de salud arriba. Cada hoja es clickeable
            // (despliega su evento + detalle). Se re-lee al abrir la pestaña. Espeja cerebroTab del Swift.
            PC3.ScrollView {
                id: cerebroScroll
                contentWidth: availableWidth   // sin scroll horizontal; solo vertical
                clip: true
                Component.onCompleted: { root.scanBrain(); root.checkUpdate() }   // primera lectura + chequeo de versión
                ColumnLayout {
                    width: cerebroScroll.availableWidth
                    spacing: Kirigami.Units.largeSpacing
                    // Encabezado de marca: ícono claude-brain (ya incluye el destello) + "Cerebro global".
                    RowLayout {
                        Layout.fillWidth: true
                        spacing: Kirigami.Units.smallSpacing
                        Image {
                            source: Qt.resolvedUrl("brand-icon.svg")
                            Layout.preferredWidth: Kirigami.Units.iconSizes.small
                            Layout.preferredHeight: Kirigami.Units.iconSizes.small
                            fillMode: Image.PreserveAspectFit
                            smooth: true
                            sourceSize.width: 64; sourceSize.height: 64
                        }
                        Kirigami.Heading { level: 3; text: "Cerebro global"; Layout.fillWidth: true }
                        // Enlace discreto al MAPA del cerebro: docs/mapa-cerebro.md versionado en el
                        // repo (GitHub). Abre el navegador del sistema (espeja mapaButton del Swift).
                        PC3.ToolButton {
                            text: "🗺 mapa"
                            onClicked: Qt.openUrlExternally("https://github.com/unjordi/claude-brain/blob/main/docs/mapa-cerebro.md")
                            PC3.ToolTip.text: "Abre el mapa del cerebro (docs/mapa-cerebro.md del repo) en tu navegador."
                            PC3.ToolTip.visible: hovered
                            PC3.ToolTip.delay: 500
                        }
                    }
                    PC3.Label {
                        Layout.fillWidth: true; opacity: 0.6; wrapMode: Text.WordWrap
                        font.pointSize: Kirigami.Theme.smallFont.pointSize
                        text: "Guardarraíles + gobernanza + normas de Claude Code. Viaja por git, aplica en toda máquina. De más duro (arriba) a más leve (abajo). Toca una pieza para ver su evento y un ejemplo."
                    }

                    // Banner de AUTOUPDATE (winturbo-style, espeja updateBanner de PopoverView.swift):
                    // solo aparece si el repo avanzó respecto al build empaquetado. Naranja #e8884a @16%.
                    // Al pulsarlo corre git ff + install.sh (ver runUpdate); en KDE el applet toma la
                    // versión nueva al RECARGAR el plasmoide (kquitapp6 plasmashell && kstart plasmashell,
                    // o re-loguear) — no se fuerza aquí. Fail-open: sin repo → "actualiza a mano", no hace nada.
                    Rectangle {
                        id: updBanner
                        Layout.fillWidth: true
                        visible: root.updateAvailable || root.updating || root.updateMessage !== ""
                        radius: Kirigami.Units.smallSpacing
                        color: Qt.rgba(0.91, 0.53, 0.29, 0.16)   // #e8884a @ 16%
                        implicitHeight: updRow.implicitHeight + Kirigami.Units.smallSpacing * 2
                        RowLayout {
                            id: updRow
                            anchors.left: parent.left; anchors.right: parent.right
                            anchors.verticalCenter: parent.verticalCenter
                            anchors.margins: Kirigami.Units.smallSpacing
                            spacing: Kirigami.Units.smallSpacing
                            PC3.Label {
                                Layout.fillWidth: true; wrapMode: Text.WordWrap
                                color: "#e8884a"; font.bold: true
                                font.pointSize: Kirigami.Theme.smallFont.pointSize
                                text: root.updating
                                      ? "… Actualizando… (recarga el widget al terminar)"
                                      : (root.updateMessage !== ""
                                         ? root.updateMessage
                                         : (root.updCanSelfUpdate
                                            ? "⬆ Actualizar widget (" + root.updLocalShort + " → " + root.updRemoteShort + ")"
                                            : "⬆ Hay versión nueva (" + root.updRemoteShort + ") — actualiza a mano"))
                            }
                        }
                        MouseArea {
                            anchors.fill: parent
                            hoverEnabled: true
                            cursorShape: Qt.PointingHandCursor
                            enabled: !root.updating && root.updCanSelfUpdate && root.updateAvailable
                            onClicked: root.runUpdate()
                            PC3.ToolTip.text: root.updCanSelfUpdate
                                ? "Corre git fetch + merge --ff-only origin/main + install.sh en tu clon. En KDE el applet toma la versión nueva al recargar el plasmoide (kquitapp6 plasmashell && kstart plasmashell, o re-loguear)."
                                : "No hay 'repo' en version.json; actualiza a mano con git pull && ./install.sh."
                            PC3.ToolTip.visible: containsMouse
                            PC3.ToolTip.delay: 500
                        }
                    }

                    // Recuadro de SALUD: piezas globales activas + leyenda + hora + botón-curita.
                    BrainHealth { Layout.fillWidth: true }

                    Repeater {
                        model: root.brainTiers
                        delegate: BrainTier {
                            Layout.fillWidth: true
                            tierIndex: index
                            emoji: modelData.emoji
                            title: modelData.title
                            accent: modelData.color
                            subtitle: modelData.subtitle
                            items: modelData.items
                        }
                    }

                    // ➕ OTROS: hooks cableados en tu settings.json fuera del catálogo del cerebro.
                    RowLayout {
                        Layout.fillWidth: true
                        visible: root.brainExtras.length > 0
                        spacing: Kirigami.Units.smallSpacing
                        Rectangle {
                            Layout.preferredWidth: 3; Layout.fillHeight: true
                            Layout.topMargin: 2; Layout.bottomMargin: 2
                            radius: 1
                            color: Qt.rgba(Kirigami.Theme.textColor.r, Kirigami.Theme.textColor.g, Kirigami.Theme.textColor.b, 0.3)
                        }
                        ColumnLayout {
                            Layout.fillWidth: true
                            spacing: Kirigami.Units.smallSpacing
                            RowLayout {
                                Layout.fillWidth: true; spacing: Kirigami.Units.smallSpacing
                                PC3.Label { text: "➕"; font.pointSize: Kirigami.Theme.defaultFont.pointSize * 1.1 }
                                PC3.Label { text: "OTROS"; font.bold: true; opacity: 0.5 }
                                Item { Layout.fillWidth: true }
                            }
                            PC3.Label {
                                Layout.fillWidth: true; opacity: 0.6; wrapMode: Text.WordWrap
                                font.pointSize: Kirigami.Theme.smallFont.pointSize
                                text: "hooks cableados en tu settings.json, fuera del catálogo del cerebro"
                            }
                            Repeater {
                                model: root.brainExtras
                                delegate: RowLayout {
                                    Layout.fillWidth: true; spacing: Kirigami.Units.smallSpacing
                                    PC3.Label { text: "●"; color: "#3aa76d"; opacity: 0.55; font.pointSize: Kirigami.Theme.smallFont.pointSize }
                                    PC3.Label { text: modelData; font.family: "monospace" }
                                    Item { Layout.fillWidth: true }
                                }
                            }
                        }
                    }

                    PC3.Label {
                        Layout.fillWidth: true; opacity: 0.45; wrapMode: Text.WordWrap
                        font.pointSize: Kirigami.Theme.smallFont.pointSize
                        text: "Instalado por install-brain.sh · probado por test-brain.sh · sin jq los hooks fallan ABIERTO (no bloquean)."
                    }
                }
            }
        }
    }

    // botón del riel de pestañas
    component TabRailButton: Rectangle {
        property int idx: 0
        property string icon: ""
        property string emoji: ""   // glifo alterno cuando no hay ícono nativo (p.ej. 🧠)
        property string label: ""
        Layout.fillWidth: true
        Layout.preferredHeight: Kirigami.Units.gridUnit * 2
        radius: Kirigami.Units.smallSpacing
        readonly property bool active: root.currentTab === idx
        color: active ? Qt.rgba(0.91, 0.53, 0.29, 0.18)
                      : (mouse.containsMouse ? Qt.rgba(Kirigami.Theme.textColor.r, Kirigami.Theme.textColor.g, Kirigami.Theme.textColor.b, 0.08) : "transparent")
        RowLayout {
            anchors.fill: parent; anchors.leftMargin: Kirigami.Units.smallSpacing; spacing: Kirigami.Units.smallSpacing
            Kirigami.Icon {
                visible: emoji === ""
                source: icon
                Layout.preferredWidth: Kirigami.Units.iconSizes.small; Layout.preferredHeight: Kirigami.Units.iconSizes.small
                color: active ? "#e8884a" : Kirigami.Theme.textColor
                isMask: true
            }
            // El emoji no se puede tintar; el estado activo se marca con la etiqueta.
            PC3.Label {
                visible: emoji !== ""
                text: emoji
                Layout.preferredWidth: Kirigami.Units.iconSizes.small
                horizontalAlignment: Text.AlignHCenter
            }
            PC3.Label { text: label; font.bold: active; color: active ? "#e8884a" : Kirigami.Theme.textColor }
            Item { Layout.fillWidth: true }
        }
        MouseArea { id: mouse; anchors.fill: parent; hoverEnabled: true; onClicked: root.currentTab = idx }
    }

    // Footer con las 4 píldoras de rango {hoy·7d·30d·∞} al PIE de Resumen/Modelos/Proyectos/Chats.
    // La activa va en acento (#e8884a @20% de fondo); las demás tenues. Espeja rangeFooter del Swift.
    // Si `machineToggle` y hay vista sincronizada (e), agrega a la derecha el par 🖥 esta / ☁️ todas.
    component RangeFooter: RowLayout {
        // Muestra el par de píldoras 🖥/☁️ a la derecha (solo Resumen/Modelos/Proyectos, NO Chats).
        property bool machineToggle: false
        Layout.fillWidth: true
        Layout.topMargin: 2
        spacing: Kirigami.Units.smallSpacing
        Repeater {
            model: root.rangeLabels
            delegate: Rectangle {
                readonly property bool active: root.rangeIdx === index
                radius: Kirigami.Units.smallSpacing
                implicitHeight: pillLbl.implicitHeight + Kirigami.Units.smallSpacing
                implicitWidth: pillLbl.implicitWidth + Kirigami.Units.largeSpacing
                color: active ? Qt.rgba(0.91, 0.53, 0.29, 0.20)   // #e8884a @ 20%
                              : Qt.rgba(Kirigami.Theme.textColor.r, Kirigami.Theme.textColor.g, Kirigami.Theme.textColor.b, 0.06)
                PC3.Label {
                    id: pillLbl
                    anchors.centerIn: parent
                    text: modelData
                    font.bold: active
                    color: active ? "#e8884a" : Kirigami.Theme.textColor
                    opacity: active ? 1.0 : 0.7
                    font.pointSize: Kirigami.Theme.smallFont.pointSize
                }
                MouseArea {
                    anchors.fill: parent
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    onClicked: root.rangeIdx = index
                }
            }
        }
        Item { Layout.fillWidth: true }
        // (e) Par 🖥 esta máquina / ☁️ todas. Solo si se pidió el toggle Y hay stats-global.json con
        // datos. Mismo estilo que las píldoras de rango (activa en acento @20%). Espeja `machinePills`.
        RowLayout {
            spacing: Kirigami.Units.smallSpacing
            visible: machineToggle && root.hasGlobal
            Repeater {
                // 0 = 🖥 esta máquina (useGlobal=false); 1 = ☁️ todas (useGlobal=true, con conteo si >1).
                model: 2
                delegate: Rectangle {
                    readonly property bool global: index === 1
                    readonly property bool on: root.useGlobal === global
                    radius: Kirigami.Units.smallSpacing
                    implicitHeight: mpLbl.implicitHeight + Kirigami.Units.smallSpacing
                    implicitWidth: mpLbl.implicitWidth + Kirigami.Units.largeSpacing
                    color: on ? Qt.rgba(0.91, 0.53, 0.29, 0.20)   // #e8884a @ 20%
                              : Qt.rgba(Kirigami.Theme.textColor.r, Kirigami.Theme.textColor.g, Kirigami.Theme.textColor.b, 0.06)
                    PC3.Label {
                        id: mpLbl
                        anchors.centerIn: parent
                        text: global ? ("☁️" + (root.globalMachineCount > 1 ? " " + root.globalMachineCount : ""))
                                     : "🖥"
                        font.bold: on
                        color: on ? "#e8884a" : Kirigami.Theme.textColor
                        opacity: on ? 1.0 : 0.7
                        font.pointSize: Kirigami.Theme.smallFont.pointSize
                    }
                    MouseArea {
                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onClicked: root.useGlobal = global
                        PC3.ToolTip.text: root.useGlobal ? "Mostrando el uso combinado de todas tus máquinas (sync)"
                                                         : "Mostrando solo esta máquina"
                        PC3.ToolTip.visible: containsMouse
                        PC3.ToolTip.delay: 500
                    }
                }
            }
        }
    }

    // Recuadro de SALUD del cerebro global, de cara al usuario BINARIO (espeja brainHealth del Swift):
    // todo activo → ✓ verde "Cerebro global completo y activo"; falta algo → 🩹 rojo "Tu cerebro global
    // está incompleto". Conserva la hora de lectura y el botón-curita 🩹 (solo si falta algo). SIN leyenda
    // de 4 estados: el matiz fino vive en el detalle al tocar cada pieza (brainStatusLabel).
    component BrainHealth: Rectangle {
        id: health
        readonly property bool ready: root.brainState !== null
        readonly property bool allGood: ready && root.brainActive === root.brainTotal
        readonly property int missing: ready ? (root.brainTotal - root.brainActive) : 0
        readonly property bool healingNow: root.brainHeal === "running"
        readonly property color healTint: missing > 0 ? "#dc3545" : "#e8884a"
        Layout.fillWidth: true
        implicitHeight: healthCol.implicitHeight + Kirigami.Units.smallSpacing * 2
        radius: Kirigami.Units.smallSpacing
        color: Qt.rgba(Kirigami.Theme.textColor.r, Kirigami.Theme.textColor.g, Kirigami.Theme.textColor.b, 0.05)

        ColumnLayout {
            id: healthCol
            anchors.fill: parent
            anchors.margins: Kirigami.Units.smallSpacing
            spacing: Kirigami.Units.smallSpacing

            // Línea 1 (BINARIA): sello + veredicto de una línea + hora de lectura. Sin conteo N/M ni
            // leyenda de cara al usuario: verde = todo bien, rojo = algo falta (cúralo).
            RowLayout {
                Layout.fillWidth: true; spacing: Kirigami.Units.smallSpacing
                PC3.Label { text: health.allGood ? "✓" : "🩹"; color: health.allGood ? "#3aa76d" : "#dc3545"; font.bold: true }
                PC3.Label {
                    Layout.fillWidth: true; font.bold: true; wrapMode: Text.WordWrap
                    font.pointSize: Kirigami.Theme.smallFont.pointSize
                    text: health.ready
                          ? (health.allGood ? "Cerebro global completo y activo"
                                             : "Tu cerebro global está incompleto")
                          : "leyendo tu ~/.claude…"
                }
                // Versión INSTALADA del brain (sello .brain-version), discreta junto al veredicto.
                PC3.Label {
                    visible: root.brainVersion !== ""
                    text: "· v" + root.brainVersion
                    opacity: 0.5
                    font.pointSize: Kirigami.Theme.smallFont.pointSize
                }
                PC3.Label {
                    visible: root.brainScannedAt !== ""
                    text: "leído " + root.brainScannedAt
                    opacity: 0.4; font.pointSize: Kirigami.Theme.smallFont.pointSize * 0.9
                }
            }

            // Línea 2: botón-curita self-healing 🩹 (rojo cruz-roja). SOLO visible si hay algo que
            // curar; sano (10/10) → sin botón ni "curado" (el sello verde ya lo dice todo).
            RowLayout {
                Layout.fillWidth: true; spacing: Kirigami.Units.smallSpacing
                visible: health.missing > 0
                Rectangle {
                    id: healBtn
                    radius: Kirigami.Units.smallSpacing
                    color: Qt.rgba(health.healTint.r, health.healTint.g, health.healTint.b, 0.16)
                    implicitWidth: healRow.implicitWidth + Kirigami.Units.smallSpacing * 2
                    implicitHeight: healRow.implicitHeight + Kirigami.Units.smallSpacing
                    opacity: health.healingNow ? 0.7 : 1.0
                    RowLayout {
                        id: healRow
                        anchors.centerIn: parent
                        spacing: Kirigami.Units.smallSpacing
                        PC3.Label {
                            // Curita/cruz-roja como glifo (no hay ícono Breeze fiable de "bandage").
                            text: health.healingNow ? "…" : "🩹"
                            color: health.healTint
                        }
                        PC3.Label {
                            font.bold: true; font.pointSize: Kirigami.Theme.smallFont.pointSize
                            color: health.healTint
                            text: health.healingNow
                                  ? "Curando…"
                                  : (health.missing > 0
                                     ? "Curar cerebro global (" + health.missing + ")"
                                     : "Actualizar cerebro global")
                        }
                    }
                    MouseArea {
                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        enabled: !health.healingNow
                        onClicked: root.healBrainGlobal()
                        PC3.ToolTip.text: "Corre install-brain.sh (localiza el instalador; en Linux ver la NOTA DE RUTA en brain-scan.sh): copia/cablea hooks globales, skill y normas en tu ~/.claude. Idempotente."
                        PC3.ToolTip.visible: containsMouse
                        PC3.ToolTip.delay: 500
                    }
                }
                PC3.Label {
                    visible: root.brainHeal === "ok" || root.brainHeal === "error"
                    text: root.brainHeal === "ok" ? "✓ curado" : "✗ error (¿jq / ruta del install-brain.sh?)"
                    opacity: 0.6; font.pointSize: Kirigami.Theme.smallFont.pointSize * 0.9
                }
                Item { Layout.fillWidth: true }
            }
        }
    }

    // Un nivel (tier) del cerebro: espina/barra de color a la izquierda + encabezado
    // (emoji + TÍTULO en el color del nivel + subtítulo tenue) + hojas con conectores
    // de árbol monoespaciados (├─ para todas menos la última, └─ para la última).
    // Cada hoja es CLICKEABLE: al tocarla se despliega su evento (chip) + detalle + estado,
    // con chevron ▸/▾. Solo una hoja abierta a la vez (root.brainExpandedKey).
    component BrainTier: RowLayout {
        id: tier
        property int tierIndex: 0
        property string emoji: ""
        property string title: ""
        property color accent: Kirigami.Theme.textColor
        property string subtitle: ""
        property var items: []
        spacing: Kirigami.Units.smallSpacing
        Rectangle {
            Layout.preferredWidth: 3; Layout.fillHeight: true
            Layout.topMargin: 2; Layout.bottomMargin: 2
            radius: 1; color: tier.accent
        }
        ColumnLayout {
            Layout.fillWidth: true
            spacing: Kirigami.Units.smallSpacing
            RowLayout {
                Layout.fillWidth: true; spacing: Kirigami.Units.smallSpacing
                PC3.Label { text: tier.emoji; font.pointSize: Kirigami.Theme.defaultFont.pointSize * 1.1 }
                PC3.Label { text: tier.title; font.bold: true; color: tier.accent }
                Item { Layout.fillWidth: true }
            }
            PC3.Label {
                Layout.fillWidth: true; text: tier.subtitle; opacity: 0.6; wrapMode: Text.WordWrap
                font.pointSize: Kirigami.Theme.smallFont.pointSize
            }
            Repeater {
                model: tier.items
                delegate: ColumnLayout {
                    id: leaf
                    Layout.fillWidth: true
                    spacing: 2
                    readonly property string leafKey: tier.tierIndex + "-" + index
                    readonly property bool open: root.brainExpandedKey === leafKey
                    readonly property string st: root.brainStatus(modelData.name)

                    // Cabecera CLICKEABLE: el MouseArea es el item del layout; el RowLayout va anclado
                    // dentro (conector + punto de estado + emoji + nombre + desc + chevron ▸/▾).
                    MouseArea {
                        Layout.fillWidth: true
                        implicitHeight: headerRow.implicitHeight
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onClicked: root.brainExpandedKey = leaf.open ? "" : leaf.leafKey
                        RowLayout {
                            id: headerRow
                            anchors.left: parent.left; anchors.right: parent.right; anchors.top: parent.top
                            spacing: Kirigami.Units.smallSpacing
                            PC3.Label {
                                Layout.alignment: Qt.AlignTop
                                text: index === tier.items.length - 1 ? "└─" : "├─"
                                font.family: "monospace"; color: tier.accent; opacity: 0.55
                            }
                            PC3.Label {
                                Layout.alignment: Qt.AlignTop
                                text: root.brainDot(leaf.st); color: root.brainDotColor(leaf.st)
                                font.pointSize: Kirigami.Theme.smallFont.pointSize
                            }
                            PC3.Label { Layout.alignment: Qt.AlignTop; text: modelData.emoji }
                            PC3.Label {
                                Layout.alignment: Qt.AlignTop
                                text: modelData.name; font.family: "monospace"; font.bold: true
                            }
                            PC3.Label {
                                Layout.fillWidth: true; Layout.alignment: Qt.AlignTop
                                text: modelData.desc; opacity: 0.62; wrapMode: Text.WordWrap
                                font.pointSize: Kirigami.Theme.smallFont.pointSize
                            }
                            PC3.Label {
                                Layout.alignment: Qt.AlignTop
                                text: leaf.open ? "▾" : "▸"; opacity: 0.35
                                font.pointSize: Kirigami.Theme.smallFont.pointSize
                            }
                        }
                    }

                    // Detalle desplegado: chip del evento (color del nivel) + párrafo + estado leído.
                    ColumnLayout {
                        Layout.fillWidth: true
                        Layout.leftMargin: Kirigami.Units.gridUnit * 1.2
                        Layout.rightMargin: Kirigami.Units.smallSpacing
                        visible: leaf.open
                        spacing: 3
                        Rectangle {
                            Layout.alignment: Qt.AlignLeft
                            radius: 3
                            color: Qt.rgba(tier.accent.r, tier.accent.g, tier.accent.b, 0.15)
                            implicitWidth: chip.implicitWidth + Kirigami.Units.smallSpacing * 2
                            implicitHeight: chip.implicitHeight + 2
                            PC3.Label {
                                id: chip
                                anchors.centerIn: parent
                                text: modelData.event; color: tier.accent; font.bold: true
                                font.family: "monospace"; font.pointSize: Kirigami.Theme.smallFont.pointSize * 0.9
                            }
                        }
                        PC3.Label {
                            Layout.fillWidth: true; text: modelData.detail; opacity: 0.75; wrapMode: Text.WordWrap
                            font.pointSize: Kirigami.Theme.smallFont.pointSize
                        }
                        RowLayout {
                            visible: leaf.st !== ""
                            spacing: 4
                            PC3.Label { text: root.brainDot(leaf.st); color: root.brainDotColor(leaf.st); font.pointSize: Kirigami.Theme.smallFont.pointSize }
                            PC3.Label {
                                text: root.brainStatusLabel(leaf.st); color: root.brainDotColor(leaf.st)
                                font.pointSize: Kirigami.Theme.smallFont.pointSize * 0.95
                            }
                        }
                    }
                }
            }
        }
    }

    // tarjeta de estadística (Resumen)
    component StatCard: Rectangle {
        property string label: ""
        property string value: "—"
        Layout.fillWidth: true
        Layout.preferredHeight: Kirigami.Units.gridUnit * 2.8
        radius: Kirigami.Units.smallSpacing
        color: Qt.rgba(Kirigami.Theme.textColor.r, Kirigami.Theme.textColor.g, Kirigami.Theme.textColor.b, 0.06)
        ColumnLayout {
            anchors.fill: parent; anchors.margins: Kirigami.Units.smallSpacing; spacing: 0
            PC3.Label { text: label; opacity: 0.6; font.pointSize: Kirigami.Theme.smallFont.pointSize; Layout.fillWidth: true; elide: Text.ElideRight }
            PC3.Label { text: value; font.bold: true; font.pointSize: Kirigami.Theme.defaultFont.pointSize * 1.1; Layout.fillWidth: true; elide: Text.ElideRight }
        }
    }

    // sección de límite (barra redondeada + reset + costo local)
    component UsageSection: ColumnLayout {
        property string title: ""
        property var block: null
        readonly property real pct: block && block.percent !== undefined ? block.percent : -1
        spacing: Kirigami.Units.smallSpacing
        RowLayout {
            Layout.fillWidth: true
            PC3.Label { text: title; Layout.fillWidth: true; font.bold: true }
            PC3.Label { text: pct >= 0 ? pct.toFixed(1) + "%" : "—"; color: root.pctColor(pct); font.bold: true }
        }
        Rectangle {
            Layout.fillWidth: true; height: Kirigami.Units.gridUnit * 0.5; radius: height / 2
            color: Qt.rgba(Kirigami.Theme.textColor.r, Kirigami.Theme.textColor.g, Kirigami.Theme.textColor.b, 0.12)
            Rectangle {
                anchors.left: parent.left; anchors.verticalCenter: parent.verticalCenter
                height: parent.height; radius: parent.radius
                width: parent.width * Math.max(0, Math.min(1, pct / 100))
                color: root.pctColor(pct)
                Behavior on width { NumberAnimation { duration: 250 } }
            }
        }
        PC3.Label {
            Layout.fillWidth: true; opacity: 0.65; font.pointSize: Kirigami.Theme.smallFont.pointSize
            text: {
                if (!block) return ""
                // Past-aware: si el resets_at ya pasó, el % puede estar pegado en el de la ventana
                // anterior mientras llega el fetch → "Se restableció … · actualizando…". Espeja
                // resetLine() de PopoverView.swift.
                let past = root.isPast(block.resets_at)
                let s = past ? ("Se restableció " + root.relativeTime(block.resets_at) + " · actualizando…")
                             : ("Se restablece " + root.resetDetail(block.resets_at))
                if (block.cost_usd !== null && block.cost_usd !== undefined)
                    s += " · ≈ $" + block.cost_usd.toFixed(2) + " (API equiv local)"
                return s
            }
        }
    }

    // sección de GASTO REAL: dinero de tu bolsillo (spend) + overage (extra_usage).
    // Distinto del "Costo API-equiv" del Resumen, que es el equivalente incluido.
    component SpendSection: ColumnLayout {
        property var spend: null
        property var extra: null
        readonly property real pct: spend && spend.percent !== undefined && spend.percent !== null ? spend.percent : -1
        visible: spend && spend.enabled === true
        spacing: Kirigami.Units.smallSpacing
        RowLayout {
            Layout.fillWidth: true
            PC3.Label { text: "Gasto real"; Layout.fillWidth: true; font.bold: true }
            PC3.Label {
                // Headline = MONTO usado (no %); el color sigue por porcentaje.
                text: spend ? root.fmtMoney(spend.used, spend.currency) : "—"
                color: root.pctColor(pct); font.bold: true
            }
        }
        Rectangle {
            Layout.fillWidth: true; height: Kirigami.Units.gridUnit * 0.5; radius: height / 2
            color: Qt.rgba(Kirigami.Theme.textColor.r, Kirigami.Theme.textColor.g, Kirigami.Theme.textColor.b, 0.12)
            Rectangle {
                anchors.left: parent.left; anchors.verticalCenter: parent.verticalCenter
                height: parent.height; radius: parent.radius
                width: parent.width * Math.max(0, Math.min(1, pct / 100))
                color: root.pctColor(pct)
                Behavior on width { NumberAnimation { duration: 250 } }
            }
        }
        PC3.Label {
            Layout.fillWidth: true; opacity: 0.65; wrapMode: Text.WordWrap
            font.pointSize: Kirigami.Theme.smallFont.pointSize
            text: {
                if (!spend) return ""
                // Monto usado / tope (redundante con el headline a propósito).
                let s = root.fmtMoney(spend.used, spend.currency) + " / " + root.fmtMoney(spend.cap, spend.currency)
                if (spend.currency) s += " " + spend.currency
                s += " — gasto real de bolsillo (no el equivalente incluido del plan)"
                if (extra && extra.enabled === true && extra.used_credits !== null && extra.used_credits !== undefined)
                    s += "\nSobreuso: " + root.fmtInt(extra.used_credits) + " / " + root.fmtInt(extra.monthly_limit) + " créditos"
                        + (extra.utilization !== null && extra.utilization !== undefined ? " (" + extra.utilization.toFixed(1) + "%)" : "")
                return s
            }
        }
    }

    // ---------- Tooltip ----------
    toolTipMainText: {
        if (statusKey === "error") return "Claude Limits — sin datos"
        const five = fivePct >= 0 ? Math.round(fivePct) + "%" : "—"
        const wk   = weekPct >= 0 ? Math.round(weekPct) + "%" : "—"
        const warn = (snapshot && snapshot.account_mismatch === true) ? " ⚠ otra cuenta" : ""
        return "Claude: 5h " + five + " · 7d " + wk + warn
    }
    toolTipSubText: snapshot && snapshot.five_hour
                    ? (isPast(snapshot.five_hour.resets_at)
                       ? "sesión se restableció " + relativeTime(snapshot.five_hour.resets_at) + " · actualizando…"
                       : "sesión se restablece " + relativeTime(snapshot.five_hour.resets_at)) : ""

    // ---------- Helpers ----------
    // true si el instante ISO ya pasó (o es exactamente ahora). Espeja RelativeTime.isPast del macOS.
    function isPast(iso) {
        if (!iso) return false
        const t = Date.parse(iso)
        if (isNaN(t)) return false
        return t <= Date.now()
    }
    // Reset específico/útil (espeja RelativeTime.resetDetail de macOS): <24h → "en 4h36m";
    // ≥24h → "mié@7:59" (día abreviado en español + hora 12h, sin am/pm — weekday manual para no
    // depender del API de locale de QML).
    function resetDetail(iso) {
        if (!iso) return ""
        const t = Date.parse(iso); if (isNaN(t)) return ""
        const secs = (t - Date.now()) / 1000
        if (secs < 86400) {
            const total = Math.max(0, Math.round(secs))
            const h = Math.floor(total / 3600), m = Math.floor((total % 3600) / 60)
            if (h > 0) return m > 0 ? ("en " + h + "h" + m + "m") : ("en " + h + "h")
            if (total >= 60) return "en " + m + "m"
            return "en <1m"
        }
        const d = new Date(t)
        const wd = ["dom","lun","mar","mié","jue","vie","sáb"][d.getDay()]
        let hh = d.getHours() % 12; if (hh === 0) hh = 12
        const mm = ("0" + d.getMinutes()).slice(-2)
        return wd + "@" + hh + ":" + mm
    }
    // Edad del snapshot en segundos (a partir de updated_at); -1 si no hay dato válido.
    function snapshotAgeSec() {
        if (!snapshot || !snapshot.updated_at) return -1
        const t = Date.parse(snapshot.updated_at)
        if (isNaN(t)) return -1
        return (Date.now() - t) / 1000
    }
    function relativeTime(iso) {
        if (!iso) return ""
        const t = Date.parse(iso); if (isNaN(t)) return iso
        const diff = Math.round((t - Date.now()) / 1000); const abs = Math.abs(diff)
        let val, unit
        if      (abs < 60)    { val = abs;                  unit = "s" }
        else if (abs < 3600)  { val = Math.round(abs/60);   unit = "min" }
        else if (abs < 86400) { val = Math.round(abs/3600); unit = "h" }
        else                  { val = Math.round(abs/86400);unit = "d" }
        return diff < 0 ? ("hace " + val + unit) : ("en " + val + unit)
    }
    function compactReset(iso) {
        if (!iso) return ""
        const t = Date.parse(iso); if (isNaN(t)) return ""
        const diff = Math.round((t - Date.now()) / 1000); const abs = Math.abs(diff)
        if (abs < 3600)  return Math.round(abs/60) + "min"
        if (abs < 86400) return Math.round(abs/3600) + "h"
        return Math.round(abs/86400) + "d"
    }

    // rachas (días consecutivos con uso) a partir de stats.days
    function pad2(n) { return (n < 10 ? "0" : "") + n }
    function dayKey(d) { return d.getFullYear() + "-" + pad2(d.getMonth()+1) + "-" + pad2(d.getDate()) }
    readonly property var streaks: {
        if (!stats || !stats.days || !stats.days.length) return { cur: 0, max: 0 }
        var set = {}; for (var i = 0; i < stats.days.length; i++) if (stats.days[i].tokens > 0) set[stats.days[i].date] = true
        var keys = Object.keys(set).sort(); var longest = 0, run = 0, prev = null
        for (var j = 0; j < keys.length; j++) {
            var t = Date.parse(keys[j])
            if (prev !== null && (t - prev) === 86400000) run++; else run = 1
            longest = Math.max(longest, run); prev = t
        }
        var cur = 0; var d = new Date()
        if (!set[dayKey(d)]) d.setDate(d.getDate() - 1)
        while (set[dayKey(d)]) { cur++; d.setDate(d.getDate() - 1) }
        return { cur: cur, max: longest }
    }
    readonly property int currentStreak: streaks.cur
    readonly property int longestStreak: streaks.max

    // celdas del heatmap (rango continuo desde el primer día, alineado por semana)
    function heatmapCells() {
        if (!stats || !stats.days || !stats.days.length) return []
        var m = {}, minT = null, maxT = null
        for (var i = 0; i < stats.days.length; i++) {
            var dd = stats.days[i]; m[dd.date] = dd.tokens
            var t = Date.parse(dd.date)
            if (minT === null || t < minT) minT = t
            if (maxT === null || t > maxT) maxT = t
        }
        if (minT === null) return []
        var start = new Date(minT); start.setDate(start.getDate() - start.getDay())
        var end = new Date(maxT)
        var cells = [], cur = new Date(start)
        while (cur <= end) { cells.push({ tokens: (m[dayKey(cur)] || 0) }); cur.setDate(cur.getDate() + 1) }
        return cells
    }
}
