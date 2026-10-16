import QtQuick
import QtQuick.Layouts
import org.kde.plasma.plasmoid
import org.kde.plasma.core as PlasmaCore
import org.kde.plasma.plasma5support as P5Support
import "Logic.js" as L

// Plasma wrapper: owns sampling, rate derivation and alert state.
// The card is the full representation; clicking it opens a detail drawer inside the card
// itself (no Plasma popup). Card.qml and Detail.qml are pure views.
PlasmoidItem {
    id: root

    readonly property int fastMs: 2000
    readonly property int slowMs: 30000
    readonly property int topMs: 3000
    readonly property string probe: "bash '"
        + Qt.resolvedUrl("../code/archi-stat.sh").toString().replace(/^file:\/\//, "") + "'"

    property var snap: ({})
    property var sec: ({})
    property var procs: null
    property var prev: null
    property real cpu: -1
    property real rx: -1
    property real tx: -1

    // Alert state is mutated by L.evaluate(); only its results are bound to the views.
    property var engine: L.freshState()
    property var levels: ({})
    property var alertList: []

    // Freshness watchdog. Detecting that data stopped arriving needs a clock: one 1 s
    // Timer advances `now`, and everything else is a binding on the receive times.
    readonly property real startedAt: Date.now()
    property real now: Date.now()
    property real lastFast: 0           // ms, when the last valid fast snapshot was parsed
    property real lastSec: 0            // ms, when the last valid security snapshot was parsed
    readonly property real fastAge: now - (lastFast || startedAt)
    readonly property real secAge: lastSec ? now - lastSec : Infinity
    readonly property bool stale: fastAge > L.FAST_STALE_MS
    readonly property var shownAlerts: L.present(alertList, fastAge)

    Timer {
        interval: 1000
        running: true
        repeat: true
        onTriggered: root.now = Date.now()
    }

    // Detail drawer inside the card. The top-consumers probe costs ~1 s of light work,
    // so it runs only while the drawer is open.
    property bool detailOpen: false
    onDetailOpenChanged: if (detailOpen) procs = null

    // Stopping processes. The command is built and checked by L.killCommand; the probe
    // re-validates every PID (name, owner, protected list) before signalling it.
    property var termLog: ({})
    function requestKill(name, pids, sig) {
        const cmd = L.killCommand(root.probe, sig, name, pids)
        if (!cmd) return
        if (sig === "TERM") {
            const t = Object.assign({}, termLog)
            t[name] = Date.now()
            termLog = t
        }
        oneshot.connectSource(cmd)
    }

    // Media bar: what a browser is playing (MPRIS via playerctl), polled every 2 s.
    property var media: null
    property real mediaAt: 0
    function mediaAction(action) {
        if (!media || !media.player) return
        const cmd = L.mediaCommand(root.probe, action, media.player)
        if (!cmd) return
        if (action === "play-pause") {
            // Flip at once instead of waiting up to 2 s for the next poll; freeze the
            // position where it is when pausing.
            const m = Object.assign({}, media), t = Date.now()
            if (m.status === "Playing" && m.pos_us !== null && m.pos_us !== undefined)
                m.pos_us += (t - mediaAt) * 1000
            m.status = m.status === "Playing" ? "Paused" : "Playing"
            media = m
            mediaAt = t
        }
        oneshot.connectSource(cmd)
    }

    P5Support.DataSource {
        engine: "executable"
        interval: 2000
        connectedSources: [root.probe + " media"]
        onNewData: (source, data) => {
            try {
                root.media = L.keepArt(root.media, JSON.parse(data["stdout"]))
                root.mediaAt = Date.now()
            } catch (e) {}
        }
    }

    // Fire-and-forget commands (stop a process, media buttons).
    P5Support.DataSource {
        id: oneshot
        engine: "executable"
        onNewData: (source, data) => disconnectSource(source)
    }

    Plasmoid.backgroundHints: PlasmaCore.Types.NoBackground
    preferredRepresentation: fullRepresentation

    function ingest(out) {
        let d
        try { d = JSON.parse(out) } catch (e) { return }
        const p = prev
        if (p) {
            const dt = (d.ts - p.ts) / 1e6
            const dTotal = d.cpu_total - p.cpu_total
            if (dTotal > 0)
                cpu = Math.max(0, Math.min(100, 100 * (1 - (d.cpu_idle - p.cpu_idle) / dTotal)))
            if (dt > 0 && d.iface === p.iface && d.rx !== null && p.rx !== null) {
                rx = Math.max(0, (d.rx - p.rx) / dt)
                tx = Math.max(0, (d.tx - p.tx) / dt)
            } else {
                rx = -1; tx = -1
            }
        }
        prev = d
        snap = d
        lastFast = now = Date.now()
        const r = L.evaluate(engine, d, sec, lastSec ? now - lastSec : Infinity)
        levels = r.levels
        alertList = r.list
    }

    P5Support.DataSource {
        engine: "executable"
        interval: root.fastMs
        connectedSources: [root.probe]
        onNewData: (source, data) => root.ingest(data["stdout"])
    }

    P5Support.DataSource {
        engine: "executable"
        interval: root.slowMs
        connectedSources: [root.probe + " sec"]
        onNewData: (source, data) => {
            try {
                root.sec = JSON.parse(data["stdout"])
                root.lastSec = Date.now()
            } catch (e) {}
        }
    }

    P5Support.DataSource {
        engine: "executable"
        interval: root.topMs
        connectedSources: root.detailOpen ? [root.probe + " top"] : []
        onNewData: (source, data) => {
            try { root.procs = JSON.parse(data["stdout"]) } catch (e) {}
        }
    }

    fullRepresentation: Card {
        Layout.minimumWidth: implicitWidth
        Layout.minimumHeight: implicitHeight
        Layout.preferredWidth: implicitWidth
        Layout.preferredHeight: implicitHeight
        s: root.snap
        sec: root.sec
        cpu: root.cpu
        rx: root.rx
        tx: root.tx
        levels: root.levels
        alertList: root.shownAlerts
        stale: root.stale
        secFresh: root.secAge <= L.SEC_STALE_MS
        bgOpacity: Plasmoid.configuration.opacity / 100
        expanded: root.detailOpen
        procs: root.procs
        termLog: root.termLog
        now: root.now
        onActivated: root.detailOpen = !root.detailOpen
        onKillRequested: (name, pids, sig) => root.requestKill(name, pids, sig)
        media: root.media
        mediaAt: root.mediaAt
        onMediaAction: (action) => root.mediaAction(action)
    }
}
