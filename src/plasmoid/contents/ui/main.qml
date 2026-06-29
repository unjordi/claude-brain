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

    // ---------- Data ----------
    property var snapshot: null
    property string snapshotError: ""

    readonly property string stateFilePath: {
        const raw = "" + StandardPaths.writableLocation(StandardPaths.GenericCacheLocation)
        const stripped = raw.startsWith("file://") ? raw.substring("file://".length) : raw
        return stripped + "/claude-quota/state.json"
    }

    P5Support.DataSource {
        id: catSource
        engine: "executable"
        connectedSources: []
        onNewData: function(source, data) {
            if (data["exit code"] === 0 && data.stdout) {
                try {
                    root.snapshot = JSON.parse(data.stdout)
                    root.snapshotError = ""
                } catch (e) {
                    root.snapshotError = "parse: " + e
                }
            } else {
                root.snapshotError = "cat rc=" + data["exit code"] +
                    (data.stderr ? " " + data.stderr : "")
            }
            disconnectSource(source)
        }
    }

    // Fires the systemd fetch service on demand (refresh button), then re-reads.
    P5Support.DataSource {
        id: refreshRunner
        engine: "executable"
        connectedSources: []
        onNewData: function(source, data) {
            disconnectSource(source)
            loadSnapshot()
        }
    }

    function loadSnapshot() {
        catSource.connectSource("cat " + stateFilePath)
    }
    function forceRefresh() {
        refreshRunner.connectSource("systemctl --user start claude-quota.service")
    }

    Timer {
        interval: 10000
        repeat: true
        running: true
        triggeredOnStart: true
        onTriggered: loadSnapshot()
    }

    // ---------- Status / color derivation ----------
    readonly property string statusKey: {
        if (snapshotError !== "" || snapshot === null) return "error"
        if (snapshot.status) return snapshot.status
        return "error"
    }

    // FelixDes-style single orange accent; escalates to red only at the wall (>90%).
    function pctColor(p) {
        if (p === undefined || p === null) return "#777777"
        if (p > 90) return "#dc3545"   // red — about to get throttled
        return "#e8884a"               // orange accent
    }

    readonly property real fivePct: snapshot && snapshot.five_hour ? snapshot.five_hour.percent : -1
    readonly property real weekPct: snapshot && snapshot.weekly    ? snapshot.weekly.percent    : -1

    Plasmoid.status: PlasmaCore.Types.ActiveStatus
    Plasmoid.icon: "applications-development"

    // ---------- Compact representation (panel) — two rows w/ mini bars, FelixDes-style ----------
    compactRepresentation: MouseArea {
        id: compactRoot
        hoverEnabled: true
        onClicked: root.expanded = !root.expanded
        implicitWidth: col.implicitWidth + Kirigami.Units.largeSpacing * 2
        implicitHeight: Kirigami.Units.iconSizes.medium

        // The system tray / panel reserves space from these Layout hints, not
        // implicitWidth alone — without them a wide compact rep overlaps neighbors.
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
                label: "5h"
                pct: root.fivePct
                resetIso: root.snapshot && root.snapshot.five_hour ? root.snapshot.five_hour.resets_at : ""
                fontPx: compactRoot.fs
            }
            CompactRow {
                label: "7d"
                pct: root.weekPct
                resetIso: root.snapshot && root.snapshot.weekly ? root.snapshot.weekly.resets_at : ""
                fontPx: compactRoot.fs
            }
        }
    }

    // One row of the panel indicator: label · mini bar · % · reset (FelixDes-style).
    component CompactRow: RowLayout {
        property string label: ""
        property real pct: -1
        property string resetIso: ""
        property real fontPx: 11
        spacing: Kirigami.Units.smallSpacing

        PC3.Label { text: label; opacity: 0.7; font.pixelSize: fontPx }

        // mini rounded bar
        Rectangle {
            Layout.minimumWidth: fontPx * 3
            Layout.preferredWidth: fontPx * 4
            Layout.alignment: Qt.AlignVCenter
            height: Math.max(3, fontPx * 0.42)
            radius: height / 2
            visible: pct >= 0
            color: Qt.rgba(Kirigami.Theme.textColor.r, Kirigami.Theme.textColor.g, Kirigami.Theme.textColor.b, 0.15)
            Rectangle {
                anchors.left: parent.left
                anchors.verticalCenter: parent.verticalCenter
                height: parent.height
                radius: parent.radius
                width: parent.width * Math.max(0, Math.min(1, pct / 100))
                color: root.pctColor(pct)
            }
        }

        PC3.Label {
            text: pct >= 0 ? Math.round(pct) + "%" : (root.snapshotError ? "!" : "…")
            color: root.pctColor(pct)
            font.bold: true
            font.pixelSize: fontPx
            Layout.minimumWidth: fontPx * 2.4
            horizontalAlignment: Text.AlignRight
        }

        PC3.Label {
            visible: resetIso !== ""
            text: resetIso !== "" ? "⟳" + root.compactReset(resetIso) : ""
            opacity: 0.55
            font.pixelSize: fontPx * 0.9
        }
    }

    // ---------- Full representation (popup card) ----------
    fullRepresentation: ColumnLayout {
        Layout.preferredWidth: Kirigami.Units.gridUnit * 19
        Layout.preferredHeight: Kirigami.Units.gridUnit * 13
        spacing: Kirigami.Units.largeSpacing

        // Header: title + refresh
        RowLayout {
            Layout.fillWidth: true
            Layout.leftMargin: Kirigami.Units.largeSpacing
            Layout.rightMargin: Kirigami.Units.largeSpacing
            Layout.topMargin: Kirigami.Units.largeSpacing
            Kirigami.Heading {
                level: 3
                text: "Claude Limits"
                Layout.fillWidth: true
            }
            PC3.ToolButton {
                icon.name: "view-refresh"
                flat: true
                onClicked: root.forceRefresh()
                PC3.ToolTip.text: "Actualizar ahora"
                PC3.ToolTip.visible: hovered
                PC3.ToolTip.delay: 500
            }
        }

        // 5-hour section
        UsageSection {
            Layout.fillWidth: true
            Layout.leftMargin: Kirigami.Units.largeSpacing
            Layout.rightMargin: Kirigami.Units.largeSpacing
            title: "Sesión (5 h)"
            block: root.snapshot ? root.snapshot.five_hour : null
        }

        // weekly section
        UsageSection {
            Layout.fillWidth: true
            Layout.leftMargin: Kirigami.Units.largeSpacing
            Layout.rightMargin: Kirigami.Units.largeSpacing
            title: "Semanal (7 d)"
            block: root.snapshot ? root.snapshot.weekly : null
        }

        Item { Layout.fillHeight: true }

        // footer
        PC3.Label {
            Layout.fillWidth: true
            Layout.leftMargin: Kirigami.Units.largeSpacing
            Layout.rightMargin: Kirigami.Units.largeSpacing
            Layout.bottomMargin: Kirigami.Units.largeSpacing
            horizontalAlignment: Text.AlignHCenter
            opacity: 0.5
            font.pointSize: Kirigami.Theme.smallFont.pointSize
            text: {
                if (root.snapshotError) return "error: " + root.snapshotError
                if (!root.snapshot) return "cargando…"
                const basis = root.snapshot.basis === "oauth" ? "datos reales" : "estimado local"
                return basis + " · ⟳ 5 min · act. " + root.relativeTime(root.snapshot.updated_at)
            }
        }
    }

    // A titled usage row: label + %, rounded bar, reset + API-equiv cost.
    component UsageSection: ColumnLayout {
        property string title: ""
        property var block: null
        readonly property real pct: block && block.percent !== undefined ? block.percent : -1
        spacing: Kirigami.Units.smallSpacing

        RowLayout {
            Layout.fillWidth: true
            PC3.Label { text: title; Layout.fillWidth: true; font.bold: true }
            PC3.Label {
                text: pct >= 0 ? pct.toFixed(1) + "%" : "—"
                color: root.pctColor(pct)
                font.bold: true
            }
        }
        // rounded progress bar
        Rectangle {
            Layout.fillWidth: true
            height: Kirigami.Units.gridUnit * 0.5
            radius: height / 2
            color: Qt.rgba(Kirigami.Theme.textColor.r, Kirigami.Theme.textColor.g, Kirigami.Theme.textColor.b, 0.12)
            Rectangle {
                anchors.left: parent.left
                anchors.verticalCenter: parent.verticalCenter
                height: parent.height
                radius: parent.radius
                width: parent.width * Math.max(0, Math.min(1, pct / 100))
                color: root.pctColor(pct)
                Behavior on width { NumberAnimation { duration: 250 } }
            }
        }
        PC3.Label {
            Layout.fillWidth: true
            opacity: 0.65
            font.pointSize: Kirigami.Theme.smallFont.pointSize
            text: {
                if (!block) return ""
                let s = "Se restablece " + root.relativeTime(block.resets_at)
                if (block.cost_usd !== null && block.cost_usd !== undefined)
                    s += " · ≈ $" + block.cost_usd.toFixed(2) + " (API equiv local)"
                return s
            }
        }
    }

    // ---------- Hover tooltip ----------
    toolTipMainText: {
        if (statusKey === "error") return "Claude Limits — sin datos"
        const five = fivePct >= 0 ? Math.round(fivePct) + "%" : "—"
        const wk   = weekPct >= 0 ? Math.round(weekPct) + "%" : "—"
        return "Claude: 5h " + five + " · 7d " + wk
    }
    toolTipSubText: snapshot && snapshot.five_hour
                    ? "sesión se restablece " + relativeTime(snapshot.five_hour.resets_at)
                    : ""

    function relativeTime(iso) {
        if (!iso) return ""
        const t = Date.parse(iso)
        if (isNaN(t)) return iso
        const diff = Math.round((t - Date.now()) / 1000)
        const abs = Math.abs(diff)
        let val, unit
        if      (abs < 60)    { val = abs;                  unit = "s" }
        else if (abs < 3600)  { val = Math.round(abs/60);   unit = "min" }
        else if (abs < 86400) { val = Math.round(abs/3600); unit = "h" }
        else                  { val = Math.round(abs/86400);unit = "d" }
        return diff < 0 ? ("hace " + val + unit) : ("en " + val + unit)
    }

    // Short reset for the compact pill: "3h", "2d", "12min".
    function compactReset(iso) {
        if (!iso) return ""
        const t = Date.parse(iso)
        if (isNaN(t)) return ""
        const diff = Math.round((t - Date.now()) / 1000)
        const abs = Math.abs(diff)
        if (abs < 3600)  return Math.round(abs/60) + "min"
        if (abs < 86400) return Math.round(abs/3600) + "h"
        return Math.round(abs/86400) + "d"
    }
}
