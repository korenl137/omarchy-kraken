// Kraken Cooler editor. All device and file access goes through the `kraken-profile` CLI.
import QtQuick
import Quickshell
import Quickshell.Io

ShellRoot {
    id: root

    // ---- theme (falls back to Matte Black; overridden from the current Omarchy theme) ----
    property color cBg: "#121212"
    property color cPanel: "#1e1e1e"
    property color cLine: "#333333"
    property color cText: "#bebebe"
    property color cDim: "#8a8a8d"
    property color cAccent: "#e68e0d"
    property color cWarn: "#D35F5F"

    // ---- editor state ----
    property var profiles: []          // [{name, pump, fan, builtin}]
    property string activeName: ""
    property string current: ""        // profile being edited
    property bool builtin: false
    property int pump: 80
    property var points: [[28, 40], [45, 100]]
    property int sel: -1
    property bool dirty: false
    property string nameField: ""
    property var errors: []
    property var warns: []
    property string note: ""
    property bool verifyPending: false
    property var st: ({ liquid: NaN, cpu: NaN, pump_rpm: 0, pump_duty: 0, fan_rpm: 0, fan_duty: 0 })
    property bool saveThenApply: false

    readonly property int tMin: 20
    readonly property int tMax: 59

    function fanArg() { return points.map(p => p[0] + " " + p[1]).join(" ") }
    function interp(t) {
        var p = points
        if (t <= p[0][0]) return p[0][1]
        for (var i = 1; i < p.length; i++)
            if (t <= p[i][0]) return p[i-1][1] + (p[i][1] - p[i-1][1]) * (t - p[i-1][0]) / (p[i][0] - p[i-1][0])
        return p[p.length-1][1]
    }
    function clamp(v, lo, hi) { return Math.max(lo, Math.min(hi, v)) }

    // Undo history: consecutive edits within 500 ms (one drag) count as one step.
    property var undoStack: []
    property var redoStack: []
    property string committed: ""
    property double lastTouch: 0
    function snap() { return JSON.stringify({ pump: pump, points: points }) }
    function touch() {
        var now = Date.now()
        if (now - lastTouch > 500 && committed !== "") {
            undoStack = undoStack.concat([committed]).slice(-100); redoStack = []
        }
        lastTouch = now; committed = snap()
        dirty = true; note = ""; runCheck(); canvas.requestPaint()
    }
    function restore(str) {
        var o = JSON.parse(str)
        pump = o.pump; points = o.points; sel = -1; committed = str; lastTouch = 0
        dirty = true; note = ""; runCheck(); canvas.requestPaint()
    }
    function undo() {
        if (!undoStack.length) return
        var cur = snap(), prev = undoStack[undoStack.length - 1]
        undoStack = undoStack.slice(0, -1); redoStack = redoStack.concat([cur]); restore(prev)
    }
    function redo() {
        if (!redoStack.length) return
        var cur = snap(), nxt = redoStack[redoStack.length - 1]
        redoStack = redoStack.slice(0, -1); undoStack = undoStack.concat([cur]); restore(nxt)
    }
    function revert() {
        for (var i = 0; i < profiles.length; i++) if (profiles[i].name === current) {
            lastTouch = 0; pump = profiles[i].pump; points = profiles[i].fan.map(p => [p[0], p[1]]); sel = -1
            touch(); dirty = false; note = "Reverted to saved " + current; return
        }
    }
    function runCheck() {
        pCheck.command = ["kraken-profile", "check", "--pump", String(pump), "--fan", fanArg()]
        pCheck.running = true
    }
    function select(name) {
        for (var i = 0; i < profiles.length; i++) {
            if (profiles[i].name === name) {
                current = name; builtin = profiles[i].builtin; pump = profiles[i].pump
                points = profiles[i].fan.map(p => [p[0], p[1]]); sel = -1; dirty = false
                nameField = builtin ? name + "-copy" : name; note = ""
                undoStack = []; redoStack = []; committed = snap(); lastTouch = 0
                runCheck(); canvas.requestPaint(); return
            }
        }
    }
    function reload(thenSelect) {
        pList.thenSelect = thenSelect || ""
        pList.running = true
    }
    function apply() {
        pTry.command = ["kraken-profile", "try", "--pump", String(pump), "--fan", fanArg()]
        pTry.running = true
    }
    function save(activate) {
        var n = nameField.trim()
        if (!n) { note = "Enter a profile name"; return }
        saveThenApply = activate
        pSave.target = n
        pSave.command = ["kraken-profile", "save", n, "--pump", String(pump), "--fan", fanArg()].concat(activate ? ["--activate"] : [])
        pSave.running = true
    }

    // ---- processes ----
    Process {
        id: pList
        property string thenSelect: ""
        command: ["kraken-profile", "list", "--json"]
        stdout: StdioCollector {
            onStreamFinished: {
                var d = JSON.parse(text)
                root.profiles = d.profiles; root.activeName = d.active
                root.select(pList.thenSelect || (root.current && d.profiles.some(p => p.name === root.current) ? root.current : d.active))
            }
        }
    }
    Process {
        id: pStatus
        command: ["kraken-profile", "status", "--json"]
        stdout: StdioCollector {
            onStreamFinished: {
                try { root.st = JSON.parse(text) } catch (e) { return }
                canvas.requestPaint()
                if (root.verifyPending) {
                    root.verifyPending = false
                    var want = root.interp(root.st.liquid), got = root.st.fan_duty
                    root.note = Math.abs(want - got) <= 5
                        ? "Applied. Device fan " + got + "% matches curve (" + Math.round(want) + "%) and pump " + root.st.pump_duty + "%"
                        : "Applied, but device fan " + got + "% differs from curve " + Math.round(want) + "% (fan may still be ramping; check again)"
                }
            }
        }
    }
    Process {
        id: pCheck
        stdout: StdioCollector {
            onStreamFinished: {
                try { var d = JSON.parse(text); root.errors = d.errors; root.warns = d.warnings } catch (e) {}
            }
        }
    }
    Process {
        id: pTry
        stderr: StdioCollector { id: tryErr }
        onExited: code => {
            if (code === 0) { root.note = "Applied. Verifying..."; verifyTimer.restart() }
            else root.note = "Apply failed: " + tryErr.text.trim()
        }
    }
    Process {
        id: pSave
        property string target: ""
        stderr: StdioCollector { id: saveErr }
        onExited: code => {
            if (code !== 0) { root.note = "Save failed: " + saveErr.text.trim(); return }
            if (root.saveThenApply) root.apply()
            else root.note = "Saved " + target
            root.reload(target)
        }
    }
    Process {
        id: pDelete
        stderr: StdioCollector { id: delErr }
        onExited: code => { if (code === 0) root.reload(root.activeName === root.current ? "balanced" : "") ; else root.note = delErr.text.trim() }
    }
    Timer { id: verifyTimer; interval: 3000; onTriggered: { root.verifyPending = true; pStatus.running = true } }
    Timer { interval: 1000; running: win.visible; repeat: true; triggeredOnStart: true; onTriggered: if (!pStatus.running) pStatus.running = true }

    FileView {
        path: Quickshell.env("HOME") + "/.local/state/omarchy/current/theme/colors.toml"
        printErrors: false
        onLoaded: {
            var m = {}
            text().split("\n").forEach(l => { var r = /^(\w+)\s*=\s*"(#[0-9a-fA-F]{6})"/.exec(l); if (r) m[r[1]] = r[2] })
            if (m.background) root.cBg = m.background
            if (m.lighter_background) root.cPanel = m.lighter_background
            if (m.selection) root.cLine = m.selection
            if (m.foreground) root.cText = m.foreground
            if (m.light_foreground) root.cDim = m.light_foreground
            if (m.accent) root.cAccent = m.accent
            if (m.red) root.cWarn = m.red
        }
    }

    Component.onCompleted: reload("")

    // ---- small widgets ----
    component Btn: Rectangle {
        property string label
        property bool primary: false
        property bool enabledBtn: true
        signal clicked()
        implicitWidth: t.implicitWidth + 24; implicitHeight: 30; radius: 6
        color: primary ? root.cAccent : root.cLine
        opacity: enabledBtn ? (ma.containsMouse ? 0.85 : 1) : 0.35
        Text { id: t; anchors.centerIn: parent; text: parent.label; color: parent.primary ? root.cBg : root.cText; font.pixelSize: 13 }
        MouseArea { id: ma; anchors.fill: parent; hoverEnabled: true; onClicked: if (parent.enabledBtn) parent.clicked() }
    }
    component Num: Rectangle {
        id: num
        property int value; property int lo; property int hi; property string suffix: ""
        property bool editable: true
        signal edited(int v)
        // text is assigned (not bound) while typing, so refresh it whenever the value changes from elsewhere (undo, drag)
        onValueChanged: if (!inp.activeFocus) inp.text = value + suffix
        Component.onCompleted: inp.text = value + suffix
        implicitWidth: 64; implicitHeight: 28; radius: 5; color: root.cBg; border.color: inp.activeFocus ? root.cAccent : root.cLine
        TextInput {
            id: inp; anchors.fill: parent; anchors.margins: 4; color: root.cText; font.pixelSize: 13
            horizontalAlignment: TextInput.AlignHCenter; verticalAlignment: TextInput.AlignVCenter
            readOnly: !num.editable; inputMethodHints: Qt.ImhDigitsOnly; validator: RegularExpressionValidator { regularExpression: /[0-9]{0,3}/ }  // range is clamped on commit; a bounded validator blocks Enter for e.g. "15"
            onActiveFocusChanged: if (activeFocus) { text = String(num.value); selectAll() } else text = num.value + num.suffix
            readonly property var padMap: ({ [Qt.Key_Insert]: "0", [Qt.Key_End]: "1", [Qt.Key_Down]: "2", [Qt.Key_PageDown]: "3",
                [Qt.Key_Left]: "4", [Qt.Key_Clear]: "5", [Qt.Key_Right]: "6", [Qt.Key_Home]: "7", [Qt.Key_Up]: "8", [Qt.Key_PageUp]: "9" })
            Keys.onPressed: event => {
                if (!(event.modifiers & Qt.KeypadModifier)) return
                var d = padMap[event.key]
                if (d !== undefined) { remove(selectionStart, selectionEnd); insert(cursorPosition, d); event.accepted = true }
                else if (event.key === Qt.Key_Delete) { event.accepted = true }   // keypad "." never valid here
            }
            onEditingFinished: { var v = parseInt(text); if (num.editable && !isNaN(v)) num.edited(root.clamp(v, num.lo, num.hi)); text = num.value + num.suffix; focus = false }
        }
    }

    FloatingWindow {
        id: win
        visible: true
        title: "Kraken Cooler"
        implicitWidth: 960; implicitHeight: 600
        color: root.cBg
        onVisibleChanged: if (!visible) Qt.quit()

        Shortcut { sequences: [StandardKey.Undo]; onActivated: root.undo() }
        Shortcut { sequences: [StandardKey.Redo, "Ctrl+Y"]; onActivated: root.redo() }

        // left: profile list
        Rectangle {
            id: side
            anchors { left: parent.left; top: parent.top; bottom: parent.bottom }
            width: 190; color: root.cPanel
            Text { x: 14; y: 14; text: "Profiles"; color: root.cDim; font.pixelSize: 12 }
            ListView {
                anchors { fill: parent; topMargin: 40; bottomMargin: 8 }
                model: root.profiles; clip: true
                delegate: Rectangle {
                    width: ListView.view.width; height: 34
                    color: modelData.name === root.current ? root.cLine : "transparent"
                    Text {
                        anchors { verticalCenter: parent.verticalCenter; left: parent.left; leftMargin: 14 }
                        text: modelData.name + (modelData.name === root.activeName ? "  ●" : "") + (modelData.builtin ? "" : "  ✎")
                        color: modelData.name === root.current ? root.cAccent : root.cText; font.pixelSize: 14
                    }
                    MouseArea { anchors.fill: parent; onClicked: root.select(modelData.name) }
                }
            }
        }

        // top: live readout
        Row {
            id: live
            anchors { left: side.right; leftMargin: 20; top: parent.top; topMargin: 14 }
            spacing: 26
            Repeater {
                model: [
                    ["CPU", isNaN(root.st.cpu) || root.st.cpu === null ? "-" : root.st.cpu.toFixed(0) + " °C"],
                    ["Liquid", isNaN(root.st.liquid) ? "-" : root.st.liquid.toFixed(1) + " °C"],
                    ["Pump", root.st.pump_rpm + " rpm (" + root.st.pump_duty + "%)"],
                    ["Fan", root.st.fan_rpm + " rpm (" + root.st.fan_duty + "%)"]
                ]
                delegate: Column {
                    Text { text: modelData[0]; color: root.cDim; font.pixelSize: 11 }
                    Text { text: modelData[1]; color: root.cText; font.pixelSize: 15 }
                }
            }
        }

        // fan curve graph
        Canvas {
            id: canvas
            anchors { left: side.right; leftMargin: 20; top: live.bottom; topMargin: 14; right: parent.right; rightMargin: 20 }
            height: 300
            readonly property int pl: 40; readonly property int pb: 26; readonly property int pt: 8; readonly property int pr: 10
            function px(t) { return pl + (t - root.tMin) / (root.tMax - root.tMin) * (width - pl - pr) }
            function py(d) { return pt + (100 - d) / 100 * (height - pt - pb) }
            function tx(x) { return Math.round(root.tMin + (x - pl) / (width - pl - pr) * (root.tMax - root.tMin)) }
            function dy(y) { return Math.round(100 - (y - pt) / (height - pt - pb) * 100) }
            onPaint: {
                var c = getContext("2d"); c.reset()
                c.fillStyle = root.cPanel; c.fillRect(0, 0, width, height)
                c.strokeStyle = root.cLine; c.fillStyle = root.cDim; c.font = "11px sans-serif"; c.lineWidth = 1
                for (var d = 0; d <= 100; d += 20) { c.beginPath(); c.moveTo(pl, py(d)); c.lineTo(width - pr, py(d)); c.stroke(); c.fillText(d + "%", 6, py(d) + 4) }
                for (var t = root.tMin; t <= root.tMax; t += 5) { c.beginPath(); c.moveTo(px(t), pt); c.lineTo(px(t), height - pb); c.stroke(); c.fillText(t + "°", px(t) - 8, height - 8) }
                var p = root.points
                c.strokeStyle = root.cAccent; c.lineWidth = 2; c.beginPath()
                c.moveTo(px(root.tMin), py(p[0][1])); c.lineTo(px(p[0][0]), py(p[0][1]))
                for (var i = 1; i < p.length; i++) c.lineTo(px(p[i][0]), py(p[i][1]))
                c.lineTo(px(root.tMax), py(p[p.length-1][1])); c.stroke()
                if (!isNaN(root.st.liquid)) {
                    c.strokeStyle = root.cDim; c.setLineDash([4, 4]); c.beginPath()
                    c.moveTo(px(root.st.liquid), pt); c.lineTo(px(root.st.liquid), height - pb); c.stroke(); c.setLineDash([])
                }
                for (var j = 0; j < p.length; j++) {
                    c.beginPath(); c.arc(px(p[j][0]), py(p[j][1]), j === root.sel ? 7 : 5, 0, 6.2832)
                    c.fillStyle = j === root.sel ? root.cText : root.cAccent; c.fill()
                }
            }
            MouseArea {
                anchors.fill: parent
                acceptedButtons: Qt.LeftButton | Qt.RightButton
                property int drag: -1
                function nearest(x, y) {
                    var best = -1, bd = 14 * 14
                    root.points.forEach((p, i) => { var dx = canvas.px(p[0]) - x, dy = canvas.py(p[1]) - y; if (dx*dx + dy*dy < bd) { bd = dx*dx + dy*dy; best = i } })
                    return best
                }
                onPressed: mouse => {
                    var i = nearest(mouse.x, mouse.y); root.sel = i
                    if (mouse.button === Qt.RightButton && i >= 0 && root.points.length > 1) {
                        root.points.splice(i, 1); root.sel = -1; root.touch()
                    } else if (mouse.button === Qt.LeftButton) drag = i
                    canvas.requestPaint()
                }
                onDoubleClicked: mouse => {
                    if (nearest(mouse.x, mouse.y) >= 0 || root.points.length >= 10) return
                    var t = root.clamp(canvas.tx(mouse.x), root.tMin, root.tMax)
                    if (root.points.some(p => p[0] === t)) return
                    root.points.push([t, root.clamp(canvas.dy(mouse.y), 0, 100)])
                    root.points.sort((a, b) => a[0] - b[0]); root.sel = root.points.findIndex(p => p[0] === t); root.touch()
                }
                onPositionChanged: mouse => {
                    if (drag < 0) return
                    var p = root.points, lo = drag > 0 ? p[drag-1][0] + 1 : root.tMin, hi = drag < p.length - 1 ? p[drag+1][0] - 1 : root.tMax
                    p[drag] = [root.clamp(canvas.tx(mouse.x), lo, hi), root.clamp(canvas.dy(mouse.y), 0, 100)]
                    root.touch()
                }
                onReleased: drag = -1
            }
        }

        Text {
            id: hint
            anchors { left: canvas.left; top: canvas.bottom; topMargin: 4 }
            text: "Drag points · double-click to add · right-click to delete · dashed line = current liquid temperature"
            color: root.cDim; font.pixelSize: 11
        }

        // controls
        Row {
            id: controls
            anchors { left: canvas.left; top: hint.bottom; topMargin: 14 }
            spacing: 14
            Text { text: "Pump"; color: root.cDim; font.pixelSize: 13; anchors.verticalCenter: parent.verticalCenter }
            Rectangle {
                id: track; width: 220; height: 28; color: "transparent"; anchors.verticalCenter: parent.verticalCenter
                Rectangle { anchors.verticalCenter: parent.verticalCenter; width: parent.width; height: 4; radius: 2; color: root.cLine }
                Rectangle { anchors.verticalCenter: parent.verticalCenter; width: (root.pump - 20) / 80 * parent.width; height: 4; radius: 2; color: root.cAccent }
                Rectangle { x: (root.pump - 20) / 80 * parent.width - 8; anchors.verticalCenter: parent.verticalCenter; width: 16; height: 16; radius: 8; color: root.cText }
                MouseArea {
                    anchors.fill: parent
                    function set(x) { root.pump = root.clamp(Math.round(20 + x / width * 80), 20, 100); root.touch() }
                    onPressed: mouse => set(mouse.x)
                    onPositionChanged: mouse => set(mouse.x)
                }
            }
            Num { value: root.pump; lo: 20; hi: 100; suffix: "%"; onEdited: v => { root.pump = v; root.touch() } }
            Text { text: "Point"; color: root.cDim; font.pixelSize: 13; anchors.verticalCenter: parent.verticalCenter }
            Num {
                value: root.sel >= 0 ? root.points[root.sel][0] : 0; lo: root.tMin; hi: root.tMax; suffix: "°"; editable: root.sel >= 0
                onEdited: v => {
                    var p = root.points, i = root.sel, lo = i > 0 ? p[i-1][0] + 1 : root.tMin, hi = i < p.length - 1 ? p[i+1][0] - 1 : root.tMax
                    p[i] = [root.clamp(v, lo, hi), p[i][1]]; root.touch()
                }
            }
            Num {
                value: root.sel >= 0 ? root.points[root.sel][1] : 0; lo: 0; hi: 100; suffix: "%"; editable: root.sel >= 0
                onEdited: v => { root.points[root.sel] = [root.points[root.sel][0], v]; root.touch() }
            }
        }

        Row {
            id: actions
            anchors { left: canvas.left; top: controls.bottom; topMargin: 14 }
            spacing: 10
            Btn { label: "Undo"; enabledBtn: root.undoStack.length > 0; onClicked: root.undo() }
            Btn { label: "Redo"; enabledBtn: root.redoStack.length > 0; onClicked: root.redo() }
            Btn { label: "Revert"; enabledBtn: root.dirty; onClicked: root.revert() }
            Btn { label: "Apply"; primary: true; enabledBtn: root.errors.length === 0; onClicked: root.apply() }
            Rectangle {
                width: 170; height: 30; radius: 6; color: root.cBg; border.color: nameIn.activeFocus ? root.cAccent : root.cLine
                TextInput {
                    id: nameIn; anchors { fill: parent; margins: 6 } color: root.cText; font.pixelSize: 13; verticalAlignment: TextInput.AlignVCenter
                    text: root.nameField; onTextEdited: root.nameField = text
                }
            }
            Btn { label: "Save"; enabledBtn: root.errors.length === 0; onClicked: root.save(false) }
            Btn { label: "Save & Activate"; enabledBtn: root.errors.length === 0; onClicked: root.save(true) }
            Btn {
                label: "Delete"; enabledBtn: !root.builtin
                onClicked: { pDelete.command = ["kraken-profile", "delete", root.current]; pDelete.running = true }
            }
        }

        Column {
            anchors { left: canvas.left; right: canvas.right; top: actions.bottom; topMargin: 12 }
            spacing: 3
            Text { visible: root.dirty; text: "Unsaved changes in " + root.current + (root.builtin ? " (built-in, save under a new name)" : ""); color: root.cDim; font.pixelSize: 12 }
            Repeater { model: root.errors; delegate: Text { text: "✕ " + modelData; color: root.cWarn; font.pixelSize: 12 } }
            Repeater { model: root.warns; delegate: Text { text: "⚠ " + modelData; color: root.cAccent; font.pixelSize: 12 } }
            Text { visible: root.note !== ""; text: root.note; color: root.cText; font.pixelSize: 12; wrapMode: Text.Wrap; width: parent.width }
        }
    }
}
