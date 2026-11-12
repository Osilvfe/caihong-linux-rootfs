import QtQuick
import QtQuick.Layouts
import org.kde.plasma.plasmoid
import org.kde.plasma.components as PC3
import org.kde.plasma.plasma5support as P5Support
import org.kde.kirigami as Kirigami

PlasmoidItem {
    id: root

    property int level: 0
    property int lastOn: 40
    readonly property bool lit: level > 0
    readonly property string cmd: "/usr/local/sbin/caihong-flashlight"

    // Only one script invocation may run at a time. While it runs, newer
    // requests replace pendingLevel, so a slider drag never builds a backlog
    // of stale on/off commands.
    property bool busy: false
    property int pendingLevel: -1
    property bool dragging: false
    property int generation: 0
    property int pollGeneration: -1

    Plasmoid.icon: lit ? "flashlight-on" : "flashlight-off"
    toolTipMainText: "Flashlight"
    toolTipSubText: lit ? level + "%" : "Off"

    function clampLevel(v) {
        return Math.max(0, Math.min(100, Math.round(v)))
    }

    function setLevel(v) {
        v = clampLevel(v)
        if (v === level)
            return
        generation++
        level = v
        if (v > 0)
            lastOn = v
        pendingLevel = v
        pump()
    }

    function pump() {
        if (busy || pendingLevel < 0)
            return
        var v = pendingLevel
        pendingLevel = -1
        busy = true
        act.connectSource(v > 0 ? cmd + " on " + v : cmd + " off")
    }

    function refresh() {
        // Never let a poll race a user action or a slider drag.
        if (busy || pendingLevel >= 0 || dragging)
            return
        pollGeneration = generation
        poll.connectSource(cmd + " status")
    }

    P5Support.DataSource {
        id: act
        engine: "executable"
        onNewData: (src, data) => {
            disconnectSource(src)
            root.busy = false
            root.pump()
        }
    }

    P5Support.DataSource {
        id: poll
        engine: "executable"
        onNewData: (src, data) => {
            disconnectSource(src)
            // Discard results that started before the latest user action.
            if (root.pollGeneration !== root.generation || root.busy || root.dragging)
                return
            var out = (data && data.stdout) ? data.stdout : ""
            var m = out.match(/brightness=(\d+)/)
            if (m) {
                root.level = Math.round(parseInt(m[1]) * 100 / 255)
                if (root.level > 0)
                    root.lastOn = root.level
                return
            }
            var mode = out.match(/led_mode:\s*(\d+)/)
            var inten = out.match(/intensity_torch_mode:\s*(\d+)/)
            if (mode && inten) {
                let lv = parseInt(mode[1]) === 2
                    ? Math.max(1, Math.round(parseInt(inten[1]) * 100 / 500000))
                    : 0
                // The driver quantizes intensity, so do not make the slider
                // jump by a percent or two after each reconcile. Turning off
                // must always win.
                if (lv > 0 && Math.abs(lv - root.level) <= 2)
                    return
                root.level = lv
                if (lv > 0)
                    root.lastOn = lv
            }
        }
    }

    // Reconcile with the hardware only when idle; user actions always win.
    Timer {
        interval: 15000
        running: true
        repeat: true
        triggeredOnStart: true
        onTriggered: root.refresh()
    }

    onExpandedChanged: {
        if (expanded)
            root.refresh()
    }

    fullRepresentation: ColumnLayout {
        Layout.minimumWidth: Kirigami.Units.gridUnit * 15
        spacing: Kirigami.Units.largeSpacing

        PC3.Switch {
            Layout.fillWidth: true
            text: "Flashlight"
            checked: root.lit
            onToggled: root.setLevel(checked ? root.lastOn : 0)
        }

        RowLayout {
            Layout.fillWidth: true
            Kirigami.Icon {
                source: "brightness-low"
                implicitWidth: Kirigami.Units.iconSizes.small
                implicitHeight: implicitWidth
            }
            PC3.Slider {
                Layout.fillWidth: true
                from: 1
                to: 100
                stepSize: 1
                value: Math.max(1, root.level)
                onMoved: root.setLevel(value)
                onPressedChanged: {
                    root.dragging = pressed
                    if (!pressed && value !== root.level)
                        root.setLevel(value)
                }
            }
            PC3.Label {
                text: root.level + "%"
                Layout.minimumWidth: Kirigami.Units.gridUnit * 2
                horizontalAlignment: Text.AlignRight
            }
        }
    }
}
