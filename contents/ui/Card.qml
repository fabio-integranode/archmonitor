import QtQuick
import QtQuick.Layouts
import QtQuick.Effects
import "Logic.js" as L

// Pure view: no Plasma imports, so it can be previewed with plain Qt.
Item {
    id: card

    // ── Inputs ───────────────────────────────────────────────────────────────
    property var s: ({})        // fast snapshot from archi-stat.sh
    property var sec: ({})      // security snapshot
    property real cpu: -1       // % (derived from /proc/stat deltas)
    property real rx: -1        // B/s
    property real tx: -1        // B/s
    property real bgOpacity: 0.82   // 0..1, from widget settings
    property var levels: ({})       // stabilised alert levels from L.evaluate()
    property var alertList: []      // [{key, kind, sev, text, short}], worst first (L.present output)
    property bool stale: false      // fast telemetry older than L.FAST_STALE_MS: dim the figures
    property bool secFresh: true    // security snapshot younger than L.SEC_STALE_MS
    property var policy: ({})       // security requirements { luks, fw, usbguard } from settings
    property bool expanded: false   // detail drawer open under the header
    property var procs: null        // top consumers for the drawer (null while sampling)
    property var termLog: ({})      // command name -> ms when SIGTERM was sent
    property real now: 0            // ms, ticks once a second
    readonly property bool hovered: hit.containsMouse
    signal activated()
    signal killRequested(string name, var pids, string sig)
    property var media: null        // `archi-stat.sh media` snapshot
    property real mediaAt: 0        // ms, when it arrived
    signal mediaAction(string action)   // play-pause | next | previous | raise
    property var batResult: null    // last bat-* result {action, ok, code, at}
    signal batteryAction(string action, int start, int end)   // set | full | care

    // ── Design tokens ────────────────────────────────────────────────────────
    readonly property string sans: "Inter"
    readonly property string mono: "JetBrains Mono"
    readonly property color cFg:     L.C.fg
    readonly property color cSub:    L.C.sub
    readonly property color cFaint:  L.C.faint
    readonly property color cTrack:  Qt.rgba(1, 1, 1, 0.07)
    readonly property color cBar:    L.C.bar
    readonly property color cAccent: L.C.accent
    readonly property color cOk:     L.C.ok
    readonly property color cWarn:   L.C.warn
    readonly property color cCrit:   L.C.crit
    readonly property int pad: 20
    readonly property int labelW: 40
    readonly property int auxW: 44

    function tone(level, base) { return level >= 2 ? cCrit : level === 1 ? cWarn : base; }
    function lv(key) { return levels && levels[key] ? levels[key] : 0; }
    function kindColor(kind) {
        return kind === "crit" ? cCrit : kind === "warn" ? cWarn
             : kind === "unknown" || kind === "stale" ? cSub : cOk;
    }

    // ── Derived ──────────────────────────────────────────────────────────────
    readonly property var d: L.derive(s)
    readonly property bool live: d.live
    readonly property real memUsed: d.memUsed
    readonly property real memPct: d.memPct
    readonly property real diskUsed: d.diskUsed
    readonly property real diskCap: d.diskCap
    readonly property real diskPct: d.diskPct
    readonly property string worstKind: alertList.length ? alertList[0].kind : ""
    readonly property var ctx: L.contextRow(s, levels)
    readonly property var mv: L.mediaView(media, now, mediaAt)
    // Masks (rounded cover, fading marquee) need a GPU scene graph; with the software
    // renderer they would draw nothing, so fall back to the plain items.
    readonly property bool fx: GraphicsInfo.api !== GraphicsInfo.Software
    readonly property var secItems: L.secView(sec, policy, secFresh, lv("reboot") > 0)
    readonly property var gv: L.gpuView(s)
    readonly property bool hasBattery: !live || L.has(s.bat_cap)

    // Battery charge window. `edit` is the window being dragged, then the one sent, until
    // the probe reports it (or 8 s pass, or the helper says no); `fullWant` likewise for
    // the full-charge switch. Both are view state only.
    readonly property var bv: L.batteryView(s)
    property bool batOpen: false
    property var edit: null             // {start, end, at}
    property var fullWant: null         // {on, at}
    readonly property var win: edit ? edit : { start: bv.start, end: bv.end }
    readonly property bool fullOn: fullWant ? fullWant.on : !!bv.full
    readonly property bool batBusy: !!edit && edit.at > 0 || !!fullWant
    readonly property string batNote: {
        if (batResult && !batResult.ok && now - batResult.at < 6000) return L.batteryError(batResult.code)
        if (batBusy) return "applying…"
        if (fullOn) return "until reboot"
        return ""
    }
    onSChanged: {
        if (edit && edit.at > 0 && ((s.care_start === edit.start || !bv.hasStart) && s.care_end === edit.end || now - edit.at > 8000)) edit = null
        if (fullWant && (!!bv.full === fullWant.on || now - fullWant.at > 8000)) fullWant = null
    }
    onBatResultChanged: if (batResult && !batResult.ok) { edit = null; fullWant = null }

    implicitWidth: 272
    implicitHeight: col.implicitHeight + 2 * pad

    // ── Surface ──────────────────────────────────────────────────────────────
    // Sized to the content, not to the container: if Plasma does not shrink the widget
    // after the drawer closes, the spare area stays transparent instead of stretching
    // the card.
    Rectangle {
        anchors { left: parent.left; right: parent.right; top: parent.top }
        height: card.implicitHeight
        radius: 14
        color: Qt.rgba(L.C.surface[0], L.C.surface[1], L.C.surface[2], card.bgOpacity)
        border.width: 1
        border.color: Qt.rgba(1, 1, 1, (card.hovered ? 0.16 : 0.06) * Math.min(1, card.bgOpacity * 2))
        Behavior on color { ColorAnimation { duration: 250 } }
        Behavior on border.color { ColorAnimation { duration: 150 } }
    }

    // ── Building blocks ──────────────────────────────────────────────────────
    component Label: Text {
        font.family: card.sans
        font.pixelSize: 9
        font.weight: Font.DemiBold
        font.letterSpacing: 1.5
        color: card.cSub
        renderType: Text.NativeRendering
    }
    component Num: Text {
        font.family: card.mono
        font.pixelSize: 11
        color: card.cFg
        renderType: Text.NativeRendering
    }
    component Note: Text {
        font.family: card.sans
        font.pixelSize: 10
        color: card.cSub
        renderType: Text.NativeRendering
    }
    component Hair: Rectangle {
        Layout.fillWidth: true
        implicitHeight: 1
        color: Qt.rgba(1, 1, 1, 0.07)
    }
    component Gap: Item { property int h: 12; implicitHeight: h; Layout.fillWidth: true }

    component Bar: Item {
        property real frac: 0
        property int level: 0
        Layout.fillWidth: true
        implicitHeight: 2
        Rectangle { anchors.fill: parent; radius: 1; color: card.cTrack }
        Rectangle {
            height: parent.height
            radius: 1
            width: parent.width * Math.max(0, Math.min(1, parent.frac))
            color: card.tone(parent.level, card.cBar)
            opacity: parent.level ? 1 : 0.55
            Behavior on width { NumberAnimation { duration: 700; easing.type: Easing.OutCubic } }
            Behavior on color { ColorAnimation { duration: 400 } }
        }
    }

    // Battery bar with the charge window: thin ticks at start and end when idle; with
    // `editing`, a faint band and two handles that drag in 5 % steps. Dragging only moves
    // the shown window (card.edit); releasing sends it.
    component WindowBar: Item {
        id: wb
        property real level: 0
        property int levelTone: 0
        property bool marks: false
        property int start: 0
        property int end: 100
        property bool hasStart: true
        property bool editing: false
        property bool dim: false
        implicitHeight: editing ? 18 : 2
        Behavior on implicitHeight { NumberAnimation { duration: 160; easing.type: Easing.OutCubic } }
        readonly property real cy: height / 2
        function px(p) { return Math.round(width * p / 100) }

        Rectangle { x: 0; width: parent.width; y: wb.cy - 1; height: 2; radius: 1; color: card.cTrack }
        Rectangle {           // the window band
            visible: wb.editing
            x: wb.px(wb.hasStart ? wb.start : 0); width: wb.px(wb.end) - x
            y: wb.cy - 3; height: 6; radius: 3
            color: Qt.rgba(card.cAccent.r, card.cAccent.g, card.cAccent.b, wb.dim ? 0.08 : 0.18)
        }
        Rectangle {           // charge level
            x: 0; y: wb.cy - 1; height: 2; radius: 1
            width: parent.width * Math.max(0, Math.min(1, wb.level))
            color: card.tone(wb.levelTone, card.cBar)
            opacity: wb.levelTone ? 1 : 0.55
            Behavior on width { NumberAnimation { duration: 700; easing.type: Easing.OutCubic } }
        }
        Repeater {            // ticks (idle)
            model: wb.marks && !wb.editing ? (wb.hasStart && wb.start > 0 ? [wb.start, wb.end] : [wb.end]) : []
            Rectangle {
                required property int modelData
                visible: modelData > 0 && modelData < 100
                x: wb.px(modelData) - 0.5; width: 1
                y: wb.cy - 3; height: 6
                color: wb.dim ? card.cTrack : card.cFaint
            }
        }
        Repeater {            // handles (editing)
            model: wb.editing ? (wb.hasStart ? ["start", "end"] : ["end"]) : []
            Rectangle {
                required property string modelData
                readonly property int v: modelData === "start" ? wb.start : wb.end
                width: 12; height: 12; radius: 6
                x: wb.px(v) - 6; y: wb.cy - 6
                color: drag.grab === modelData ? card.cAccent : card.cFg
                border.width: 2
                border.color: Qt.rgba(L.C.surface[0], L.C.surface[1], L.C.surface[2], 1)
                opacity: wb.dim ? 0.5 : 1
            }
        }
        MouseArea {
            id: drag
            objectName: "windowDrag"
            anchors.fill: parent
            anchors.leftMargin: -8; anchors.rightMargin: -8
            enabled: wb.editing
            preventStealing: true
            cursorShape: enabled ? Qt.SizeHorCursor : Qt.ArrowCursor
            property string grab: ""
            function at(mx) { return Math.max(0, Math.min(100, (mx - 8) / wb.width * 100)) }
            function move(mx) {
                const v = at(mx)
                const w = L.clampWindow(grab === "start" ? v : card.win.start, grab === "end" ? v : card.win.end, grab)
                card.edit = { start: wb.hasStart ? w.start : card.win.start, end: w.end, at: 0 }
            }
            onPressed: (m) => {
                const v = at(m.x)
                grab = !wb.hasStart ? "end"
                     : Math.abs(v - wb.start) < Math.abs(v - wb.end) ? "start"
                     : Math.abs(v - wb.start) > Math.abs(v - wb.end) ? "end"
                     : (v < wb.start ? "start" : "end")
                move(m.x)
            }
            onPositionChanged: (m) => { if (grab) move(m.x) }
            onReleased: {
                grab = ""
                if (!card.edit) return
                if (card.edit.start === card.bv.start && card.edit.end === card.bv.end && !card.fullOn) { card.edit = null; return }
                card.edit = { start: card.edit.start, end: card.edit.end, at: card.now }
                card.fullWant = card.fullOn ? { on: false, at: card.now } : null
                card.batteryAction("set", card.edit.start, card.edit.end)
            }
            onCanceled: { grab = ""; card.edit = null }
        }
    }

    // Media glyphs drawn as paths: font glyphs for ⏮ ⏯ ⏭ fall back to colour emoji.
    component MediaGlyph: Canvas {
        property string kind: "play"
        property color tint: card.cFg
        implicitWidth: 12
        implicitHeight: 12
        onKindChanged: requestPaint()
        onTintChanged: requestPaint()
        onPaint: {
            var g = getContext("2d"), w = width, h = height
            g.reset()
            g.fillStyle = tint
            function tri(x0, x1) { g.beginPath(); g.moveTo(x0, h * 0.14); g.lineTo(x1, h * 0.5); g.lineTo(x0, h * 0.86); g.closePath(); g.fill() }
            if (kind === "play") tri(w * 0.2, w * 0.9)
            else if (kind === "pause") { g.fillRect(w * 0.2, h * 0.14, w * 0.2, h * 0.72); g.fillRect(w * 0.6, h * 0.14, w * 0.2, h * 0.72) }
            else if (kind === "next") { tri(w * 0.1, w * 0.72); g.fillRect(w * 0.76, h * 0.14, w * 0.14, h * 0.72) }
            else if (kind === "prev") { tri(w * 0.9, w * 0.28); g.fillRect(w * 0.1, h * 0.14, w * 0.14, h * 0.72) }
            else if (kind === "note") {
                g.beginPath(); g.ellipse(w * 0.16, h * 0.62, w * 0.34, h * 0.28); g.fill()
                g.fillRect(w * 0.42, h * 0.12, w * 0.09, h * 0.64)
                g.fillRect(w * 0.42, h * 0.12, w * 0.36, h * 0.1)
            }
        }
    }

    component MediaButton: Item {
        id: mb
        property string kind: "play"
        property int size: 28
        signal activated()
        implicitWidth: size
        implicitHeight: size
        // Sits on top of artwork: its own dark disc and light rim keep it readable on any image.
        Rectangle {
            anchors.fill: parent
            radius: width / 2
            color: mbArea.pressed ? Qt.rgba(0, 0, 0, 0.62) : mbArea.containsMouse ? Qt.rgba(0, 0, 0, 0.50) : Qt.rgba(0, 0, 0, 0.38)
            border.width: 1
            border.color: Qt.rgba(1, 1, 1, mbArea.containsMouse ? 0.38 : 0.22)
            Behavior on color { ColorAnimation { duration: 120 } }
        }
        MediaGlyph {
            anchors.centerIn: parent
            width: Math.round(mb.size * 0.36); height: width
            kind: mb.kind
            tint: "#FFFFFF"
        }
        MouseArea {
            id: mbArea
            anchors.fill: parent
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onClicked: mb.activated()
        }
    }

    // Play and pause share one button; the two glyphs cross-fade and scale into each other.
    component PlayPause: Item {
        id: pp
        property bool playing: false
        property int size: 34
        signal activated()
        implicitWidth: size
        implicitHeight: size
        Rectangle {
            anchors.fill: parent
            radius: width / 2
            color: ppArea.pressed ? Qt.rgba(0, 0, 0, 0.70) : ppArea.containsMouse ? Qt.rgba(0, 0, 0, 0.58) : Qt.rgba(0, 0, 0, 0.46)
            border.width: 1
            border.color: Qt.rgba(1, 1, 1, ppArea.containsMouse ? 0.45 : 0.30)
            Behavior on color { ColorAnimation { duration: 120 } }
        }
        MediaGlyph {
            anchors.centerIn: parent
            width: Math.round(pp.size * 0.36); height: width
            kind: "pause"
            tint: "#FFFFFF"
            opacity: pp.playing ? 1 : 0
            scale: pp.playing ? 1 : 0.6
            Behavior on opacity { NumberAnimation { duration: 160 } }
            Behavior on scale { NumberAnimation { duration: 160; easing.type: Easing.OutBack } }
        }
        MediaGlyph {
            anchors.centerIn: parent
            anchors.horizontalCenterOffset: 1
            width: Math.round(pp.size * 0.36); height: width
            kind: "play"
            tint: "#FFFFFF"
            opacity: pp.playing ? 0 : 1
            scale: pp.playing ? 0.6 : 1
            Behavior on opacity { NumberAnimation { duration: 160 } }
            Behavior on scale { NumberAnimation { duration: 160; easing.type: Easing.OutBack } }
        }
        MouseArea {
            id: ppArea
            anchors.fill: parent
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onClicked: pp.activated()
        }
    }

    // One line of text; when it does not fit it scrolls left as a seamless loop
    // (two copies, 30 px/s, 2.5 s rest at the start of every pass).
    component Marquee: Item {
        id: mq
        property string text
        property color tint: card.cFg
        property int pixelSize: 11
        property int weight: Font.Normal
        readonly property bool overflow: t1.implicitWidth > width
        readonly property int gap: 48
        clip: true
        implicitHeight: t1.implicitHeight
        // Soft edges while scrolling instead of a hard cut mid-letter.
        Item {
            id: fade
            anchors.fill: parent
            layer.enabled: true
            visible: false
            Rectangle {
                anchors.fill: parent
                gradient: Gradient {
                    orientation: Gradient.Horizontal
                    GradientStop { position: 0.0;  color: Qt.rgba(0, 0, 0, mq.overflow && strip.x < 0 ? 0 : 1) }
                    GradientStop { position: 0.08; color: "black" }
                    GradientStop { position: 0.86; color: "black" }
                    GradientStop { position: 1.0;  color: Qt.rgba(0, 0, 0, mq.overflow ? 0 : 1) }
                }
            }
        }
        // The strip moves inside a clipped viewport; the viewport (not the whole strip)
        // is what the fade mask is applied to.
        Item {
            id: viewport
            anchors.fill: parent
            clip: true
            layer.enabled: card.fx
            visible: !card.fx
            Row {
                id: strip
                spacing: mq.gap
                Text { id: t1; text: mq.text; font.family: card.sans; font.pixelSize: mq.pixelSize; font.weight: mq.weight; color: mq.tint; renderType: Text.NativeRendering }
                Text { visible: mq.overflow; text: mq.text; font.family: card.sans; font.pixelSize: mq.pixelSize; font.weight: mq.weight; color: mq.tint; renderType: Text.NativeRendering }
            }
        }
        MultiEffect {
            anchors.fill: parent
            visible: card.fx
            source: viewport
            maskEnabled: true
            maskSource: fade
            maskThresholdMin: 0.5       // alpha is mapped through a soft step centred here,
            maskSpreadAtMin: 1.0        // so the gradient below becomes a smooth fade
        }
        SequentialAnimation {
            id: scroll
            running: mq.overflow && mq.visible
            loops: Animation.Infinite
            PropertyAction { target: strip; property: "x"; value: 0 }
            PauseAnimation { duration: 2500 }
            NumberAnimation {
                target: strip; property: "x"
                to: -(t1.implicitWidth + mq.gap)
                duration: (t1.implicitWidth + mq.gap) / 30 * 1000
            }
        }
        onTextChanged: { strip.x = 0; if (scroll.running) scroll.restart() }
        onOverflowChanged: if (!overflow) strip.x = 0
    }

    component Metric: ColumnLayout {
        id: m
        property string label
        property string value
        property string aux
        property int valueLevel: 0
        property int auxLevel: 0
        property real frac: -1
        property int barLevel: Math.max(valueLevel, auxLevel)
        Layout.fillWidth: true
        spacing: 6
        RowLayout {
            Layout.fillWidth: true
            spacing: 0
            Label { text: m.label; Layout.preferredWidth: card.labelW }
            Num {
                text: m.value
                color: card.tone(m.valueLevel, card.cFg)
                horizontalAlignment: Text.AlignRight
                Layout.fillWidth: true
            }
            Num {
                text: m.aux
                color: card.tone(m.auxLevel, card.cSub)
                horizontalAlignment: Text.AlignRight
                Layout.preferredWidth: card.auxW
            }
        }
        Bar { visible: m.frac >= 0; frac: m.frac; level: m.barLevel }
    }

    // ── Layout ───────────────────────────────────────────────────────────────
    ColumnLayout {
        id: col
        anchors { left: parent.left; right: parent.right; top: parent.top; margins: card.pad }
        spacing: 0

        // Header
        RowLayout {
            Layout.fillWidth: true
            spacing: 8
            ColumnLayout {
                spacing: 3
                Layout.fillWidth: true
                Layout.minimumWidth: 0
                Text {
                    text: card.live ? (card.s.host || "—").toUpperCase() : "…"
                    font.family: card.sans
                    font.pixelSize: 14
                    font.weight: Font.DemiBold
                    font.letterSpacing: 3
                    color: card.cFg
                    renderType: Text.NativeRendering
                }
                // Model, then uptime. A long model is cut, never the uptime.
                Item {
                    Layout.fillWidth: true
                    implicitHeight: upNote.implicitHeight
                    Note {
                        id: modelNote
                        visible: text !== ""
                        text: card.live && card.s.model ? card.s.model : ""
                        font.pixelSize: 9
                        elide: Text.ElideRight
                        width: Math.max(0, Math.min(implicitWidth, parent.width - upNote.implicitWidth))
                    }
                    Note {
                        id: upNote
                        x: modelNote.visible ? modelNote.width : 0
                        text: !card.live ? "" : (card.s.model ? "  ·  " : "") + "up " + L.dur(card.s.uptime)
                        font.pixelSize: 9
                    }
                }
            }

            // Status pill: one word when nominal, the worst finding otherwise.
            Rectangle {
                id: pill
                readonly property color c: card.live || card.stale ? card.kindColor(card.worstKind) : card.cFaint
                Layout.alignment: Qt.AlignTop
                implicitHeight: 20
                implicitWidth: pillRow.implicitWidth + 14
                radius: 10
                color: Qt.rgba(pill.c.r, pill.c.g, pill.c.b, 0.10)
                border.width: 1
                border.color: Qt.rgba(pill.c.r, pill.c.g, pill.c.b, 0.30)
                Row {
                    id: pillRow
                    anchors.centerIn: parent
                    spacing: 6
                    Rectangle {
                        id: dot
                        width: 6; height: 6; radius: 3
                        anchors.verticalCenter: parent.verticalCenter
                        color: pill.c
                        SequentialAnimation on opacity {
                            running: card.worstKind === "crit"
                            loops: Animation.Infinite
                            onRunningChanged: if (!running) dot.opacity = 1
                            NumberAnimation { to: 0.25; duration: 650; easing.type: Easing.InOutSine }
                            NumberAnimation { to: 1.0;  duration: 650; easing.type: Easing.InOutSine }
                        }
                    }
                    Label {
                        anchors.verticalCenter: parent.verticalCenter
                        text: card.alertList.length === 0 ? (card.live ? "NOMINAL" : "…")
                              : card.alertList[0].short + (card.alertList.length > 1 ? "  +" + (card.alertList.length - 1) : "")
                        font.pixelSize: 9
                        font.letterSpacing: 0.9
                        color: pill.c
                    }
                }
            }
        }

        // Detail drawer: opens right under the header, keeping it intact, and pushes the
        // metrics down. Height animates so the eye can follow the move.
        Item {
            id: drawer
            Layout.fillWidth: true
            // Reach 8 px into the card padding so the row highlights are not clipped.
            Layout.leftMargin: -8
            Layout.rightMargin: -8
            implicitHeight: card.expanded ? drawerCol.implicitHeight : 0
            visible: implicitHeight > 0
            clip: true
            Behavior on implicitHeight { NumberAnimation { duration: 200; easing.type: Easing.OutCubic } }

            ColumnLayout {
                id: drawerCol
                anchors { left: parent.left; right: parent.right; top: parent.top; leftMargin: 8; rightMargin: 8 }
                spacing: 0
                opacity: card.expanded ? 1 : 0
                Behavior on opacity { NumberAnimation { duration: 160 } }

                Gap { h: 18 }
                Hair {}
                Gap { h: 16 }
                Detail {
                    objectName: "detail"
                    Layout.fillWidth: true
                    s: card.s
                    sec: card.sec
                    alertList: card.alertList
                    procs: card.procs
                    termLog: card.termLog
                    now: card.now
                    onKillRequested: (name, pids, sig) => card.killRequested(name, pids, sig)
                }
            }
        }

        // Everything below the header dims when the telemetry is stale.
        ColumnLayout {
            id: body
            Layout.fillWidth: true
            spacing: 0
            opacity: card.stale ? 0.35 : 1
            Behavior on opacity { NumberAnimation { duration: 300 } }

            Gap { h: 18 }
            Hair {}
            Gap { h: 16 }

            // Compute
            ColumnLayout {
                Layout.fillWidth: true
                spacing: 14

                Metric {
                    label: "CPU"
                    value: L.pct(card.cpu)
                    aux: card.live ? L.degC(card.s.cpu_temp) : "—"
                    auxLevel: card.lv("cpuT")
                    frac: card.cpu >= 0 ? card.cpu / 100 : 0
                }
                Metric {
                    label: "MEM"
                    value: card.live ? L.gib(card.memUsed) + " / " + L.gib(card.s.mem_total) + " GiB" : "—"
                    valueLevel: card.lv("mem")
                    aux: L.pct(card.memPct)
                    auxLevel: card.lv("mem")
                    frac: card.memPct >= 0 ? card.memPct / 100 : 0
                }
                Metric {
                    label: "GPU"
                    // Busy % where the driver has it (AMD, NVIDIA), else the clock (Intel).
                    visible: card.gv.show
                    value: card.gv.value
                    aux: L.degOpt(card.s.gpu_temp)
                    auxLevel: card.lv("gpuT")
                    frac: card.gv.frac
                }
                Metric {
                    label: "SSD"
                    value: card.diskCap > 0 ? L.gb(card.diskUsed) + " / " + L.gb(card.diskCap) + " GiB" : "—"
                    valueLevel: card.lv("disk")
                    aux: L.degOpt(card.s.ssd_temp)
                    auxLevel: card.lv("ssdT")
                    frac: card.diskPct >= 0 ? card.diskPct / 100 : 0
                }
                // One contextual row of fixed height, so the card never changes size:
                // FAN when hot, else SoC power (faint at idle), else blank.
                RowLayout {
                    Layout.fillWidth: true
                    spacing: 0
                    visible: L.contextRowUsed(card.s)
                    Label {
                        text: card.ctx.label
                        color: card.ctx.tone === "quiet" ? card.cFaint : card.cSub
                        Layout.preferredWidth: card.labelW
                    }
                    Num {
                        text: card.ctx.value
                        color: card.ctx.tone === "warn" ? card.cWarn : card.ctx.tone === "quiet" ? card.cFaint : card.cFg
                        horizontalAlignment: Text.AlignRight
                        Layout.fillWidth: true
                    }
                    Num {
                        text: card.ctx.aux
                        color: card.cFaint
                        horizontalAlignment: Text.AlignRight
                        Layout.preferredWidth: card.auxW
                    }
                }
            }

            Gap { h: 20 }
            Hair {}
            Gap { h: 16 }

            // Network
            RowLayout {
                Layout.fillWidth: true
                spacing: 8
                Label {
                    text: !card.live ? "—"
                          : card.s.ssid ? card.s.ssid.toUpperCase()
                          : card.s.iface ? card.s.iface.toUpperCase() : "OFFLINE"
                    color: card.live && card.s.iface ? card.cAccent : card.cWarn
                    elide: Text.ElideRight
                    Layout.fillWidth: true
                }
                Num {
                    visible: card.live && L.has(card.s.signal)
                    text: card.live && L.has(card.s.signal) ? card.s.signal + " dBm" : ""
                    font.pixelSize: 9
                    color: card.tone(card.lv("sig"), card.cSub)
                }
                Row {
                    visible: card.live && L.has(card.s.signal)
                    spacing: 2
                    Layout.alignment: Qt.AlignVCenter
                    Repeater {
                        model: 4
                        Rectangle {
                            required property int index
                            width: 2.5
                            height: 3 + index * 2.5
                            radius: 1
                            anchors.bottom: parent.bottom
                            color: index < L.signalBars(card.s.signal)
                                   ? card.tone(card.lv("sig"), card.cFg)
                                   : card.cTrack
                        }
                    }
                }
            }
            Gap { h: 10 }
            RowLayout {
                Layout.fillWidth: true
                spacing: 0
                Num { text: "↓"; color: card.cFaint }
                Num { text: " " + L.rate(card.rx); Layout.fillWidth: true }
                Num { text: "↑"; color: card.cFaint }
                Num { text: " " + L.rate(card.tx); Layout.preferredWidth: 84; horizontalAlignment: Text.AlignRight }
            }

            // Power: only on machines with a battery. Clicking the section, where the
            // firmware exposes charge thresholds, opens the charge window: handles on the
            // bar and a full-charge switch.
            ColumnLayout {
                Layout.fillWidth: true
                spacing: 0
                visible: card.hasBattery

                Gap { h: 20 }
                Hair {}
                Gap { h: 16 }
                Item {
                    id: batBlock
                    objectName: "battery"
                    Layout.fillWidth: true
                    implicitHeight: batCol.implicitHeight
                    MouseArea {
                        anchors.fill: parent
                        enabled: card.bv.show
                        cursorShape: enabled ? Qt.PointingHandCursor : Qt.ArrowCursor
                        onClicked: card.batOpen = !card.batOpen
                    }
                    ColumnLayout {
                        id: batCol
                        anchors { left: parent.left; right: parent.right; top: parent.top }
                        spacing: 0
                        RowLayout {
                            Layout.fillWidth: true
                            spacing: 8
                            Label { text: "BATTERY"; Layout.alignment: Qt.AlignBaseline }
                            Label {
                                visible: card.fullOn
                                text: "FULL CHARGE"
                                color: card.cAccent
                                Layout.alignment: Qt.AlignBaseline
                            }
                            Item { Layout.fillWidth: true }
                            Num {
                                text: card.live && L.has(card.s.bat_cap) ? card.s.bat_cap + "%" : "—"
                                font.pixelSize: 16
                                font.weight: Font.Medium
                                color: card.tone(card.lv("bat"), card.cFg)
                            }
                        }
                        Gap { h: 8 }
                        WindowBar {
                            id: wbar
                            Layout.fillWidth: true
                            level: card.live && L.has(card.s.bat_cap) ? card.s.bat_cap / 100 : 0
                            levelTone: card.lv("bat")
                            marks: card.bv.show
                            start: card.win.start
                            end: card.win.end
                            hasStart: !!card.bv.hasStart
                            editing: card.batOpen && card.bv.ctl
                            dim: card.fullOn
                        }
                        Gap { h: 8 }
                        Note { text: card.live ? L.batteryLine(card.s) : ""; Layout.fillWidth: true; elide: Text.ElideRight }

                        ColumnLayout {
                            Layout.fillWidth: true
                            spacing: 0
                            visible: card.batOpen && card.bv.show
                            Gap { h: 14 }
                            RowLayout {
                                Layout.fillWidth: true
                                spacing: 0
                                Label { text: "CHARGE WINDOW"; Layout.fillWidth: true }
                                Num {
                                    text: card.bv.hasStart ? card.win.start + "–" + card.win.end + "%" : "≤ " + card.win.end + "%"
                                    color: card.fullOn ? card.cFaint : card.cFg
                                }
                            }
                            Gap { h: 12 }
                            RowLayout {
                                Layout.fillWidth: true
                                spacing: 10
                                visible: card.bv.ctl
                                // Pill switch: charge to 100 % now (a trip later today), or back
                                // to the window.
                                Rectangle {
                                    id: fullBtn
                                    objectName: "fullCharge"
                                    implicitWidth: fullLbl.implicitWidth + 22
                                    implicitHeight: 22
                                    radius: 11
                                    readonly property color c: card.fullOn ? card.cAccent : card.cSub
                                    color: Qt.rgba(c.r, c.g, c.b, card.fullOn ? 0.16 : (fullArea.containsMouse ? 0.10 : 0.04))
                                    border.width: 1
                                    border.color: Qt.rgba(c.r, c.g, c.b, card.fullOn ? 0.55 : 0.28)
                                    Behavior on color { ColorAnimation { duration: 150 } }
                                    Label {
                                        id: fullLbl
                                        anchors.centerIn: parent
                                        text: card.fullOn ? "FULL CHARGE · ON" : "CHARGE TO 100%"
                                        color: fullBtn.c
                                    }
                                    MouseArea {
                                        id: fullArea
                                        anchors.fill: parent
                                        hoverEnabled: true
                                        cursorShape: Qt.PointingHandCursor
                                        onClicked: {
                                            const on = !card.fullOn
                                            card.fullWant = { on: on, at: card.now }
                                            card.batteryAction(on ? "full" : "care", 0, 0)
                                        }
                                    }
                                }
                                Item { Layout.fillWidth: true }
                                Note {
                                    text: card.batNote
                                    font.pixelSize: 9
                                    color: card.batResult && !card.batResult.ok && card.batNote === L.batteryError(card.batResult.code) ? card.cWarn : card.cSub
                                }
                            }
                            Note {
                                visible: !card.bv.ctl
                                text: "Read-only: battery helper not installed"
                                font.pixelSize: 9
                                wrapMode: Text.WordWrap
                                Layout.fillWidth: true
                            }
                        }
                    }
                }
            }

            Gap { h: 20 }
            Hair {}
            Gap { h: 14 }

            // Security posture (wraps when the names are long, e.g. FIREWALLD + REBOOT)
            Flow {
                Layout.fillWidth: true
                spacing: 14
                Repeater {
                    model: card.secItems
                    // ok: filled green · bad: filled amber · off (not in use, not required):
                    // hollow · unk (cannot tell): hollow with "?".
                    Row {
                        required property var modelData
                        readonly property bool unknown: modelData.tone === "unk"
                        readonly property bool bad: modelData.tone === "bad"
                        readonly property bool hollow: unknown || modelData.tone === "off"
                        spacing: 5
                        Rectangle {
                            width: 5; height: 5; radius: 2.5
                            anchors.verticalCenter: parent.verticalCenter
                            color: parent.hollow ? "transparent" : parent.bad ? card.cWarn : card.cOk
                            border.width: parent.hollow ? 1 : 0
                            border.color: card.cFaint
                        }
                        Label {
                            text: parent.modelData.k + (parent.unknown ? " ?" : "")
                            font.pixelSize: 8
                            color: parent.bad ? card.cWarn : card.cFaint
                        }
                    }
                }
            }
        }

        // Media: what a browser is playing. Outside the dimmed body: its data has its own
        // source. One 16:9 block: the artwork fills it; a subtle gradient from the bottom
        // keeps the controls, progress and title readable on any image. Clicking the
        // artwork or the title brings the browser forward.
        ColumnLayout {
            id: mediaBar
            visible: card.mv.visible
            Layout.fillWidth: true
            spacing: 0

            Gap { h: 20 }

            Item {
                id: art
                objectName: "mediaArt"
                readonly property int radius: 8
                Layout.fillWidth: true
                implicitHeight: Math.round(width * 9 / 16)

                // Fallback when there is no artwork (or it is still loading).
                Rectangle {
                    anchors.fill: parent
                    radius: art.radius
                    gradient: Gradient {
                        GradientStop { position: 0.0; color: "#262B31" }
                        GradientStop { position: 1.0; color: "#14171B" }
                    }
                }
                Image {
                    id: coverImg
                    // The probe only reports a written file and re-versions the URL when it
                    // changes. As a last guard, a failed load is retried a few times: same
                    // file, cache bypassed by the extra query parameter.
                    property int attempt: 0
                    readonly property string want: card.mv.art
                    onWantChanged: attempt = 0
                    source: want === "" ? "" : attempt === 0 ? want
                          : want + (want.indexOf("?") < 0 ? "?" : "&") + "r=" + attempt
                    onStatusChanged: if (status === Image.Error && attempt < 5) retry.restart()
                    Timer { id: retry; interval: 700; onTriggered: coverImg.attempt++ }
                    anchors.fill: parent
                    fillMode: Image.PreserveAspectCrop
                    asynchronous: true
                    sourceSize.width: 480       // fixed: a size bound to the layout loads twice
                    visible: !card.fx && status === Image.Ready
                }
                Item {
                    id: artMask
                    anchors.fill: parent
                    layer.enabled: true
                    visible: false
                    Rectangle { anchors.fill: parent; radius: art.radius; color: "black" }
                }
                MultiEffect {
                    anchors.fill: parent
                    source: coverImg
                    maskEnabled: true
                    maskSource: artMask
                    visible: card.fx && coverImg.status === Image.Ready
                }

                // Legibility scrim: light at the top, so the artwork reads, and dense from the
                // progress line down, so the time and the scrolling title stay crisp.
                Rectangle {
                    anchors.fill: parent
                    radius: art.radius
                    gradient: Gradient {
                        GradientStop { position: 0.0;  color: Qt.rgba(0, 0, 0, 0.10) }
                        GradientStop { position: 0.40; color: Qt.rgba(0, 0, 0, 0.22) }
                        GradientStop { position: 0.62; color: Qt.rgba(0, 0, 0, 0.62) }
                        GradientStop { position: 1.0;  color: Qt.rgba(0, 0, 0, 0.90) }
                    }
                }
                Rectangle {
                    anchors.fill: parent
                    radius: art.radius
                    color: "transparent"
                    border.width: 1
                    border.color: Qt.rgba(1, 1, 1, 0.06)
                }

                MouseArea {
                    anchors.fill: parent
                    cursorShape: Qt.PointingHandCursor
                    onClicked: card.mediaAction("raise")
                }

                // Controls, centred in the space above the progress and title.
                Row {
                    id: controls
                    anchors.horizontalCenter: parent.horizontalCenter
                    y: Math.round((bottomBlock.y - height) / 2) + 2
                    spacing: 18
                    MediaButton { kind: "prev"; size: 30; anchors.verticalCenter: parent.verticalCenter; onActivated: card.mediaAction("previous") }
                    PlayPause { size: 40; playing: card.mv.playing; onActivated: card.mediaAction("play-pause") }
                    MediaButton { kind: "next"; size: 30; anchors.verticalCenter: parent.verticalCenter; onActivated: card.mediaAction("next") }
                }

                // Progress (remaining time only) and title, on the dense end of the scrim.
                ColumnLayout {
                    id: bottomBlock
                    anchors { left: parent.left; right: parent.right; bottom: parent.bottom; margins: 12 }
                    spacing: 7
                    RowLayout {
                        Layout.fillWidth: true
                        spacing: 8
                        Item {
                            Layout.fillWidth: true
                            Layout.alignment: Qt.AlignVCenter
                            implicitHeight: 3
                            opacity: card.mv.frac >= 0 ? 1 : 0.5
                            Rectangle { anchors.fill: parent; radius: 1.5; color: Qt.rgba(1, 1, 1, 0.25) }
                            Rectangle {
                                height: parent.height
                                radius: 1.5
                                color: Qt.rgba(1, 1, 1, 0.92)
                                width: parent.width * Math.max(0, Math.min(1, card.mv.frac))
                                Behavior on width { NumberAnimation { duration: 900 } }
                            }
                        }
                        Text {
                            visible: text !== ""
                            text: card.mv.time
                            font.family: card.mono
                            font.pixelSize: 10
                            color: Qt.rgba(1, 1, 1, 0.80)
                            renderType: Text.NativeRendering
                        }
                    }
                    Marquee {
                        Layout.fillWidth: true
                        text: card.mv.line
                        pixelSize: 12
                        weight: Font.Medium
                        tint: card.mv.playing ? "#FFFFFF" : Qt.rgba(1, 1, 1, 0.70)
                        MouseArea {
                            anchors.fill: parent
                            cursorShape: Qt.PointingHandCursor
                            onClicked: card.mediaAction("raise")
                        }
                    }
                }
            }
        }
    }

    // Below the content (z -1): clicks anywhere toggle the drawer, except on drawer rows,
    // which handle their own.
    MouseArea {
        id: hit
        z: -1
        anchors { left: parent.left; right: parent.right; top: parent.top }
        height: card.implicitHeight
        hoverEnabled: true
        cursorShape: Qt.PointingHandCursor
        onClicked: (mouse) => {
            // Inside the open drawer a click never closes it: only the header or the
            // metrics below toggle. A missed row cannot collapse the card.
            if (card.expanded) {
                const top = drawer.mapToItem(card, 0, 0).y
                if (mouse.y >= top && mouse.y < top + drawer.height) return
            }
            // Clicks between the media controls do nothing rather than toggling the drawer.
            if (mediaBar.visible && mouse.y >= mediaBar.mapToItem(card, 0, 0).y) return
            card.activated()
        }
    }
}
