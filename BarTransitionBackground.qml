import Quickshell
import Quickshell.Hyprland
import Quickshell.Wayland
import QtQuick
import qs.Commons as Commons

Item {
  id: root

  property bool barHidden: true
  property string position: "top"
  property var barConfig: ({})
  required property var thicknessForScreen

  readonly property bool vertical: position === "left" || position === "right"
  readonly property bool opaque: (barConfig.background
    || (barConfig.transparent === true ? "none" : "opaque")) === "opaque"
  readonly property bool covering: opaque && (!barHidden || hideCoverTimer.running)
  readonly property int coverDurationMs: Math.max(50, Commons.Style.duration(300))

  function hasTiledWindow(workspace) {
    if (!workspace || !workspace.toplevels) return false
    const windows = workspace.toplevels.values
    for (const window of windows) {
      const state = window.lastIpcObject
      if (state && state.mapped !== false && !state.hidden
          && state.floating === false && !state.fullscreen) return true
    }
    return false
  }

  onBarHiddenChanged: {
    if (barHidden && opaque) hideCoverTimer.restart()
    else hideCoverTimer.stop()
  }

  Timer {
    id: hideCoverTimer
    // Allow the compositor's window expansion and the client's resize repaint
    // to finish. Even with animations off, the repaint needs a frame or two.
    interval: root.coverDurationMs
  }

  Variants {
    model: Quickshell.screens

    delegate: Component {
      PanelWindow {
        id: backgroundWindow
        required property var modelData

        readonly property int thickness: root.thicknessForScreen(modelData.name)
        readonly property var monitor: Hyprland.monitorFor(screen)
        readonly property bool hasExpandingWindow: root.hasTiledWindow(
          monitor ? monitor.activeWorkspace : null)
        screen: modelData
        visible: true
        // Keep the surface mapped so Hyprland does not fade it in/out. Only
        // its pixels change; it never reserves space or accepts input.
        // The surface must be alpha-capable from creation. Making an initially
        // opaque window transparent later can leave a black compositor strip.
        color: "transparent"
        surfaceFormat.opaque: false
        exclusionMode: ExclusionMode.Ignore
        mask: Region {}
        implicitWidth: root.vertical ? thickness : 0
        implicitHeight: root.vertical ? 0 : thickness

        Rectangle {
          anchors.fill: parent
          visible: root.covering && backgroundWindow.hasExpandingWindow
          color: Commons.Color.bar.background
        }

        anchors {
          top: root.position === "top" || root.vertical
          bottom: root.position === "bottom" || root.vertical
          left: root.position === "left" || !root.vertical
          right: root.position === "right" || !root.vertical
        }

        // Below application windows, above the wallpaper: expanding windows
        // cover this strip naturally, without us covering their content.
        WlrLayershell.namespace: "omarchy-bar-autohide-background"
        WlrLayershell.layer: WlrLayer.Bottom
        WlrLayershell.keyboardFocus: WlrKeyboardFocus.None
      }
    }
  }
}
