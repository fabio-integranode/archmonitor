import QtQuick
import QtQuick.Layouts
import "Logic.js" as L

// Detail section that Card.qml opens under its header: every active alert, the processes
// behind the numbers, and the kernel. Content only: no background or outer padding, so it
// reads as part of the card. Pure view: stopping a process is only requested here
// (killRequested); main.qml sends it and the probe re-validates it.
//
// Stopping is two clicks on the same row: the first arms it (red, "STOP?"), the second
// confirms. Anything else, 4 s passing, or closing the drawer disarms it.
ColumnLayout {
    id: detail

    property var s: ({})
    property var sec: ({})
    property var alertList: []
    property var procs: null        // { cpu: [{n, v, c, p, k}], mem: [...] } from `archi-stat.sh top`, or null while sampling
    property var termLog: ({})      // command name -> ms when SIGTERM was sent
    property real now: 0            // ms, ticks once a second (main.qml)
    property string armed: ""       // "<list>:<name>" of the row awaiting confirmation

    signal killRequested(string name, var pids, string sig)

    onVisibleChanged: if (!visible) armed = ""
    Timer { id: disarm; interval: 4000; onTriggered: detail.armed = "" }
    readonly property string sans: "Inter"
    readonly property string mono: "JetBrains Mono"

    spacing: 0

    function tone(kind) {
        return kind === "crit" ? L.C.crit : kind === "warn" ? L.C.warn
             : kind === "unknown" || kind === "stale" ? L.C.sub : L.C.ok;
    }

    component Label: Text {
        font.family: detail.sans
        font.pixelSize: 9
        font.weight: Font.DemiBold
        font.letterSpacing: 1.5
        color: L.C.sub
        renderType: Text.NativeRendering
    }
    component Hint: Text {
        font.family: detail.sans
        font.pixelSize: 9
        color: L.C.faint
        renderType: Text.NativeRendering
    }
    component Hair: Rectangle {
        Layout.fillWidth: true
        implicitHeight: 1
        color: Qt.rgba(1, 1, 1, 0.07)
    }
    component Gap: Item { property int h: 12; implicitHeight: h; Layout.fillWidth: true }

    // One consumer: name, process count, value. Clickable when the probe marked the
    // group as stoppable (own processes, not on the protected list).
    component Row3: Item {
        id: r3
        property string name
        property int count: 1
        property string value
        property bool placeholder: false
        property bool killable: false
        property var pids: []
        property string listKey: ""
        readonly property string key: listKey + ":" + name
        readonly property bool armed: !placeholder && detail.armed === key
        readonly property bool pending: !placeholder && L.killPending(name, detail.termLog, detail.now)
        readonly property string sig: L.killSignal(name, detail.termLog, detail.now)
        readonly property bool clickable: killable && !pending && !placeholder
        readonly property color tint: placeholder || pending ? L.C.faint : armed ? L.C.crit : L.C.fg

        Layout.fillWidth: true
        implicitHeight: line.implicitHeight + 6

        Rectangle {
            anchors { fill: parent; leftMargin: -8; rightMargin: -8 }
            radius: 4
            color: r3.armed ? Qt.rgba(0.894, 0.408, 0.373, 0.14)
                 : r3.clickable && ma.containsMouse ? Qt.rgba(1, 1, 1, 0.05) : "transparent"
            Behavior on color { ColorAnimation { duration: 120 } }
        }
        RowLayout {
            id: line
            anchors { left: parent.left; right: parent.right; verticalCenter: parent.verticalCenter }
            spacing: 6
            Text {
                text: r3.name
                font.family: detail.sans
                font.pixelSize: 11
                color: r3.tint
                elide: Text.ElideRight
                renderType: Text.NativeRendering
                Layout.fillWidth: true
            }
            Text {
                visible: r3.count > 1
                text: "×" + r3.count
                font.family: detail.mono
                font.pixelSize: 9
                color: r3.armed ? L.C.crit : L.C.faint
                renderType: Text.NativeRendering
            }
            Text {
                text: r3.armed ? (r3.sig === "KILL" ? "KILL -9?" : "STOP?")
                    : r3.pending ? "stopping…" : r3.value
                font.family: detail.mono
                font.pixelSize: 11
                font.weight: r3.armed ? Font.DemiBold : Font.Normal
                color: r3.tint
                horizontalAlignment: Text.AlignRight
                renderType: Text.NativeRendering
                Layout.preferredWidth: 72
            }
        }
        // Rows always take their own clicks, so a click on a non-stoppable process does
        // not collapse the drawer by accident.
        MouseArea {
            id: ma
            anchors.fill: parent
            hoverEnabled: true
            cursorShape: r3.clickable ? Qt.PointingHandCursor : Qt.ArrowCursor
            onClicked: {
                if (!r3.clickable) { detail.armed = ""; return }
                if (r3.armed) {
                    detail.armed = ""
                    disarm.stop()
                    detail.killRequested(r3.name, r3.pids, r3.sig)
                } else {
                    detail.armed = r3.key
                    disarm.restart()
                }
            }
        }
    }

    // Three rows of consumers, or three placeholder rows while the first sample runs,
    // so the section does not jump in height when the data lands.
    component Consumers: ColumnLayout {
        id: cons
        property var rows: null          // null while sampling
        property string listKey: ""
        property var fmt: function (v) { return String(v) }
        Layout.fillWidth: true
        spacing: 0
        Repeater {
            model: cons.rows ? cons.rows : [{}, {}, {}]
            Row3 {
                required property var modelData
                placeholder: modelData.n === undefined
                name: modelData.n !== undefined ? modelData.n : "·"
                count: modelData.c !== undefined ? modelData.c : 1
                value: modelData.v !== undefined ? cons.fmt(modelData.v) : "—"
                killable: modelData.k === true
                pids: modelData.p || []
                listKey: cons.listKey
            }
        }
    }

    // Alerts
    Label { text: "ALERTS" }
    Gap { h: 10 }
    Text {
        visible: detail.alertList.length === 0
        text: "None active"
        font.family: detail.sans
        font.pixelSize: 11
        color: L.C.ok
        renderType: Text.NativeRendering
    }
    Repeater {
        model: detail.alertList
        RowLayout {
            required property var modelData
            required property int index
            Layout.fillWidth: true
            Layout.topMargin: index > 0 ? 6 : 0
            spacing: 8
            Rectangle {
                width: 6; height: 6; radius: 3
                color: detail.tone(parent.modelData.kind)
            }
            Text {
                text: parent.modelData.text
                font.family: detail.mono
                font.pixelSize: 11
                color: detail.tone(parent.modelData.kind)
                renderType: Text.NativeRendering
                Layout.fillWidth: true
            }
        }
    }

    Gap { h: 16 }
    Hair {}
    Gap { h: 14 }

    // CPU consumers
    RowLayout {
        Layout.fillWidth: true
        Label { text: "TOP CPU"; Layout.fillWidth: true }
        Hint { text: detail.procs ? "% of one core" : "sampling…" }
    }
    Gap { h: 7 }
    Consumers {
        listKey: "cpu"
        rows: detail.procs ? detail.procs.cpu : null
        fmt: function (v) { return (v / 10).toFixed(v >= 1000 ? 0 : 1) + "%" }
    }

    Gap { h: 16 }
    Hair {}
    Gap { h: 14 }

    // Memory consumers
    RowLayout {
        Layout.fillWidth: true
        Label { text: "TOP MEMORY"; Layout.fillWidth: true }
        Hint { text: detail.procs ? "RSS, summed" : "sampling…" }
    }
    Gap { h: 7 }
    Consumers {
        listKey: "mem"
        rows: detail.procs ? detail.procs.mem : null
        fmt: function (v) { return L.bytes(v) }
    }

    Gap { h: 16 }
    Hair {}
    Gap { h: 12 }

    // System
    RowLayout {
        Layout.fillWidth: true
        spacing: 6
        Label { text: "KERNEL"; font.pixelSize: 8 }
        Text {
            text: detail.sec && detail.sec.kernel ? detail.sec.kernel : "—"
            font.family: detail.mono
            font.pixelSize: 9
            color: L.C.faint
            renderType: Text.NativeRendering
            elide: Text.ElideRight
            Layout.fillWidth: true
        }
        Text {
            visible: !!detail.sec && detail.sec.reboot === true
            text: "reboot pending"
            font.family: detail.sans
            font.pixelSize: 9
            font.weight: Font.DemiBold
            color: L.C.warn
            renderType: Text.NativeRendering
        }
    }
}
