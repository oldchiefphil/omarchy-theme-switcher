import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui
import "Model.js" as Model

// Bar pill for the theme-switcher: a moon/sun icon (moon = dark theme)
// hosting the config popup and the switching engine.
//
// The engine lives here as a child (tailscale pattern) so inline
// shell.json settings flow straight through `settings`. Only the first
// live instance runs the timer — a bar exists per monitor.
BarWidget {
  id: root
  moduleName: "io.github.oldchiefphil.theme-switcher"

  // Moon when the dark theme is active or scheduled, sun for light.
  readonly property string pillIcon: switcher.desiredNow === "dark" ? "󰖔" : "󰖙"

  function isPrimaryInstance() {
    if (!root.bar || typeof root.bar.moduleWidgets !== "function") return true
    var items = root.bar.moduleWidgets(root.moduleName)
    if (!items || items.length === 0) return true
    return items[0] === root
  }

  property bool primary: true

  function refreshPrimary() {
    root.primary = root.isPrimaryInstance()
  }

  function refresh() {
    refreshPrimary()
    switcher.refresh()
    if (panelLoader.item && panelLoader.item.refresh) panelLoader.item.refresh()
  }

  // ---- Popup. Shape contract for shell summon/hide/toggle routing:
  //      Bar.findPanelWidget requires open/close/opened on the root.
  readonly property bool opened: panelLoader.item ? panelLoader.item.opened === true : false

  function open() {
    if (panelLoader.item) panelLoader.item.open()
  }

  function close() {
    if (panelLoader.item) panelLoader.item.close()
  }

  function togglePanel() {
    if (panelLoader.item) panelLoader.item.toggle()
  }

  readonly property bool popoutSwitchClosing: panelLoader.item ? panelLoader.item.popoutSwitchClosing === true : false

  function closeForPopoutSwitch() {
    if (panelLoader.item) panelLoader.item.closeForPopoutSwitch()
  }

  function injectPanel() {
    var target = panelLoader.item
    if (!target) return
    if ("bar" in target) target.bar = root.bar
    if ("settings" in target) target.settings = root.settings
    if ("anchorItem" in target) target.anchorItem = button
    if ("hostWidget" in target) target.hostWidget = root
    if ("switcher" in target) target.switcher = switcher
  }

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  onBarChanged: {
    injectPanel()
    refreshPrimary()
  }
  onSettingsChanged: injectPanel()

  Component.onCompleted: {
    refreshPrimary()
    primaryTimer.start()
  }

  Timer {
    id: primaryTimer
    interval: 30000
    repeat: true
    onTriggered: root.refreshPrimary()
  }

  Service {
    id: switcher
    settings: root.settings
    active: root.primary
  }

  Loader {
    id: panelLoader
    active: true
    source: Qt.resolvedUrl("Panel.qml")
    visible: false
    onLoaded: {
      root.injectPanel()
      Qt.callLater(root.injectPanel)
    }
  }

  // Slot headline shown above the stock theme picker while picking
  // ("Choose the LIGHT theme"). Slim top strip over empty scrim —
  // pointer and keyboard keep going to the picker underneath.
  Loader {
    id: headlineLoader
    active: true
    source: Qt.resolvedUrl("Headline.qml")
    visible: false
  }

  function showHeadline(message) {
    if (headlineLoader.item && headlineLoader.item.show) headlineLoader.item.show(message)
  }

  function hideHeadline() {
    if (headlineLoader.item && headlineLoader.item.hide) headlineLoader.item.hide()
  }

  IpcHandler {
    target: root.moduleName

    function refresh(): void { root.broadcast("refresh") }
    function open(): void { root.open() }
    function close(): void { root.close() }
    function show(): void { root.open() }
    function hide(): void { root.close() }
    function toggle(): void { root.togglePanel() }
    function switchToDark(): string { switcher.switchToDark(); return "ok" }
    function switchToLight(): string { switcher.switchToLight(); return "ok" }
    function toggleTheme(): string { switcher.toggle(); return "ok" }
    function status(): string { return switcher.status() }
    function pick(slot: string): string {
      if (panelLoader.item && panelLoader.item.chooseTheme) {
        panelLoader.item.chooseTheme(String(slot || ""))
        return "ok"
      }
      return "unknown"
    }
  }

  WidgetButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: root.vertical ? "" : root.pillIcon
    labelVisible: !root.vertical
    hasVisualContent: root.pillIcon !== ""
    horizontalMargin: 8.75
    verticalPadding: 8.75
    tooltipText: switcher.statusText
    opacity: switcher.enabled ? 1.0 : 0.5

    onPressed: function(b) {
      if (b === Qt.RightButton) switcher.toggle()
      else if (b === Qt.MiddleButton) root.refresh()
      else root.togglePanel()
    }
  }
}