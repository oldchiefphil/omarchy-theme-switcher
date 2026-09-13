import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui
import "Model.js" as Model

// Settings panel for the theme-switcher, following the Bluetooth/Wi-Fi
// hero + sections pattern:
//
//   1. Hero …. current status (sun/moon) + master on/off switch
//   2. Status …. active theme, next scheduled switch
//   3. Schedule . sun elevation (or fixed times)
//   4. Location . Omarchy location or manual coordinates
//   5. Themes …. light + dark pickers (Omarchy's own theme gallery)
//   6. Quick switch "Light now" / "Dark now" (temporary override)
//
// Styling comes entirely from qs.Ui / qs.Commons (PanelHero, Dropdown,
// ButtonGroup, TextField, ToggleSwitch, Style, Color), so the panel
// follows the active Omarchy theme with no extra code.
Panel {
  id: root
  moduleName: "io.github.oldchiefphil.theme-switcher"
  ipcTarget: "io.github.oldchiefphil.theme-switcher"
  manageIpc: false

  property var anchorItem: null
  property var hostWidget: null
  property var switcher: null
  readonly property var barIdentity: hostWidget || root

  readonly property color contentForeground: bar ? bar.foreground : Color.foreground
  readonly property string contentFontFamily: bar ? bar.fontFamily : Style.font.family

  // ---- Effective settings (same fallbacks as Service.qml) ----
  readonly property string effMode: {
    var m = String(setting("mode", "sun"))
    return (m === "fixed") ? "fixed" : "sun"
  }
  readonly property string effDarkTheme: {
    var v = String(setting("darkTheme", "") || "")
    return v !== "" ? v : "Tokyo Night"
  }
  readonly property string effLightTheme: {
    var v = String(setting("lightTheme", "") || "")
    return v !== "" ? v : "Catppuccin Latte"
  }
  readonly property bool effAutoLocation: {
    var v = setting("useAutoLocation", true)
    if (v === true || v === 1) return true
    if (v === false || v === 0) return false
    return String(v).toLowerCase() === "true"
  }
  readonly property real effElevation: {
    var v = parseFloat(String(setting("sunElevation", 0)))
    return isFinite(v) ? v : 0
  }
  readonly property bool effEnabled: {
    var v = setting("enabled", true)
    if (v === true || v === 1) return true
    if (v === false || v === 0) return false
    return String(v).toLowerCase() === "true"
  }

  // preview slug -> filename in Omarchy's theme preview cache
  property var previewFiles: ({})
  // Slot ("dark"/"light") currently being picked in the stock gallery.
  property string pickingSlot: ""

  readonly property string pickerScript: String(Qt.resolvedUrl("pick-theme.sh")).replace(/^file:\/\//, "")

  function previewCacheDir() {
    var xdg = Quickshell.env("XDG_CACHE_HOME")
    var base = (xdg && xdg !== "") ? xdg : Quickshell.env("HOME") + "/.cache"
    return base + "/omarchy/theme-selector/previews"
  }

  function slugForTheme(name) {
    return Model.slugForTheme(name)
  }

  function previewSourceFor(displayName) {
    var file = previewFiles[slugForTheme(displayName)]
    if (!file) return ""
    return "file://" + previewCacheDir() + "/" + file
  }

  function slotTheme(slot) {
    return slot === "dark" ? effDarkTheme : effLightTheme
  }

  // ---- Lifecycle ----
  function open() {
    syncFields()
    loadPreviews()
    if (switcher) switcher.refreshQuiet()
    root.controller.show()
  }

  function close() {
    root.controller.hide()
  }

  function toggle() {
    if (root.opened) root.close()
    else root.open()
  }

  function switchPanel(direction) {
    if (root.bar && typeof root.bar.switchPanelFrom === "function")
      return root.bar.switchPanelFrom(root.barIdentity, direction)
    return false
  }

  function refresh() {
    syncFields()
    loadPreviews()
  }

  // Applied locally first so the panel redraws on the click itself; the
  // shell.json write comes back through the bar as the same value.
  function persistSettings(values) {
    var entry = { id: root.moduleName }
    for (var existing in root.settings) if (existing !== "id") entry[existing] = root.settings[existing]
    for (var key in values) entry[key] = values[key]
    // Minute offsets were replaced by the sun elevation angle; drop the
    // legacy keys so they don't linger in shell.json.
    if ("offsetSunriseMin" in entry) delete entry.offsetSunriseMin
    if ("offsetSunsetMin" in entry) delete entry.offsetSunsetMin

    root.settings = entry
    if (root.hostWidget && "settings" in root.hostWidget) root.hostWidget.settings = entry
    if (root.bar && root.bar.shell && typeof root.bar.shell.updateEntryInline === "function")
      root.bar.shell.updateEntryInline(root.moduleName, entry)
    syncFields()
  }

  // Text inputs are assigned (never bound) so typing cannot fight the
  // settings round-trip; syncFields runs on open, on settings change,
  // and after every commit.
  function syncFields() {
    fixedLightField.text = String(setting("fixedLightTime", "07:00"))
    fixedDarkField.text = String(setting("fixedDarkTime", "19:00"))
    elevationField.text = String(setting("sunElevation", 0))
    locationNameField.text = String(setting("locationName", "") || "")
    latitudeField.text = String(setting("latitude", "") || "")
    longitudeField.text = String(setting("longitude", "") || "")
  }

  function commitTime(field, key) {
    var minutes = Model.parseTimeToMinutes(field.text)
    if (minutes === null) {
      syncFields()
      return
    }
    var normalized = Model.minutesToTimeString(minutes)
    var values = {}
    values[key] = normalized
    persistSettings(values)
  }

  function commitElevation() {
    var v = parseFloat(String(elevationField.text || "").replace(",", "."))
    if (!isFinite(v)) {
      syncFields()
      return
    }
    if (v < -18) v = -18
    if (v > 18) v = 18
    persistSettings({ sunElevation: Math.round(v * 10) / 10 })
  }

  function commitLocation() {
    var lat = String(latitudeField.text || "").replace(/^\s+|\s+$/g, "")
    var lon = String(longitudeField.text || "").replace(/^\s+|\s+$/g, "")
    if ((lat !== "" && Model.parseCoord(lat) === null)
        || (lon !== "" && Model.parseCoord(lon) === null)) {
      syncFields()
      return
    }
    persistSettings({
      locationName: String(locationNameField.text || ""),
      latitude: lat,
      longitude: lon
    })
  }

  function loadPreviews() {
    if (!previewListProc.running) {
      previewListProc.command = ["bash", "-c",
        "ls -1 " + Util.shellQuote(previewCacheDir()) + " 2>/dev/null"]
      previewListProc.running = true
    }
  }

  function parsePreviewList(raw) {
    root.previewFiles = Model.parsePreviewList(raw)
  }

  function nextSwitchText() {
    if (!switcher || switcher.mode === "manual")
      return "Automatic switching is off"
    if (!switcher.nextAt || isNaN(switcher.nextAt.getTime()))
      return "No next switch scheduled"
    var target = switcher.nextTarget === "dark" ? "Dark" : "Light"
    return "Next: " + target + " (" + switcher.nextTargetTheme + ")"
      + " at " + Model.formatTime(switcher.nextAt)
  }

  function scheduleSummaryText() {
    if (!effEnabled) return "Automatic switching is off"
    if (effMode === "fixed")
      return "Fixed — light " + String(setting("fixedLightTime", "07:00"))
        + ", dark " + String(setting("fixedDarkTime", "19:00"))
    var suffix = (switcher && !switcher.sunAvailable) ? " (no coordinates, fixed fallback)" : ""
    return "Sun — switches at " + Model.formatElevation(effElevation) + " sun elevation" + suffix
  }

  function sunDetailText() {
    if (!switcher || effMode === "fixed") return ""
    if (switcher.usingSun)
      return "Light " + Model.formatTime(switcher.lightAtToday)
        + " · Dark " + Model.formatTime(switcher.darkAtToday)
        + " (" + Model.formatElevation(effElevation) + ")"
    return "Fixed fallback " + String(setting("fixedLightTime", "07:00"))
      + " / " + String(setting("fixedDarkTime", "19:00"))
  }

  // Theme picking through Omarchy's STOCK image-grid picker (the same
  // UX as `omarchy theme switcher`). pick-theme.sh opens the grid and
  // prints the picked theme's display name. A headline banner names the
  // slot over the grid (the stock grid cannot show one); it appears
  // after the picker mapped so it stacks on top. The fullscreen grid
  // covers this panel, so it closes first and reopens with the choice.
  function chooseTheme(slot) {
    if (slot !== "dark" && slot !== "light") return
    root.pickingSlot = slot
    root.close()
    pickerDelay.restart()
  }

  function headlineText(slot) {
    return slot === "dark" ? "Choose the DARK theme" : "Choose the LIGHT theme"
  }

  function showHeadline() {
    if (root.hostWidget && typeof root.hostWidget.showHeadline === "function")
      root.hostWidget.showHeadline(headlineText(root.pickingSlot))
  }

  function hideHeadline() {
    if (root.hostWidget && typeof root.hostWidget.hideHeadline === "function")
      root.hostWidget.hideHeadline()
  }

  function onThemePicked(raw) {
    var slot = root.pickingSlot
    root.pickingSlot = ""
    hideHeadline()
    if (slot !== "dark" && slot !== "light") return
    var display = ""
    var lines = String(raw || "").split("\n")
    for (var i = 0; i < lines.length; i++) {
      var line = lines[i].replace(/^\s+|\s+$/g, "")
      if (line !== "") { display = line; break }
    }
    // Cancelled, empty, or unchanged: just reopen the panel.
    if (display === "" || Model.sameTheme(display, slotTheme(slot))) {
      root.open()
      return
    }
    var values = {}
    values[slot === "dark" ? "darkTheme" : "lightTheme"] = display
    persistSettings(values)
    root.open()
  }

  onSettingsChanged: syncFields()
  Component.onCompleted: syncFields()

  Process {
    id: previewListProc
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.parsePreviewList(text)
    }
  }

  Timer {
    id: pickerDelay
    interval: 350
    repeat: false
    onTriggered: {
      if (root.pickingSlot !== "dark" && root.pickingSlot !== "light") return
      pickerProc.command = ["bash", root.pickerScript,
        root.pickingSlot, root.slotTheme(root.pickingSlot)]
      pickerProc.running = true
      // After the picker mapped, so the headline stacks above it.
      headlineDelay.restart()
    }
  }

  Timer {
    id: headlineDelay
    interval: 900
    repeat: false
    onTriggered: {
      if (root.pickingSlot === "dark" || root.pickingSlot === "light") root.showHeadline()
    }
  }

  Process {
    id: pickerProc
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.onThemePicked(text)
    }
    onExited: function() {
      // Picker closed without a readable choice (or failed): hide the
      // headline and reopen the panel if a pick was still pending.
      if (root.pickingSlot === "dark" || root.pickingSlot === "light") {
        root.pickingSlot = ""
        hideHeadline()
        root.open()
      }
    }
  }

  KeyboardPanel {
    id: panel
    anchorItem: root.anchorItem
    owner: root.barIdentity
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(400))
    contentHeight: panel.fittedContentHeight(content.implicitHeight)

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }

      // Plain flow column like bluetooth/wifi: it sizes from the card
      // via anchors (never `width: parent.width` inside a Flickable,
      // whose contentItem reparenting collapses that binding to zero).
      Column {
        id: content
        anchors.fill: parent
        spacing: Style.space(10)

        // ---------- Hero: pill icon · status · master switch ----------
        PanelHero {
          width: parent.width
          title: "Theme Switcher"
          meta: switcher ? switcher.statusText : "Theme Switcher"
          detail: root.sunDetailText()
          foreground: root.contentForeground
          fontFamily: root.contentFontFamily
          iconOpacity: root.effEnabled ? 1.0 : 0.5
          iconComponent: Component {
            Text {
              textFormat: Text.PlainText
              anchors.centerIn: parent
              // Same glyph as the bar pill.
              text: switcher && switcher.desiredNow === "dark" ? "󰖔" : "󰖙"
              color: root.contentForeground
              font.family: root.contentFontFamily
              font.pixelSize: Style.font.display
            }
          }
          trailingControl: Component {
            ToggleSwitch {
              checked: root.effEnabled
              foreground: root.contentForeground
              onToggled: root.persistSettings({ enabled: !root.effEnabled })
            }
          }
        }

        // ---------- Status: active theme + next switch ----------
        Column {
          width: parent.width
          spacing: Style.space(2)

          Text {
            textFormat: Text.PlainText
            width: parent.width
            text: "Active theme: " + (switcher && switcher.currentTheme !== "" ? switcher.currentTheme : "…")
            color: root.contentForeground
            font.family: root.contentFontFamily
            font.pixelSize: Style.font.bodySmall
            elide: Text.ElideRight
          }

          Text {
            textFormat: Text.PlainText
            width: parent.width
            wrapMode: Text.WordWrap
            text: root.nextSwitchText()
            color: root.contentForeground
            font.family: root.contentFontFamily
            font.pixelSize: Style.font.bodySmall
          }

          Text {
            textFormat: Text.PlainText
            width: parent.width
            wrapMode: Text.WordWrap
            text: root.scheduleSummaryText()
            color: Qt.darker(root.contentForeground, 1.4)
            font.family: root.contentFontFamily
            font.pixelSize: Style.font.bodySmall
          }
        }

        PanelSeparator { width: parent.width }

        // ---------- Schedule ----------
        PanelSectionHeader {
          text: "SCHEDULE"
          foreground: root.contentForeground
          fontFamily: root.contentFontFamily
        }

        ButtonGroup {
          id: modeGroup
          width: parent.width
          value: root.effMode
          foreground: root.contentForeground
          fontFamily: root.contentFontFamily
          options: [
            { value: "sun", label: "Sun", tooltip: "Switch at sunrise/sunset" },
            { value: "fixed", label: "Fixed", tooltip: "Switch at fixed times" }
          ]
          onChanged: function(v) {
            if (v !== root.effMode) root.persistSettings({ mode: v })
          }
        }

        Text {
          visible: root.effMode === "sun" && switcher && !switcher.sunAvailable
          width: parent.width
          wrapMode: Text.WordWrap
          textFormat: Text.PlainText
          text: "No coordinates available — using the fixed times below as fallback."
          color: Qt.darker(root.contentForeground, 1.4)
          font.family: root.contentFontFamily
          font.pixelSize: Style.font.bodySmall
        }

        Row {
          visible: root.effMode === "fixed"
          width: parent.width
          spacing: Style.space(10)

          Column {
            width: (parent.width - Style.space(10)) / 2
            spacing: Style.space(4)

            Text {
              textFormat: Text.PlainText
              text: "Light at"
              color: Qt.darker(root.contentForeground, 1.4)
              font.family: root.contentFontFamily
              font.pixelSize: Style.font.bodySmall
            }

            TextField {
              id: fixedLightField
              width: parent.width
              placeholderText: "07:00"
              foreground: root.contentForeground
              font.family: root.contentFontFamily
              inputMethodHints: Qt.ImhTime
              onAccepted: root.commitTime(fixedLightField, "fixedLightTime")
              onEditingFinished: {
                if (fixedLightField.text !== String(root.setting("fixedLightTime", "07:00")))
                  root.commitTime(fixedLightField, "fixedLightTime")
              }
            }
          }

          Column {
            width: (parent.width - Style.space(10)) / 2
            spacing: Style.space(4)

            Text {
              textFormat: Text.PlainText
              text: "Dark at"
              color: Qt.darker(root.contentForeground, 1.4)
              font.family: root.contentFontFamily
              font.pixelSize: Style.font.bodySmall
            }

            TextField {
              id: fixedDarkField
              width: parent.width
              placeholderText: "19:00"
              foreground: root.contentForeground
              font.family: root.contentFontFamily
              inputMethodHints: Qt.ImhTime
              onAccepted: root.commitTime(fixedDarkField, "fixedDarkTime")
              onEditingFinished: {
                if (fixedDarkField.text !== String(root.setting("fixedDarkTime", "19:00")))
                  root.commitTime(fixedDarkField, "fixedDarkTime")
              }
            }
          }
        }

        Column {
          visible: root.effMode === "sun"
          width: parent.width
          spacing: Style.space(4)

          Text {
            textFormat: Text.PlainText
            text: "Switch at sun elevation (°)"
            color: Qt.darker(root.contentForeground, 1.4)
            font.family: root.contentFontFamily
            font.pixelSize: Style.font.bodySmall
          }

          TextField {
            id: elevationField
            width: parent.width
            placeholderText: "0"
            foreground: root.contentForeground
            font.family: root.contentFontFamily
            inputMethodHints: Qt.ImhFormattedNumbersOnly
            onAccepted: root.commitElevation()
            onEditingFinished: {
              if (parseFloat(String(elevationField.text || "").replace(",", ".")) !== root.effElevation)
                root.commitElevation()
            }
          }

          Text {
            width: parent.width
            wrapMode: Text.WordWrap
            textFormat: Text.PlainText
            text: "Sun elevation in degrees when the theme switches (0 = sunrise/sunset, horizon). "
                + "0° = Sun on the horizon · −6° civil twilight · −12° nautical twilight · −18° astronomical twilight. "
                + "Lower values switch later in the morning / earlier in the evening. Works identically anywhere on earth and all year round."
            color: Qt.darker(root.contentForeground, 1.6)
            font.family: root.contentFontFamily
            font.pixelSize: Style.font.bodySmall
          }
        }

        PanelSeparator { width: parent.width }

        // ---------- Location ----------
        PanelSectionHeader {
          text: "LOCATION"
          foreground: root.contentForeground
          fontFamily: root.contentFontFamily
        }

        Row {
          width: parent.width
          spacing: Style.space(10)

          Text {
            width: parent.width - autoSwitch.width - Style.space(10)
            anchors.verticalCenter: parent.verticalCenter
            wrapMode: Text.WordWrap
            textFormat: Text.PlainText
            text: "Use Omarchy location" + (switcher ? " (" + switcher.locationLabel + ")" : "")
            color: root.contentForeground
            font.family: root.contentFontFamily
            font.pixelSize: Style.font.body
          }

          ToggleSwitch {
            id: autoSwitch
            anchors.verticalCenter: parent.verticalCenter
            checked: root.effAutoLocation
            foreground: root.contentForeground
            onToggled: root.persistSettings({ useAutoLocation: !root.effAutoLocation })
          }
        }

        Column {
          visible: !root.effAutoLocation
          width: parent.width
          spacing: Style.space(8)

          TextField {
            id: locationNameField
            width: parent.width
            placeholderText: "Place name (optional)"
            foreground: root.contentForeground
            font.family: root.contentFontFamily
            onAccepted: root.commitLocation()
            onEditingFinished: root.commitLocation()
          }

          Row {
            width: parent.width
            spacing: Style.space(10)

            TextField {
              id: latitudeField
              width: (parent.width - Style.space(10)) / 2
              placeholderText: "Latitude"
              foreground: root.contentForeground
              font.family: root.contentFontFamily
              inputMethodHints: Qt.ImhFormattedNumbersOnly
              onAccepted: root.commitLocation()
              onEditingFinished: root.commitLocation()
            }

            TextField {
              id: longitudeField
              width: (parent.width - Style.space(10)) / 2
              placeholderText: "Longitude"
              foreground: root.contentForeground
              font.family: root.contentFontFamily
              inputMethodHints: Qt.ImhFormattedNumbersOnly
              onAccepted: root.commitLocation()
              onEditingFinished: root.commitLocation()
            }
          }
        }

        PanelSeparator { width: parent.width }

        // ---------- Themes ----------
        PanelSectionHeader {
          text: "LIGHT THEME"
          foreground: root.contentForeground
          fontFamily: root.contentFontFamily
        }

        ThemeSlotCard {
          width: parent.width
          slot: "light"
          themeName: root.slotTheme("light")
          previewSource: root.previewSourceFor(root.slotTheme("light"))
          isActive: switcher && Model.sameTheme(switcher.currentTheme, root.slotTheme("light"))
          foreground: root.contentForeground
          fontFamily: root.contentFontFamily
          onChoose: function(s) { root.chooseTheme(s) }
        }

        PanelSectionHeader {
          text: "DARK THEME"
          foreground: root.contentForeground
          fontFamily: root.contentFontFamily
        }

        ThemeSlotCard {
          width: parent.width
          slot: "dark"
          themeName: root.slotTheme("dark")
          previewSource: root.previewSourceFor(root.slotTheme("dark"))
          isActive: switcher && Model.sameTheme(switcher.currentTheme, root.slotTheme("dark"))
          foreground: root.contentForeground
          fontFamily: root.contentFontFamily
          onChoose: function(s) { root.chooseTheme(s) }
        }

        PanelSeparator { width: parent.width }

        // ---------- Quick switch ----------
        Row {
          width: parent.width
          spacing: Style.space(10)

          Button {
            width: (parent.width - Style.space(10)) / 2
            text: "Light now"
            foreground: root.contentForeground
            fontFamily: root.contentFontFamily
            bordered: true
            onClicked: if (switcher) switcher.switchToLight()
          }

          Button {
            width: (parent.width - Style.space(10)) / 2
            text: "Dark now"
            foreground: root.contentForeground
            fontFamily: root.contentFontFamily
            bordered: true
            onClicked: if (switcher) switcher.switchToDark()
          }
        }

        Text {
          visible: switcher && switcher.lastAction !== ""
          width: parent.width
          wrapMode: Text.WordWrap
          textFormat: Text.PlainText
          text: switcher ? switcher.lastAction : ""
          color: Qt.darker(root.contentForeground, 1.4)
          font.family: root.contentFontFamily
          font.pixelSize: Style.font.bodySmall
        }
      }
    }
  }
}