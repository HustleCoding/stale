import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui

BarWidget {
  id: root
  moduleName: "stale"

  property string label: ""
  property string tooltip: "Stale"
  property bool warning: false

  function refresh() {
    if (!statusProc.running) statusProc.running = true
  }

  function apply(text) {
    try {
      const s = JSON.parse(String(text))
      root.label = "\uf0a0 " + s.text
      root.tooltip = s.tooltip
      root.warning = s["class"] !== "normal"
    } catch (e) {
      root.label = ""
    }
  }

  visible: label !== ""
  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  IpcHandler {
    target: "stale"

    function refresh(): void {
      root.broadcast("refresh")
    }
  }

  Process {
    id: statusProc
    command: ["stale", "status", "--waybar"]
    stdout: StdioCollector {
      onStreamFinished: root.apply(text)
    }
  }

  Process {
    id: rescanProc
    command: ["stale", "status", "--refresh", "--waybar"]
    stdout: StdioCollector {
      onStreamFinished: root.apply(text)
    }
  }

  Timer {
    interval: 300000
    running: true
    repeat: true
    triggeredOnStart: true
    onTriggered: root.refresh()
  }

  WidgetButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: root.label
    fontSize: Style.font.caption
    horizontalMargin: 6
    active: root.warning
    tooltipText: root.tooltip
    onPressed: function(mouseButton) {
      if (mouseButton === Qt.RightButton) {
        if (!rescanProc.running) rescanProc.running = true
      } else if (root.bar) {
        root.bar.run("stale-omarchy launch")
      }
    }
  }
}
