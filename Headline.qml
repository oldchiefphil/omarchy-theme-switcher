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
  // Screen this banner maps on. null (the default) lets the compositor pick
  // the output, exactly like the stock picker (also without an explicit
  // screen) — so both end up under the same cursor/focus. The bar host pins
  // this to its own screen before showing.
  property var screenSurface: null

  // Frame spec for the strip. The stock "menu" surface drops its bottom
  // border (speech-bubble look); this headline is a closed banner, so the
  // theme's top border width is applied to all four sides. Color/gradient
  // stay theme-driven; with a solid color the renderer takes the native
  // Rectangle.border path.
  readonly property var _menuBorder: Border.surfaceSpec(
    "menu", "border", Color.menu.border, Math.max(1, Style.space(2)))
  // Border width used for the closed frame: the theme's top border width
  // (all four sides), falling back to the standard surface width.
  readonly property real _frameWidth: (function() {
    var w = root._menuBorder.widths.top
    return w > 0 ? w : Math.max(1, Style.space(2))
  })()
  // Frame spec for the strip. Two reasons for forcing a flat, uniform spec
  // here instead of reusing the theme's "menu" border verbatim:
  //   1. The stock "menu" surface drops its bottom border (speech-bubble
  //      look); this headline is a closed banner, so all four sides get the
  //      top border width.
  //   2. A gradient spec routes through BorderOverlay, whose compound ring
  //      path mis-renders at this size (the right side and bottom-right
  //      corner vanish). A flat spec takes the native Rectangle.border
  //      path, which draws a reliable full frame around the radius.
  readonly property var _frameSpec: (function() {
    var w = root._frameWidth
    return {
      color: root._menuBorder.color,
      gradient: { colors: [], angle: 0, enabled: false },
      widths: { top: w, right: w, bottom: w, left: w }
    }
  })()

  function show(message) {
    root.text = String(message || "")
    root.opened = true
  }

  function hide() {
    root.opened = false
  }

  PanelWindow {
    screen: root.screenSurface
    visible: root.opened && root.text !== ""
    anchors { top: true; left: true; right: true }
    // Full-fit height: topMargin + strip height + room for the border on
    // both edges. A height of exactly 76 previously clipped the bottom
    // border (14 + 64 + 2px of border overflowed the window bounds).
    implicitHeight: Style.space(128) + Style.space(64) + 2 * root._frameWidth
    color: "transparent"
    WlrLayershell.namespace: "omarchy-theme-switcher-headline"
    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.keyboardFocus: WlrKeyboardFocus.None
    exclusionMode: ExclusionMode.Ignore

    BorderSurface {
      anchors.horizontalCenter: parent.horizontalCenter
      anchors.top: parent.top
      anchors.topMargin: Style.space(128)
      width: Math.min(Style.space(520), parent.width - Style.space(48))
      height: Style.space(64)
      color: Color.menu.background
      borderSpec: root._frameSpec
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