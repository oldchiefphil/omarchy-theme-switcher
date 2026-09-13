import QtQuick
import qs.Commons
import qs.Ui

// One theme slot card: live preview thumbnail, theme name, active marker,
// and a Choose button that opens Omarchy's own image-grid theme picker.
// Styling comes from qs.Ui / qs.Commons so the card follows the theme.
Row {
  id: root

  property string slot: "light"
  property string themeName: ""
  property string previewSource: ""
  property bool isActive: false
  property color foreground: Color.foreground
  property string fontFamily: Style.font.family

  signal choose(string slot)

  spacing: Style.space(10)

  Rectangle {
    id: thumb
    width: Style.space(120)
    height: Style.space(68)
    radius: Style.cornerRadius
    color: Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.08)
    border.width: root.isActive ? Math.max(1, Style.space(2)) : 0
    border.color: root.isActive ? Style.selectedStateColor(root.foreground, Color.accent) : "transparent"

    Text {
      textFormat: Text.PlainText
      anchors.centerIn: parent
      visible: preview.status !== Image.Ready
      text: root.themeName.length > 0 ? root.themeName[0].toUpperCase() : "?"
      color: Qt.darker(root.foreground, 1.4)
      font.family: root.fontFamily
      font.pixelSize: Style.font.display
    }

    Image {
      id: preview
      anchors.fill: parent
      asynchronous: true
      cache: true
      fillMode: Image.PreserveAspectCrop
      source: root.previewSource
      visible: status === Image.Ready
    }
  }

  Column {
    width: parent.width - thumb.width - chooseBtn.width - 2 * parent.spacing
    anchors.verticalCenter: parent.verticalCenter
    spacing: Style.space(2)

    Text {
      textFormat: Text.PlainText
      width: parent.width
      text: root.themeName
      color: root.foreground
      font.family: root.fontFamily
      font.pixelSize: Style.font.body
      font.bold: true
      elide: Text.ElideRight
    }

    Text {
      textFormat: Text.PlainText
      visible: root.isActive
      width: parent.width
      text: "Active now"
      color: Style.selectedStateColor(root.foreground, Color.accent)
      font.family: root.fontFamily
      font.pixelSize: Style.font.bodySmall
      elide: Text.ElideRight
    }
  }

  Button {
    id: chooseBtn
    anchors.verticalCenter: parent.verticalCenter
    text: "Choose…"
    tooltipText: "Pick with Omarchy's theme gallery"
    bordered: true
    foreground: root.foreground
    fontFamily: root.fontFamily
    onClicked: root.choose(root.slot)
  }
}