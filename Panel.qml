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
  // A time field the user has deliberately cleared stays blank (shows the
  // placeholder) instead of silently snapping back to the stored/default
  // value on the next re-sync.
  property bool lightTimeBlanked: false
  property bool darkTimeBlanked: false

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

  function timeDigits(key) {
    return String(root.settings[key] || "").replace(/[^0-9]/g, "")
  }

  // Numpad keys translate to digits regardless of the NumLock state: with
  // NumLock on they arrive as Key_0..9, with NumLock off they arrive as the
  // classic navigation keys (End/Down/PageDown/Left/Right/Home/Up/PageUp/
  // Insert, Clear) that still mean "type that digit" in a digits-only field.
  function keypadDigit(ev) {
    if (!(ev.modifiers & Qt.KeypadModifier)) return -1
    switch (ev.key) {
      case Qt.Key_Home: return 7
      case Qt.Key_Up: return 8
      case Qt.Key_PageUp: return 9
      case Qt.Key_Left: return 4
      case Qt.Key_Clear: return 5
      case Qt.Key_Right: return 6
      case Qt.Key_End: return 1
      case Qt.Key_Down: return 2
      case Qt.Key_PageDown: return 3
      case Qt.Key_Insert: return 0
    }
    return -1
  }

  function insertTimeDigit(field, digit) {
    var start = field.selectionStart
    var end = field.selectionEnd
    var pos = end > start ? start : field.cursorPosition
    if (end > start) field.remove(start, end)
    field.insert(pos, String(digit))
    field.cursorPosition = pos + 1
  }
  function removeSetting(key) {
    var entry = { id: root.moduleName }
    for (var existing in root.settings) if (existing !== "id" && existing !== key) entry[existing] = root.settings[existing]
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
    if (!root.lightTimeBlanked) fixedLightField.text = root.timeDigits("fixedLightTime")
    if (!root.darkTimeBlanked) fixedDarkField.text = root.timeDigits("fixedDarkTime")
    elevationField.value = Math.round(effElevation)
    cityField.text = String(setting("locationName", "") || "")
    latitudeField.text = String(setting("latitude", "") || "")
    longitudeField.text = String(setting("longitude", "") || "")
  }

  function commitTime(field, key) {
    var minutes = Model.parseTimeToMinutes(field.text)
    if (minutes === null) {
      // Non-empty but invalid input: snap back to the stored value. Empty
      // input never reaches this branch (blank is a deliberate state).
      syncFields()
      return
    }
    var normalized = Model.minutesToTimeString(minutes)
    var values = {}
    values[key] = normalized
    persistSettings(values)
    // The blanket re-sync skips a blanked/empty field; show the raw digits
    // right here so the field never flips back to whatever was typed.
    field.text = normalized.replace(":", "")
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
      locationName: String(cityField.text || ""),
      latitude: lat,
      longitude: lon
    })
  }

  // ---- City search (needs internet) ----
  // The city field only resolves through a live geocoding lookup. When the
  // network is unreachable it says so clearly, instead of a silent no-op,
  // so the user falls back to the coordinates directly below.
  property var cityResults: []
  property string cityState: "idle" // idle | searching | offline | none | results
  property string cityQuery: ""
  property string _pendingCityQuery: ""
  property int _activeCitySeq: 0
  property int _citySeq: 0
  property bool _suppressCitySearch: false

  Timer {
    id: citySearchDebounce
    interval: 350
    repeat: false
    onTriggered: root.searchCity(cityField.text)
  }

  function cityStatusText() {
    if (root.cityState === "searching")
      return "Searching for \u201C" + root.cityQuery + "\u201D\u2026"
    if (root.cityState === "offline")
      return "No internet \u2014 a city name cannot be looked up. "
          + "Enter Latitude / Longitude directly below instead."
    if (root.cityState === "none")
      return "No city found for \u201C" + root.cityQuery + "\u201D."
    return ""
  }

  function searchCity(text) {
    var q = String(text || "").replace(/^\s+|\s+$/g, "")
    if (q === "") return
    // A query typed while the previous lookup still runs is remembered and
    // launched right after it exits, instead of being silently dropped.
    root._pendingCityQuery = q
    root._citySeq++
    root.launchCitySearch()
  }

  function launchCitySearch() {
    var q = root._pendingCityQuery
    if (q === "" || geocodeProc.running) return
    root._pendingCityQuery = ""
    root._activeCitySeq = root._citySeq
    root.cityQuery = q
    root.cityResults = []
    root.cityState = "searching"
    geocodeProc.command = ["bash", "-c",
      "curl -fsS --max-time 6 "
      + "\"https://geocoding-api.open-meteo.com/v1/search?name=$1&count=5&language=de&format=json\"",
      "geocode", encodeURIComponent(q)]
    geocodeProc.running = true
  }

  function onGeocodeResult(seq, raw) {
    // Ignore answers that belong to an earlier, superseded query.
    if (Number(seq) !== root._activeCitySeq) return
    var text = String(raw || "").replace(/^\s+|\s+$/g, "")
    var parsed = null
    try { parsed = JSON.parse(text) } catch (e) {}
    if (!parsed || !parsed.results) return
    var out = []
    for (var i = 0; i < parsed.results.length; i++) {
      var it = parsed.results[i]
      if (!it) continue
      var name = String(it.name || "")
      var lat = Number(it.latitude)
      var lon = Number(it.longitude)
      if (name === "" || !isFinite(lat) || !isFinite(lon)) continue
      out.push({
        name: name,
        country: String(it.country_code || it.country || ""),
        latitude: lat,
        longitude: lon
      })
    }
    if (root.cityState !== "searching") return
    if (out.length === 0) {
      root.cityState = "none"
      return
    }
    root.cityResults = out
    root.cityState = "results"
  }

  function pickCity(result) {
    if (!result) return
    // Assigning cityField.text must not re-trigger a search for the picked
    // name; clear the dropdown and release the guard on the next tick.
    root._suppressCitySearch = true
    citySearchDebounce.stop()
    cityField.text = result.name
    latitudeField.text = String(result.latitude)
    longitudeField.text = String(result.longitude)
    root.cityResults = []
    root.cityState = "idle"
    root.commitLocation()
    Qt.callLater(function () { root._suppressCitySearch = false })
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

  // Resolved Omarchy location shown under the "Use Omarchy location" toggle
  // while it is ON: the city Omarchy resolved (with a map pin when it came
  // from IP geo-detection — never a stored file).
  function omarchyLocationText() {
    var label = switcher ? String(switcher.locationLabel || "") : ""
    if (label === "") return "Omarchy location"
    if (label === "IP auto-detect") return "Omarchy location · IP auto-detect"
    if (label === "Omarchy location") return "Omarchy location"
    var ipMarker = " (IP)"
    var ip = label.indexOf(ipMarker) >= 0
    var name = ip ? label.slice(0, label.indexOf(ipMarker)).trim() : label
    if (name === "") return "Omarchy location"
    return "Omarchy location · " + name + (ip ? "  \uf041" : "")
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
  // The picker binary's stdout announces itself (line-buffered) the
  // moment its `open` IPC was accepted; until then it blocks on the
  // user's choice. Surface-mapped in that moment, the picker window is
  // the stacking anchor: the headline shown a couple frames later always
  // lands above its scrim and next to its grid — deterministically for
  // light and dark alike.
  readonly property string pickerReadyToken: "TSW-PICKER-READY"
  property bool _pickerShown: false

  function chooseTheme(slot) {
    if (slot !== "dark" && slot !== "light") return
    root._pickerShown = false
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

  function onPickerOutput(out) {
    if (root._pickerShown) return
    if (String(out || "").indexOf(root.pickerReadyToken) < 0) return
    root._pickerShown = true
    // The READY token arrives near the end of the grid build, long after
    // the picker surface mapped (~300 ms), so the headline can stack
    // straight on top. Shown via a direct call — a follow-up Timer here
    // was flaky: it would restart without ever firing, dropping the banner.
    root.showHeadline()
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
      if (line === "") continue
      if (line.indexOf(root.pickerReadyToken) >= 0) continue
      display = line
      break
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

  Process {
    id: geocodeProc
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.onGeocodeResult(root._activeCitySeq, text)
    }
    onExited: function(exitCode, exitStatus) {
      // curl fails (non-zero) when the network is unreachable: tell the
      // user why the city lookup cannot work, don't pretend it searched.
      if (root.cityState === "searching" && exitCode !== 0)
        root.cityState = "offline"
      // A query typed while this lookup was still running gets its chance
      // now instead of being silently dropped.
      if (root._pendingCityQuery !== "")
        root.launchCitySearch()
    }
  }

  Timer {
    id: pickerDelay
    interval: 30
    repeat: false
    onTriggered: {
      if (root.pickingSlot !== "dark" && root.pickingSlot !== "light") return
      pickerProc.command = ["stdbuf", "-oL", "bash", root.pickerScript,
        root.pickingSlot, root.slotTheme(root.pickingSlot)]
      pickerProc.running = true
      // Fast path: the headline shows on a short fixed delay once the
      // picker window is deterministically mapped; onPickerOutput (the
      // script's READY token) guards the grid-fully-up case.
      headlineDelay.restart()
    }
  }

  Timer {
    id: headlineDelay
    interval: 650
    repeat: false
    onTriggered: {
      // Fast path: with the streamlined open (tiny preview rows, no
      // thumbnail generation) the picker window maps deterministically
      // right after the `open` IPC returns, ~350 ms in. 650 ms lands the
      // headline above that surface. The READY-token path (onPickerOutput)
      // stays as a guard for grid-fully-up, and skips this via _pickerShown.
      if (!root._pickerShown && (root.pickingSlot === "dark" || root.pickingSlot === "light"))
        root.showHeadline()
    }
  }

  Process {
    id: pickerProc
    stdout: StdioCollector {
      // Must be false: the script blocks on the user's choice, so with
      // waitForEnd the READY token would only surface at process end.
      // Incremental delivery is what lets onPickerOutput fire mid-run.
      waitForEnd: false
      onDataChanged: root.onPickerOutput(text)
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
      // Inline editors own the keys while focused (same pattern as the
      // built-in panels): typing digits into the time fields or the
      // elevation spinner must not double-drive the panel shortcuts.
      blocked: fixedLightField.activeFocus
        || fixedDarkField.activeFocus
        || (elevationField.field ? elevationField.field.activeFocus : false)
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
            text: root.sunDetailText()
            color: Qt.darker(root.contentForeground, 1.4)
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
              Keys.onPressed: function(ev) {
                if (ev.modifiers & Qt.ControlModifier) return
                var digit = -1
                if (ev.key >= Qt.Key_0 && ev.key <= Qt.Key_9) digit = ev.key - Qt.Key_0
                if (digit < 0) digit = root.keypadDigit(ev)
                if (digit >= 0 && !(ev.text && ev.text.length > 0)) {
                  root.insertTimeDigit(fixedLightField, digit)
                  ev.accepted = true
                }
              }
              foreground: root.contentForeground
              font.family: root.contentFontFamily
              // A plain digit validator instead of Qt.ImhDigitsOnly: the
              // input-method hint can drop numeric-keypad digits (they carry
              // the KeypadModifier), the validator cannot.
              validator: RegularExpressionValidator { regularExpression: /^[\d:]{0,5}$/ }
              inputMethodHints: Qt.ImhNoPredictiveText
              onTextChanged: {
                var digits = String(fixedLightField.text || "").replace(/[^0-9]/g, "")
                if (digits.length > 4) {
                  // Typing over an existing value starts a fresh entry: keep
                  // only the just-typed digit so the field can commit again.
                  fixedLightField.text = digits.slice(-1)
                  return
                }
                if (digits === "") {
                  root.lightTimeBlanked = true
                  root.removeSetting("fixedLightTime")
                  return
                }
                // 4 digits complete a time: apply on the spot, no need to
                // confirm (re-entrant sync shows the raw digits again; the
                // guard stops the loop).
                if (!/^\d{4}$/.test(digits)) return
                if (fixedLightField.text === root.timeDigits("fixedLightTime")) return
                root.commitTime(fixedLightField, "fixedLightTime")
              }
              onAccepted: root.commitTime(fixedLightField, "fixedLightTime")
              onEditingFinished: {
                var dt = String(fixedLightField.text || "").replace(/[^0-9]/g, "")
                if (dt === "") {
                  root.lightTimeBlanked = true
                  root.removeSetting("fixedLightTime")
                  return
                }
                if (fixedLightField.text !== root.timeDigits("fixedLightTime"))
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
              Keys.onPressed: function(ev) {
                if (ev.modifiers & Qt.ControlModifier) return
                var digit = -1
                if (ev.key >= Qt.Key_0 && ev.key <= Qt.Key_9) digit = ev.key - Qt.Key_0
                if (digit < 0) digit = root.keypadDigit(ev)
                if (digit >= 0 && !(ev.text && ev.text.length > 0)) {
                  root.insertTimeDigit(fixedDarkField, digit)
                  ev.accepted = true
                }
              }
              foreground: root.contentForeground
              font.family: root.contentFontFamily
              validator: RegularExpressionValidator { regularExpression: /^[\d:]{0,5}$/ }
              inputMethodHints: Qt.ImhNoPredictiveText
              onTextChanged: {
                var digits = String(fixedDarkField.text || "").replace(/[^0-9]/g, "")
                if (digits.length > 4) {
                  fixedDarkField.text = digits.slice(-1)
                  return
                }
                if (digits === "") {
                  root.darkTimeBlanked = true
                  root.removeSetting("fixedDarkTime")
                  return
                }
                if (!/^\d{4}$/.test(digits)) return
                if (fixedDarkField.text === root.timeDigits("fixedDarkTime")) return
                root.commitTime(fixedDarkField, "fixedDarkTime")
              }
              onAccepted: root.commitTime(fixedDarkField, "fixedDarkTime")
              onEditingFinished: {
                var dt = String(fixedDarkField.text || "").replace(/[^0-9]/g, "")
                if (dt === "") {
                  root.darkTimeBlanked = true
                  root.removeSetting("fixedDarkTime")
                  return
                }
                if (fixedDarkField.text !== root.timeDigits("fixedDarkTime"))
                  root.commitTime(fixedDarkField, "fixedDarkTime")
              }
            }
          }
        }

        Column {
          visible: root.effMode === "sun"
          width: parent.width
          spacing: Style.space(4)

          NumberField {
            id: elevationField
            width: parent.width
            label: "Switch at sun elevation (°)"
            value: Math.round(root.effElevation)
            from: -18
            to: 18
            stepSize: 1
            foreground: root.contentForeground
            fontFamily: root.contentFontFamily
            fontSize: Style.font.body
            fieldWidth: Style.space(160)
            onModified: function(v) { root.persistSettings({ sunElevation: v }) }
          }

          Text {
            width: parent.width
            wrapMode: Text.WordWrap
            textFormat: Text.PlainText
            text: "Sun elevation when the theme switches, in degrees. Works anywhere on earth, all year round."
            color: Qt.darker(root.contentForeground, 1.6)
            font.family: root.contentFontFamily
            font.pixelSize: Style.font.bodySmall
          }

          Column {
            width: parent.width
            spacing: Style.space(2)

            // Right-aligns every value to the same column (tab stop), so the
            // minus signs and degree symbols line up; the em-dash separator
            // is dropped to avoid reading as a "minus".
            Text {
              id: degreeMeasure
              visible: false
              text: "−18°"
              font.family: root.contentFontFamily
              font.pixelSize: Style.font.bodySmall
            }

            Row {
              width: parent.width
              spacing: Style.space(8)
              Text {
                text: "horizon (sunrise / sunset)"
                width: parent.width - degreeMeasure.implicitWidth - Style.space(8)
                elide: Text.ElideRight
                color: Qt.darker(root.contentForeground, 1.6)
                font.family: root.contentFontFamily
                font.pixelSize: Style.font.bodySmall
              }
              Text {
                text: "0°"
                width: degreeMeasure.implicitWidth
                horizontalAlignment: Text.AlignRight
                color: Qt.darker(root.contentForeground, 1.6)
                font.family: root.contentFontFamily
                font.pixelSize: Style.font.bodySmall
              }
            }
            Row {
              width: parent.width
              spacing: Style.space(8)
              Text {
                text: "civil twilight"
                width: parent.width - degreeMeasure.implicitWidth - Style.space(8)
                elide: Text.ElideRight
                color: Qt.darker(root.contentForeground, 1.6)
                font.family: root.contentFontFamily
                font.pixelSize: Style.font.bodySmall
              }
              Text {
                text: "−6°"
                width: degreeMeasure.implicitWidth
                horizontalAlignment: Text.AlignRight
                color: Qt.darker(root.contentForeground, 1.6)
                font.family: root.contentFontFamily
                font.pixelSize: Style.font.bodySmall
              }
            }
            Row {
              width: parent.width
              spacing: Style.space(8)
              Text {
                text: "nautical twilight"
                width: parent.width - degreeMeasure.implicitWidth - Style.space(8)
                elide: Text.ElideRight
                color: Qt.darker(root.contentForeground, 1.6)
                font.family: root.contentFontFamily
                font.pixelSize: Style.font.bodySmall
              }
              Text {
                text: "−12°"
                width: degreeMeasure.implicitWidth
                horizontalAlignment: Text.AlignRight
                color: Qt.darker(root.contentForeground, 1.6)
                font.family: root.contentFontFamily
                font.pixelSize: Style.font.bodySmall
              }
            }
            Row {
              width: parent.width
              spacing: Style.space(8)
              Text {
                text: "astronomical twilight"
                width: parent.width - degreeMeasure.implicitWidth - Style.space(8)
                elide: Text.ElideRight
                color: Qt.darker(root.contentForeground, 1.6)
                font.family: root.contentFontFamily
                font.pixelSize: Style.font.bodySmall
              }
              Text {
                text: "−18°"
                width: degreeMeasure.implicitWidth
                horizontalAlignment: Text.AlignRight
                color: Qt.darker(root.contentForeground, 1.6)
                font.family: root.contentFontFamily
                font.pixelSize: Style.font.bodySmall
              }
            }
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
            text: "Use Omarchy location"
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

        Text {
          visible: root.effAutoLocation
          width: parent.width
          wrapMode: Text.WordWrap
          textFormat: Text.PlainText
          text: root.omarchyLocationText()
          color: Qt.darker(root.contentForeground, 1.4)
          font.family: root.contentFontFamily
          font.pixelSize: Style.font.bodySmall
        }

        Column {
          visible: !root.effAutoLocation
          width: parent.width
          spacing: Style.space(8)

          Text {
            textFormat: Text.PlainText
            text: "Custom location"
            color: Qt.darker(root.contentForeground, 1.4)
            font.family: root.contentFontFamily
            font.pixelSize: Style.font.body
          }

          TextField {
            id: cityField
            width: parent.width
            placeholderText: "City name · results appear as you type (needs internet)"
            foreground: root.contentForeground
            font.family: root.contentFontFamily
            onTextChanged: {
              if (root._suppressCitySearch) return
              var q = String(cityField.text || "").replace(/^\s+|\s+$/g, "")
              if (q.length < 2) {
                citySearchDebounce.stop()
                root.cityResults = []
                if (root.cityState !== "offline") root.cityState = "idle"
                return
              }
              citySearchDebounce.restart()
            }
            onEditingFinished: root.searchCity(cityField.text)
          }

          Text {
            textFormat: Text.PlainText
            width: parent.width
            wrapMode: Text.WordWrap
            visible: root.cityStatusText() !== ""
            text: root.cityStatusText()
            color: Qt.darker(root.contentForeground, 1.6)
            font.family: root.contentFontFamily
            font.pixelSize: Style.font.bodySmall
          }

          Column {
            width: parent.width
            visible: root.cityResults.length > 0
            spacing: Style.space(1)

            Repeater {
              model: root.cityResults

              delegate: Rectangle {
                required property var modelData
                width: parent.width
                implicitHeight: row.implicitHeight + Style.space(6)
                radius: Style.cornerRadius
                color: hoverHandler.hovered ? Qt.darker(root.contentForeground, 2.2) : "transparent"

                HoverHandler { id: hoverHandler }

                MouseArea {
                  anchors.fill: parent
                  cursorShape: Qt.PointingHandCursor
                  onClicked: root.pickCity(modelData)
                }

                Row {
                  id: row
                  anchors.left: parent.left
                  anchors.right: parent.right
                  anchors.verticalCenter: parent.verticalCenter
                  anchors.leftMargin: Style.space(2)
                  anchors.rightMargin: Style.space(2)
                  spacing: Style.space(6)

                  Text {
                    textFormat: Text.PlainText
                    text: modelData.name
                    color: root.contentForeground
                    font.family: root.contentFontFamily
                    font.pixelSize: Style.font.body
                    elide: Text.ElideRight
                    width: Math.max(0, parent.width * 0.60)
                  }

                  Text {
                    textFormat: Text.PlainText
                    text: modelData.country
                    color: Qt.darker(root.contentForeground, 1.5)
                    font.family: root.contentFontFamily
                    font.pixelSize: Style.font.bodySmall
                    anchors.verticalCenter: parent.verticalCenter
                    elide: Text.ElideRight
                    width: Math.max(0, parent.width * 0.40)
                  }
                }
              }
            }
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