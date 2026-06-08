import QtCore
import QtQuick
import QtQuick.Layouts
import org.kde.plasma.plasmoid
import org.kde.kirigami as Kirigami
import org.kde.plasma.components as PC3

PlasmoidItem {
    id: root

    // --- Data ---
    property var snapshot: null
    property string snapshotError: ""

    readonly property string stateFilePath:
        StandardPaths.writableLocation(StandardPaths.GenericCacheLocation) +
        "/claude-quota/state.json"
    readonly property string stateFileUrl: {
        // GenericCacheLocation can be a path or a file:// URL depending on Qt version; normalize.
        const p = stateFilePath
        return p.startsWith("file://") ? p : "file://" + p
    }

    function loadSnapshot() {
        const xhr = new XMLHttpRequest();
        xhr.open("GET", stateFileUrl);
        xhr.onreadystatechange = function() {
            if (xhr.readyState !== XMLHttpRequest.DONE) return;
            // file:// URLs return status 0 on success in QML's XHR
            if (xhr.status === 0 || xhr.status === 200) {
                try {
                    root.snapshot = JSON.parse(xhr.responseText);
                    root.snapshotError = "";
                } catch (e) {
                    root.snapshotError = "parse: " + e;
                }
            } else {
                root.snapshotError = "http " + xhr.status;
            }
        };
        xhr.send();
    }

    // --- Status derivation ---
    readonly property string statusKey: {
        if (snapshotError !== "" || snapshot === null) return "error"
        if (snapshot.status) return snapshot.status
        return "error"
    }
    readonly property var statusVisuals: ({
        "ok":    { icon: "emblem-success",  label: "OK" },
        "warn":  { icon: "emblem-warning",  label: "Warning" },
        "crit":  { icon: "emblem-error",    label: "Critical" },
        "error": { icon: "dialog-question", label: "No data" }
    })

    // --- Refresh loop: re-read cache file every 10s. The systemd timer
    //     refreshes the cache itself every 5min — this just picks up changes.
    Timer {
        interval: 10000
        repeat: true
        running: true
        triggeredOnStart: true
        onTriggered: loadSnapshot()
    }

    // --- Compact (panel/tray) representation ---
    compactRepresentation: Item {
        Kirigami.Icon {
            anchors.fill: parent
            source: statusVisuals[statusKey].icon
            active: hoverHandler.hovered
        }
        HoverHandler { id: hoverHandler }
        TapHandler { onTapped: root.expanded = !root.expanded }
    }

    preferredRepresentation: compactRepresentation
    fullRepresentation: null

    // --- Tooltip header (always available) ---
    toolTipMainText: {
        if (statusKey === "error") return "Claude Code quota — no data"
        const five = snapshot && snapshot.five_hour
                     ? snapshot.five_hour.percent.toFixed(0) + "%" : "—"
        const wk   = snapshot && snapshot.weekly
                     ? snapshot.weekly.percent.toFixed(0)    + "%" : "—"
        return "Claude Code: 5h " + five + " · wk " + wk
    }

    // --- Rich hover tooltip body ---
    toolTipItem: ColumnLayout {
        width: Kirigami.Units.gridUnit * 16
        spacing: Kirigami.Units.smallSpacing

        Kirigami.Heading {
            level: 4
            text: "Claude Code quota"
            Layout.fillWidth: true
        }

        Item { Layout.preferredHeight: Kirigami.Units.smallSpacing }

        ColumnLayout {
            Layout.fillWidth: true
            spacing: 2
            RowLayout {
                Layout.fillWidth: true
                PC3.Label {
                    text: "5-hour block"
                    Layout.fillWidth: true
                    font.bold: true
                }
                PC3.Label {
                    text: root.snapshot && root.snapshot.five_hour
                          ? root.snapshot.five_hour.percent.toFixed(1) + "%"
                          : "—"
                }
            }
            PC3.ProgressBar {
                Layout.fillWidth: true
                from: 0
                to: 100
                value: root.snapshot && root.snapshot.five_hour
                       ? root.snapshot.five_hour.percent : 0
            }
            PC3.Label {
                Layout.fillWidth: true
                font.pointSize: Kirigami.Theme.smallFont.pointSize
                opacity: 0.7
                text: {
                    if (!root.snapshot || !root.snapshot.five_hour) return ""
                    const f = root.snapshot.five_hour
                    return "resets " + relativeTime(f.resets_at) +
                           " · $" + f.cost_usd.toFixed(2)
                }
            }
        }

        Item { Layout.preferredHeight: Kirigami.Units.smallSpacing }

        ColumnLayout {
            Layout.fillWidth: true
            spacing: 2
            RowLayout {
                Layout.fillWidth: true
                PC3.Label {
                    text: "Weekly"
                    Layout.fillWidth: true
                    font.bold: true
                }
                PC3.Label {
                    text: root.snapshot && root.snapshot.weekly
                          ? root.snapshot.weekly.percent.toFixed(1) + "%"
                          : "—"
                }
            }
            PC3.ProgressBar {
                Layout.fillWidth: true
                from: 0
                to: 100
                value: root.snapshot && root.snapshot.weekly
                       ? root.snapshot.weekly.percent : 0
            }
            PC3.Label {
                Layout.fillWidth: true
                font.pointSize: Kirigami.Theme.smallFont.pointSize
                opacity: 0.7
                text: {
                    if (!root.snapshot || !root.snapshot.weekly) return ""
                    const w = root.snapshot.weekly
                    return "resets " + relativeTime(w.resets_at) +
                           " · $" + w.cost_usd.toFixed(2)
                }
            }
        }

        Item { Layout.preferredHeight: Kirigami.Units.smallSpacing }

        PC3.Label {
            Layout.fillWidth: true
            font.pointSize: Kirigami.Theme.smallFont.pointSize
            opacity: 0.5
            text: {
                if (root.snapshotError) return "error: " + root.snapshotError
                if (!root.snapshot) return "loading…"
                return "updated " + relativeTime(root.snapshot.updated_at)
            }
        }
    }

    function relativeTime(iso) {
        if (!iso) return ""
        const t = Date.parse(iso)
        if (isNaN(t)) return iso
        const diff = Math.round((t - Date.now()) / 1000)
        const abs = Math.abs(diff)
        let val, unit
        if      (abs < 60)    { val = abs;                  unit = "s" }
        else if (abs < 3600)  { val = Math.round(abs/60);   unit = "m" }
        else if (abs < 86400) { val = Math.round(abs/3600); unit = "h" }
        else                  { val = Math.round(abs/86400);unit = "d" }
        return diff < 0 ? (val + unit + " ago") : ("in " + val + unit)
    }
}
