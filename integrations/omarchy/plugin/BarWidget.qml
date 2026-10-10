import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons as Commons

// Third-party bar item for Omarchy 4.0.4. Properties are ordinary so the
// shell can inject bar, moduleName, and settings. The widget reads a redacted
// display file and refreshes it by running the local collector. It does not
// write stock agent usage records and it does not switch accounts.
Item {
  id: root

  property QtObject bar: null
  property string moduleName: ""
  property var settings: ({})

  property var display: null
  property bool panelWired: false

  readonly property bool vertical: bar ? bar.vertical : false
  readonly property int barSize: bar && bar.barSize ? bar.barSize : Commons.Style.bar.sizeHorizontal
  readonly property bool attention: {
    if (!display || display.read_ok === false) return true
    var recommendation = display.recommendation
    if (!recommendation) return true
    return recommendation.freshness === "drift" || recommendation.freshness === "unknown"
  }
  readonly property string barLabel: {
    var recommendation = display ? display.recommendation : null
    if (vertical || !recommendation) return "qb"
    if (recommendation.freshness === "drift" || recommendation.freshness === "unknown") return "qb"
    if (recommendation.headroom_percent === null || recommendation.headroom_percent === undefined) return "qb"
    return Math.round(Number(recommendation.headroom_percent)) + "%"
  }
  readonly property string tooltipText: {
    var recommendation = display ? display.recommendation : null
    if (!recommendation) return "quotabot: no recommendation"
    var freshness = recommendation.freshness || "unknown"
    return "quotabot " + recommendation.provider + " " + freshness
  }
  readonly property string collectorPath: fileUrlToPath(Qt.resolvedUrl("collect.py"))
  readonly property string displayPath: stateDirectory() + "/omarchy-display.json"
  readonly property bool opened: panelLoader.item ? panelLoader.item.opened === true : false
  readonly property bool popoutSwitchClosing: panelLoader.item
    ? panelLoader.item.popoutSwitchClosing === true
    : false

  function setting(name, fallback) {
    var value = settings ? settings[name] : undefined
    return value === undefined || value === null ? fallback : value
  }

  function fileUrlToPath(url) {
    var text = String(url || "")
    if (text.indexOf("file://") === 0) text = text.substring(7)
    return decodeURIComponent(text)
  }

  function stateDirectory() {
    var override = Quickshell.env("QUOTABOT_OMARCHY_STATE_DIR")
    if (override && String(override).length > 0) return String(override)
    var xdg = Quickshell.env("XDG_STATE_HOME")
    if (xdg && String(xdg).length > 0) return String(xdg) + "/quotabot"
    return String(Quickshell.env("HOME") || "") + "/.local/state/quotabot"
  }

  function applyDisplay(raw) {
    var text = String(raw || "").trim()
    if (!text) return
    try {
      var parsed = JSON.parse(text)
      if (parsed && parsed.schema === "quotabot.omarchy.v1") display = parsed
    } catch (error) {
      return
    }
  }

  function injectPanel() {
    var target = panelLoader.item
    if (!target) return
    target.bar = Qt.binding(function() { return root.bar })
    target.anchorItem = button
    target.display = Qt.binding(function() { return root.display })
    target.refreshing = Qt.binding(function() { return refreshProcess.running })
    if (!panelWired && target.refreshRequested) {
      target.refreshRequested.connect(root.refresh)
      panelWired = true
    }
  }

  function open() {
    if (panelLoader.item) panelLoader.item.open()
  }

  function close() {
    if (panelLoader.item) panelLoader.item.close()
  }

  function togglePanel() {
    if (opened) close()
    else open()
  }

  function closeForPopoutSwitch() {
    if (panelLoader.item && panelLoader.item.closeForPopoutSwitch)
      panelLoader.item.closeForPopoutSwitch()
  }

  function refresh() {
    if (refreshProcess.running) return
    refreshProcess.running = true
  }

  onBarChanged: {
    injectPanel()
    if (bar && bar.registerClickTarget) bar.registerClickTarget(button)
  }

  onSettingsChanged: injectPanel()

  Component.onDestruction: {
    if (bar && bar.unregisterClickTarget) bar.unregisterClickTarget(button)
  }

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  IpcHandler {
    target: "blisspixel.quotabot"

    function refresh(): void { root.refresh() }
    function open(): void { root.open() }
    function close(): void { root.close() }
    function toggle(): void { root.togglePanel() }
  }

  FileView {
    id: displayFile
    path: root.displayPath
    watchChanges: true
    printErrors: false
    blockLoading: false
    onFileChanged: reload()
    onLoaded: root.applyDisplay(displayFile.text())
  }

  Process {
    id: refreshProcess
    command: ["python3", root.collectorPath, "refresh"]
    onExited: displayFile.reload()
  }

  Timer {
    interval: Math.max(30, Number(root.setting("refreshIntervalSec", 900))) * 1000
    running: true
    repeat: true
    triggeredOnStart: false
    onTriggered: root.refresh()
  }

  Loader {
    id: panelLoader
    active: true
    visible: false
    source: Qt.resolvedUrl("Panel.qml")
    onLoaded: {
      root.injectPanel()
      Qt.callLater(root.injectPanel)
    }
  }

  Item {
    id: button
    implicitWidth: Math.max(root.barSize, label.implicitWidth + Commons.Style.space(16))
    implicitHeight: root.barSize

    Text {
      id: label
      anchors.centerIn: parent
      color: root.attention
        ? (root.bar && root.bar.urgent ? root.bar.urgent : Commons.Color.urgent)
        : (root.bar && root.bar.foreground ? root.bar.foreground : Commons.Color.foreground)
      font.family: root.bar && root.bar.fontFamily ? root.bar.fontFamily : "monospace"
      font.pixelSize: Commons.Style.font.body
      text: root.barLabel
    }

    MouseArea {
      id: pointer
      anchors.fill: parent
      acceptedButtons: Qt.LeftButton | Qt.MiddleButton | Qt.RightButton
      hoverEnabled: true
      onEntered: {
        if (root.bar && root.bar.showTooltip) root.bar.showTooltip(button, root.tooltipText)
      }
      onExited: {
        if (root.bar && root.bar.hideTooltip) root.bar.hideTooltip(button)
      }
      onPressed: function(mouse) {
        if (mouse.button === Qt.MiddleButton) root.refresh()
        else if (mouse.button === Qt.LeftButton) root.togglePanel()
      }
    }
  }
}
