import QtCore
import QtQuick
import QtQuick.Layouts
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

    property int currentTab: 0

    readonly property string cacheDir: {
        const raw = "" + StandardPaths.writableLocation(StandardPaths.GenericCacheLocation)
        const stripped = raw.startsWith("file://") ? raw.substring("file://".length) : raw
        return stripped + "/claude-quota"
    }

    P5Support.DataSource {
        id: catSource
        engine: "executable"
        connectedSources: []
        onNewData: function(source, data) {
            if (source.indexOf("stats.json") !== -1) {
                if (data["exit code"] === 0 && data.stdout) {
                    try { root.stats = JSON.parse(data.stdout) } catch (e) {}
                }
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

    function reload() {
        catSource.connectSource("cat " + cacheDir + "/state.json")
        catSource.connectSource("cat " + cacheDir + "/stats.json")
    }
    function forceRefresh() {
        refreshRunner.connectSource("systemctl --user start claude-quota.service")
    }

    Timer {
        interval: 10000
        repeat: true
        running: true
        triggeredOnStart: true
        onTriggered: reload()
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

    // Paleta para modelos (distinta por modelo, cohesiva con el acento).
    readonly property var modelPalette: ["#e8884a", "#5b9bd5", "#9b6dd6", "#5fb98e", "#d6a15b", "#c96daa"]
    function modelColorFor(name) {
        if (!stats || !stats.models) return modelPalette[0]
        for (var i = 0; i < stats.models.length; i++)
            if (stats.models[i].model === name) return modelPalette[i % modelPalette.length]
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

        // riel vertical de pestañas
        ColumnLayout {
            Layout.fillHeight: true
            Layout.preferredWidth: Kirigami.Units.gridUnit * 6
            Layout.margins: Kirigami.Units.smallSpacing
            spacing: Kirigami.Units.smallSpacing
            TabRailButton { idx: 0; icon: "speedometer";        label: "Límites" }
            TabRailButton { idx: 1; icon: "view-statistics";    label: "Resumen" }
            TabRailButton { idx: 2; icon: "office-chart-bar";   label: "Modelos" }
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
                Item { Layout.fillHeight: true }
                PC3.Label {
                    Layout.fillWidth: true; opacity: 0.5; font.pointSize: Kirigami.Theme.smallFont.pointSize
                    text: {
                        if (root.snapshotError) return "error: " + root.snapshotError
                        if (!root.snapshot) return "cargando…"
                        const basis = root.snapshot.basis === "oauth" ? "datos reales" : "estimado local"
                        return basis + " · ⟳ 5 min · act. " + root.relativeTime(root.snapshot.updated_at)
                    }
                }
            }

            // ===== Tab 1: Resumen =====
            ColumnLayout {
                spacing: Kirigami.Units.largeSpacing
                Kirigami.Heading { level: 3; text: "Resumen"; Layout.fillWidth: true }
                GridLayout {
                    Layout.fillWidth: true; columns: 3; rowSpacing: Kirigami.Units.smallSpacing; columnSpacing: Kirigami.Units.smallSpacing
                    StatCard { label: "Sesiones";        value: root.stats ? root.fmtInt(root.stats.summary.sessions) : "—" }
                    StatCard { label: "Mensajes";        value: root.stats ? root.fmtInt(root.stats.summary.messages) : "—" }
                    StatCard { label: "Tokens totales";  value: root.stats ? root.fmtTok(root.stats.summary.total_tokens) : "—" }
                    StatCard { label: "Días activos";    value: root.stats ? "" + root.stats.summary.active_days : "—" }
                    StatCard { label: "Racha actual";    value: root.currentStreak + "d" }
                    StatCard { label: "Racha más larga"; value: root.longestStreak + "d" }
                    StatCard { label: "Hora pico";       value: root.stats ? root.fmtHour(root.stats.summary.peak_hour) : "—" }
                    StatCard { label: "Modelo favorito"; value: root.stats ? root.prettyModel(root.stats.summary.favorite_model) : "—" }
                    StatCard { label: "Costo API-equiv"; value: root.stats ? "$" + root.stats.summary.total_cost.toFixed(0) : "—" }
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
                            model: root.stats ? root.stats.days : []
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
                                            Layout.preferredHeight: chartArea.height * (modelData.tokens / root.maxDayTokens)
                                            color: root.modelColorFor(modelData.model)
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
                // tabla de modelos
                ColumnLayout {
                    Layout.fillWidth: true; spacing: Kirigami.Units.smallSpacing
                    Repeater {
                        model: root.stats ? root.stats.models : []
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
                Item { Layout.fillHeight: true }
            }
        }
    }

    // botón del riel de pestañas
    component TabRailButton: Rectangle {
        property int idx: 0
        property string icon: ""
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
                source: icon
                Layout.preferredWidth: Kirigami.Units.iconSizes.small; Layout.preferredHeight: Kirigami.Units.iconSizes.small
                color: active ? "#e8884a" : Kirigami.Theme.textColor
                isMask: true
            }
            PC3.Label { text: label; font.bold: active; color: active ? "#e8884a" : Kirigami.Theme.textColor }
            Item { Layout.fillWidth: true }
        }
        MouseArea { id: mouse; anchors.fill: parent; hoverEnabled: true; onClicked: root.currentTab = idx }
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
                let s = "Se restablece " + root.relativeTime(block.resets_at)
                if (block.cost_usd !== null && block.cost_usd !== undefined)
                    s += " · ≈ $" + block.cost_usd.toFixed(2) + " (API equiv local)"
                return s
            }
        }
    }

    // ---------- Tooltip ----------
    toolTipMainText: {
        if (statusKey === "error") return "Claude Limits — sin datos"
        const five = fivePct >= 0 ? Math.round(fivePct) + "%" : "—"
        const wk   = weekPct >= 0 ? Math.round(weekPct) + "%" : "—"
        return "Claude: 5h " + five + " · 7d " + wk
    }
    toolTipSubText: snapshot && snapshot.five_hour
                    ? "sesión se restablece " + relativeTime(snapshot.five_hour.resets_at) : ""

    // ---------- Helpers ----------
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
