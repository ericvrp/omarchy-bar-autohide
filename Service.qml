import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import QtQuick

Item {
  id: root

  readonly property int revealThickness: 1
  readonly property int defaultHideDelayMs: 200
  readonly property int hideDelayMs: root.configuredHideDelay()

  readonly property string configHome: Quickshell.env("XDG_CONFIG_HOME")
    || Quickshell.env("HOME") + "/.config"
  property string toggleDir: Quickshell.env("HOME") + "/.local/state/omarchy/toggles"
  property string barOffFile: toggleDir + "/bar-off"
  readonly property string runtimeBaseDir: Quickshell.env("XDG_RUNTIME_DIR")
    || Quickshell.env("XDG_CACHE_HOME")
    || Quickshell.env("HOME") + "/.cache"
  readonly property string intentFilePath: leaseId
    ? runtimeBaseDir + "/ericvrp.bar-autohide." + leaseId + ".intent" : ""
  readonly property string operationFilePath: runtimeBaseDir + "/ericvrp.bar-autohide.operation"
  readonly property string acknowledgementFilePath: runtimeBaseDir + "/ericvrp.bar-autohide.ack"
  readonly property string currentOwnerPath: runtimeBaseDir + "/ericvrp.bar-autohide.current"
  readonly property string journalFilePath: runtimeBaseDir + "/ericvrp.bar-autohide.journal"
  readonly property string lockFilePath: runtimeBaseDir + "/ericvrp.bar-autohide.lock"
  property var shell: null
  property int requestRevision: 0
  property bool intentWriteSucceeded: false
  property bool ownerWriteSucceeded: false
  property string leaseId: ""
  property bool acquired: false
  property bool closing: false
  property bool autoRevealed: false
  property bool edgeHovered: false
  property var barHoverObservers: []
  property bool barSurfaceHovered: false
  property bool pointerInBarBand: false
  readonly property var bar: shell ? shell.bar : null
  readonly property string position: bar ? bar.position : "top"
  readonly property bool vertical: position === "left" || position === "right"
  readonly property bool barHidden: bar ? bar.barHidden : true
  readonly property bool centerSectionHovered: bar && "centerSectionHovered" in bar
    ? bar.centerSectionHovered : false
  readonly property bool barHovered: barSurfaceHovered || centerSectionHovered || pointerInBarBand
  // Omarchy 4.0.3+ injects PluginBarStateApi (scalars only) into third-party
  // services. `undefined !== null` is true, so the old check pinned the bar open.
  readonly property bool popoutOpen: !!(bar && bar.activePopout)
  readonly property bool canObserveBarSurfaces: !!(bar && "data" in bar)
  FileView {
    id: shellConfig

    path: root.configHome + "/omarchy/shell.json"
    blockLoading: true
    printErrors: false
  }

  FileView {
    id: stateIntent

    path: root.intentFilePath
    preload: false
    atomicWrites: true
    blockWrites: true
    printErrors: false
    onSaved: root.intentWriteSucceeded = true
    onSaveFailed: function(error) {
      root.intentWriteSucceeded = false
      console.warn("bar-autohide: failed to publish bar state intent:", error)
    }
  }

  FileView {
    id: currentOwner

    path: root.currentOwnerPath
    preload: false
    atomicWrites: true
    blockWrites: true
    printErrors: false
    onSaved: root.ownerWriteSucceeded = true
    onSaveFailed: function(error) {
      root.ownerWriteSucceeded = false
      console.warn("bar-autohide: failed to publish current owner:", error)
    }
  }

  FileView {
    id: writerOperation

    path: root.operationFilePath
    preload: false
    blockAllReads: true
    printErrors: false
  }

  // Watch the existing parent: the operation file does not exist on first use.
  FileView {
    path: root.runtimeBaseDir
    watchChanges: true
    printErrors: false
    onFileChanged: operationAckTimer.restart()
  }

  FileView {
    id: writerAcknowledgement

    path: root.acknowledgementFilePath
    preload: false
    atomicWrites: true
    blockWrites: true
    blockAllReads: true
    printErrors: false
    onSaveFailed: function(error) {
      console.warn("bar-autohide: failed to acknowledge bar state operation:", error)
    }
  }

  FileView {
    id: barStateWriter

    path: Qt.resolvedUrl("./scripts/bar-state-writer.sh")
    blockLoading: true
    printErrors: false
  }

  function configuredHideDelay() {
    let config
    try {
      config = JSON.parse(shellConfig.text())
    } catch (error) {
      console.warn("bar-autohide: invalid shell.json; using the default hide delay")
      return root.defaultHideDelayMs
    }

    if (!config || typeof config !== "object" || Array.isArray(config)
        || !Array.isArray(config.plugins)) {
      console.warn("bar-autohide: invalid plugin configuration; using the default hide delay")
      return root.defaultHideDelayMs
    }

    if (config.plugins.some(entry => !entry || typeof entry !== "object"
        || Array.isArray(entry))) {
      console.warn("bar-autohide: invalid plugin entries; using the default hide delay")
      return root.defaultHideDelayMs
    }

    const matches = config.plugins.filter(entry => entry.id === "ericvrp.bar-autohide")
    if (matches.length === 0) return root.defaultHideDelayMs
    if (matches.length !== 1) {
      console.warn("bar-autohide: duplicate plugin entries; using the default hide delay")
      return root.defaultHideDelayMs
    }

    const value = matches[0].hideDelayMs
    if (value === undefined) return root.defaultHideDelayMs
    if (typeof value !== "number" || !Number.isInteger(value)) {
      console.warn("bar-autohide: hideDelayMs must be an integer; using the default")
      return root.defaultHideDelayMs
    }
    return Math.max(0, Math.min(5000, value))
  }

  function createLeaseId() {
    return "xxxxxxxxxxxx4xxxyxxxxxxxxxxxxxxx".replace(/[xy]/g, function(c) {
      const random = Math.floor(Math.random() * 16)
      return (c === "x" ? random : (random & 3) | 8).toString(16)
    })
  }

  function requestBarState(state) {
    if (root.closing && state !== "closed") return
    if (!root.leaseId) root.leaseId = root.createLeaseId()
    root.intentWriteSucceeded = false
    root.requestRevision += 1
    const observedState = root.bar && root.bar.barHidden ? "hidden" : "visible"
    stateIntent.setText(String(root.requestRevision) + ":" + state + ":" + observedState)
    if (!root.intentWriteSucceeded) return

    if (!root.acquired) {
      root.ownerWriteSucceeded = false
      currentOwner.setText(root.leaseId)
      if (!root.ownerWriteSucceeded) return
      root.acquired = true
    }

    const writer = String(barStateWriter.text() || "")
    if (!writer) {
      console.warn("bar-autohide: state writer is unavailable")
      return
    }
    Quickshell.execDetached(["bash", "-c", writer, "bar-state-writer",
      root.runtimeBaseDir, root.currentOwnerPath, root.journalFilePath,
      root.lockFilePath, root.barOffFile, root.operationFilePath,
      root.acknowledgementFilePath])
  }

  function acknowledgeOperation(actualState) {
    writerOperation.reload()
    writerOperation.waitForJob()
    const operation = String(writerOperation.text() || "").trim().split(":")
    if (operation.length !== 5 || !/^[0-9a-fA-F]{32}$/.test(operation[0])
        || !/^[0-9]+$/.test(operation[1])
        || !/^[0-9]+$/.test(operation[2])
        || (operation[3] !== "hidden" && operation[3] !== "visible")
        || !["preparing", "closing-preparing", "waiting", "closing"].includes(operation[4])) return false

    const token = operation.slice(0, 4).join(":")
    writerAcknowledgement.reload()
    writerAcknowledgement.waitForJob()
    // Duplicate host notifications still belong to this operation. Do not
    // publish them as manual intent over a newer queued reveal/hide request.
    if (String(writerAcknowledgement.text() || "").trim() === token)
      return operation[3] === actualState

    writerAcknowledgement.setText(token)
    writerAcknowledgement.waitForJob()
    return operation[3] === actualState
  }

  function acknowledgeObservedOperation() {
    if (!root.bar || root.closing) return true
    const actualState = root.bar.barHidden ? "hidden" : "visible"
    writerOperation.reload()
    writerOperation.waitForJob()
    const operation = String(writerOperation.text() || "").trim().split(":")
    if (operation.length !== 5
        || (operation[4] !== "waiting" && operation[4] !== "closing")) return true
    if (operation[3] !== actualState) return false
    root.acknowledgeOperation(actualState)
    return true
  }

  // A probe that reports an unchanged state emits no barHiddenChanged signal.
  // Observe it only while an operation is pending, never as an idle poll.
  Timer {
    id: operationAckTimer
    interval: 50
    repeat: true
    onTriggered: {
      if (root.acknowledgeObservedOperation()) stop()
    }
  }

  onBarSurfaceHoveredChanged: {
    if (bar && typeof bar.setCenterSectionHovered === "function")
      bar.setCenterSectionHovered(barSurfaceHovered)
  }

  function refreshBarSurfaceHovered() {
    for (const observer of barHoverObservers) {
      if (observer && observer.hovered) {
        barSurfaceHovered = true
        return
      }
    }
    barSurfaceHovered = false
  }

  function removeBarHoverObserver(observer) {
    if (root.closing) return
    barHoverObservers = barHoverObservers.filter(candidate => candidate !== observer)
    refreshBarSurfaceHovered()
  }

  function observeBarPanels() {
    if (!bar || !("data" in bar)) return

    const observedWindows = barHoverObservers.map(observer => observer.observedWindow)
    for (let i = 0; i < bar.data.length; ++i) {
      const variants = bar.data[i]
      if (!variants || !("instances" in variants)) continue

      for (let j = 0; j < variants.instances.length; ++j) {
        const window = variants.instances[j]
        if (!window || !("contentItem" in window) || !("screen" in window)
            || "ghostScreen" in window || observedWindows.includes(window)) continue

        const observer = barHoverObserverComponent.createObject(window.contentItem, {
          "observedWindow": window
        })
        if (observer) {
          barHoverObservers = barHoverObservers.concat([observer])
          observedWindows.push(window)
        }
      }
    }
  }

  function barThicknessFor(screenName) {
    let size = Number(bar && bar.barSize)
    if (bar && typeof bar.barSizeFor === "function") {
      const perScreenSize = Number(bar.barSizeFor(screenName))
      if (Number.isFinite(perScreenSize) && perScreenSize > 0)
        size = perScreenSize
    }
    if (!Number.isFinite(size) || size <= 0) size = 30
    return Math.max(1, size)
  }

  function cursorInBarBand(px, py) {
    const screens = Quickshell.screens || []
    for (let i = 0; i < screens.length; ++i) {
      const s = screens[i]
      if (!s) continue
      const sx = Number(s.x || 0)
      const sy = Number(s.y || 0)
      const sw = Number(s.width || 0)
      const sh = Number(s.height || 0)
      if (sw <= 0 || sh <= 0) continue
      if (px < sx || px >= sx + sw || py < sy || py >= sy + sh) continue
      const size = root.barThicknessFor(s.name)
      if (position === "top") return py < sy + size
      if (position === "bottom") return py >= sy + sh - size
      if (position === "left") return px < sx + size
      if (position === "right") return px >= sx + sw - size
    }
    return false
  }

  function hideBar() {
    if (!root.autoRevealed || !bar || bar.barHidden
        || root.edgeHovered || root.barHovered || root.popoutOpen) return
    root.autoRevealed = false
    root.pointerInBarBand = false
    root.requestBarState("hidden")
  }

  function showBar() {
    if (bar && bar.barHidden) {
      // The cursor probe path needs a seed while the reveal is sampled.
      // Event-based hosts already track the bar surface directly.
      if (!root.canObserveBarSurfaces)
        root.pointerInBarBand = true
      root.autoRevealed = true
      root.requestBarState("visible")
    }
  }

  Process {
    id: cursorProbe

    running: false
    command: ["hyprctl", "cursorpos"]
    stdout: StdioCollector {
      onStreamFinished: {
        if (!root.autoRevealed || root.barHidden) return
        const text = String(this.text || "").trim()
        const parts = text.split(",")
        const px = Number(parts[0])
        const py = Number(parts[1])
        // A sample without a position carries no answer. The next probe either
        // restores the state or confirms the exit; never run on stale data.
        if (parts.length < 2 || Number.isNaN(px) || Number.isNaN(py)) {
          root.pointerInBarBand = false
          return
        }
        root.pointerInBarBand = root.cursorInBarBand(px, py)
      }
    }
  }

  Timer {
    interval: 80
    repeat: true
    running: root.autoRevealed && !root.barHidden && !root.canObserveBarSurfaces
    onTriggered: {
      if (!cursorProbe.running)
        cursorProbe.running = true
    }
    onRunningChanged: {
      if (!running)
        root.pointerInBarBand = false
    }
  }

  Timer {
    interval: root.hideDelayMs
    running: root.autoRevealed && !root.barHidden
      && !root.edgeHovered && !root.barHovered && !root.popoutOpen
    onTriggered: root.hideBar()
  }

  Connections {
    target: root.bar
    function onBarHiddenChanged() {
      // Read the signal's source directly: root.barHidden's binding may not
      // have updated yet while this notification is being delivered.
      const actualState = root.bar.barHidden ? "hidden" : "visible"
      const acknowledged = root.acknowledgeOperation(actualState)
      if (acknowledged) return
      if (root.closing) return

      if (actualState === "hidden") {
        root.autoRevealed = false
        root.pointerInBarBand = false
      }
      root.requestBarState(actualState)
    }
  }

  Connections {
    target: Quickshell
    function onScreensChanged() { Qt.callLater(root.observeBarPanels) }
  }

  Component {
    id: barHoverObserverComponent

    Item {
      required property var observedWindow
      readonly property alias hovered: wholeBarHover.hovered

      anchors.fill: parent
      z: 1000000

      HoverHandler {
        id: wholeBarHover
        blocking: false
        onHoveredChanged: root.refreshBarSurfaceHovered()
      }

      Component.onDestruction: root.removeBarHoverObserver(this)
    }
  }

  BarTransitionBackground {
    barHidden: root.barHidden
    position: root.position
    barConfig: root.shell && root.shell.barConfig ? root.shell.barConfig : ({})
    thicknessForScreen: root.barThicknessFor
  }

  Variants {
    model: Quickshell.screens

    delegate: Component {
      PanelWindow {
        required property var modelData

        screen: modelData
        visible: root.barHidden || root.autoRevealed
        color: "transparent"
        exclusionMode: ExclusionMode.Ignore
        implicitWidth: root.vertical ? root.revealThickness : 0
        implicitHeight: root.vertical ? 0 : root.revealThickness

        anchors {
          top: root.position === "top" || root.vertical
          bottom: root.position === "bottom" || root.vertical
          left: root.position === "left" || !root.vertical
          right: root.position === "right" || !root.vertical
        }

        WlrLayershell.namespace: "omarchy-bar-autohide-trigger"
        WlrLayershell.layer: WlrLayer.Overlay
        WlrLayershell.keyboardFocus: WlrKeyboardFocus.None

        HoverHandler {
          onHoveredChanged: {
            root.edgeHovered = hovered
            if (hovered) root.showBar()
          }
        }
      }
    }
  }

  Component.onDestruction: {
    root.closing = true
    operationAckTimer.stop()
    // Observers are parented to host windows, which outlive this service.
    for (const observer of root.barHoverObservers) {
      if (observer) observer.destroy()
    }
    root.barHoverObservers = []
    if (bar && typeof bar.setCenterSectionHovered === "function")
      bar.setCenterSectionHovered(false)
    root.requestBarState("closed")
  }

  onBarChanged: Qt.callLater(() => {
    operationAckTimer.restart()
    root.observeBarPanels()
  })

  Component.onCompleted: {
    operationAckTimer.restart()
    root.requestBarState("hidden")
    Qt.callLater(root.observeBarPanels)
  }
}
