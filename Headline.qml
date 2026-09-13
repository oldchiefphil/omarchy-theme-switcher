import QtQuick
import Quickshell
import Quickshell.Wayland
import qs.Commons
import qs.Ui

// Centered headline strip shown above the stock theme picker while a
// slot is being picked ("Choose the LIGHT theme"). A slim top-anchored
// strip (not fullscreen): the picker's carousel is vertically centered,
// so the strip only ever covers empty scrim. No MouseArea and no
// keyboard focus — pointer and keys keep going straight to the picker
// (Esc still cancels it). Hosted by BarWidget.qml through a Loader;
// shown after the picker mapped so it stacks on top.
Item {
  id: root

  property bool opened: false
  property string text: ""

  function show(message) {
    root.text = String(message || "")
    root.opened = true
  }

  function hide() {
    root.opened = false
  }

  PanelWindow {
    visible: root.opened && root.text !== ""
    anchors { top: true; left: true; right: true }
    implicitHeight: Style.space(76)
    color: "transparent"
    WlrLayershell.namespace: "omarchy-theme-switcher-headline"
    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.keyboardFocus: WlrKeyboardFocus.None
    exclusionMode: ExclusionMode.Ignore

    BorderSurface {
      anchors.horizontalCenter: parent.horizontalCenter
      anchors.top: parent.top
      anchors.topMargin: Style.space(14)
      width: Math.min(Style.space(520), parent.width - Style.space(48))
      height: Style.space(64)
      color: Color.menu.background
      borderSpec: Border.surfaceSpec("menu", "border", Color.menu.border, Math.max(1, Style.space(2)))
      radius: Style.cornerRadius

      Text {
        textFormat: Text.PlainText
        anchors.centerIn: parent
        width: parent.width - Style.spacing.popupPadding * 2
        horizontalAlignment: Text.AlignHCenter
        text: root.text
        color: Color.menu.text
        font.family: Style.font.menuFamily
        font.pixelSize: Style.font.title
        font.bold: true
        elide: Text.ElideRight
      }
    }
  }
}