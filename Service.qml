import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import "SunCalc.js" as SunCalc
import "Model.js" as Model

// Background switching engine for the theme-switcher plugin.
//
// Owned as a child of BarWidget.qml (tailscale pattern: Service {
// settings: root.settings }), so inline shell.json settings arrive via
// the `settings` property and persistence goes through the widget's
// updateEntryInline. Only the primary bar instance runs the timer —
// BarWidget gates this through `active`.
//
// Strategy: compute today's plan once (Model.planDay), arm a single-shot
// timer for the next event, and reconcile on start/settings change. Every
// `omarchy theme set` is guarded by `omarchy theme current` so a redundant
// switch never rotates the background.
//
// Wallpaper: each theme keeps its own wallpaper. Before `omarchy theme set`
// we stage the remembered wallpaper as the theme's FIRST user background
// (~/.config/omarchy/backgrounds/<slug>/0-chosen.<ext>), so the theme switch
// itself cross-fades straight to that image — no default-then-restore step,
// the transition is one motion ("aus einem Guß"). Memory lives in
// ~/.local/state/omarchy/theme-switcher/backgrounds.json and stores bare
// filenames (not volatile paths under current/theme/).
//
// Manual switches (Light now / Dark now) are temporary overrides: the
// schedule stays armed and the override holds until the next scheduled
// event instead of being reconciled away.
Item {
  id: root

  property var settings: ({})
  property bool active: true
  property bool debug: false

  function dbg() {
    if (!root.debug) return
    var parts = []
    for (var i = 0; i < arguments.length; i++) parts.push(String(arguments[i]))
    console.log("[tsw] " + parts.join(" "))
  }

  function setting(name, fallback) {
    var value = settings ? settings[name] : undefined
    return value === undefined || value === null ? fallback : value
  }

  function intSetting(name, fallback, min, max) {
    var n = parseInt(String(setting(name, fallback)), 10)
    if (!isFinite(n)) n = fallback
    if (n < min) n = min
    if (n > max) n = max
    return n
  }

  function boolSetting(name, fallback) {
    var v = setting(name, fallback)
    if (v === true || v === 1) return true
    if (v === false || v === 0) return false
    return String(v).toLowerCase() === "true" ? true : fallback
  }

  // Sun elevation in degrees at which the switch happens (0 = horizon,
  // positive = above, negative = below; standard sunrise/sunset = -0.833).
  // Unlike a minute offset, an elevation behaves the same everywhere on
  // earth and in every season.
  function floatSetting(name, fallback, min, max) {
    var n = parseFloat(String(setting(name, fallback)))
    if (!isFinite(n)) n = fallback
    if (n < min) n = min
    if (n > max) n = max
    return n
  }

  // ---- Configuration (inline shell.json entry) ----
  // `enabled` is the master switch from the panel hero. When off, the
  // service behaves like a disabled schedule: no timers, no reconcile.
  readonly property bool enabled: boolSetting("enabled", true)
  readonly property string configuredMode: {
    var m = String(setting("mode", "sun"))
    // "manual" is a legacy value; the schedule itself is only Sun/Fixed.
    return (m === "fixed" || m === "manual") ? m : "sun"
  }
  readonly property string mode: enabled ? configuredMode : "manual"
  readonly property string darkThemeSetting: String(setting("darkTheme", "") || "")
  readonly property string lightThemeSetting: String(setting("lightTheme", "") || "")
  readonly property string darkTheme: darkThemeSetting !== "" ? darkThemeSetting : "Tokyo Night"
  readonly property string lightTheme: lightThemeSetting !== "" ? lightThemeSetting : "Catppuccin Latte"
  readonly property int fixedLightMin: {
    var v = Model.parseTimeToMinutes(setting("fixedLightTime", "07:00"))
    return v === null ? 420 : v
  }
  readonly property int fixedDarkMin: {
    var v = Model.parseTimeToMinutes(setting("fixedDarkTime", "19:00"))
    return v === null ? 1140 : v
  }
  readonly property real sunElevation: floatSetting("sunElevation", 0, -18, 18)
  readonly property bool useAutoLocation: boolSetting("useAutoLocation", true)
  readonly property string locationName: String(setting("locationName", "") || "")
  // NOTE: `var`, not `double` — QML coerces null to 0.0 for typed
  // doubles, which would turn "no coordinates" into (0,0) off Africa.
  readonly property var manualLatitude: Model.parseCoord(setting("latitude", ""))
  readonly property var manualLongitude: Model.parseCoord(setting("longitude", ""))

  // ---- Location: Omarchy's own weather.json or manual override ----
  property var autoLocation: ({ name: "", latitude: null, longitude: null })

  readonly property bool hasAutoCoords: Model.validCoords(autoLocation.latitude, autoLocation.longitude)
  readonly property bool hasManualCoords: Model.validCoords(manualLatitude, manualLongitude)
  readonly property var effectiveCoords: {
    if (useAutoLocation && hasAutoCoords)
      return { latitude: autoLocation.latitude, longitude: autoLocation.longitude }
    if (!useAutoLocation && hasManualCoords)
      return { latitude: manualLatitude, longitude: manualLongitude }
    // One-way fallback so sun mode degrades gracefully instead of dying:
    // prefer whichever source actually has coordinates.
    if (hasAutoCoords) return { latitude: autoLocation.latitude, longitude: autoLocation.longitude }
    if (hasManualCoords) return { latitude: manualLatitude, longitude: manualLongitude }
    return null
  }
  readonly property string locationLabel: {
    if (useAutoLocation) {
      if (hasAutoCoords) return autoLocation.name !== "" ? autoLocation.name : "Omarchy location"
      return "IP auto-detect"
    }
    if (hasManualCoords) return locationName !== "" ? locationName : "Custom coordinates"
    return "No coordinates set"
  }

  // ---- Live plan ----
  property string desiredNow: ""
  property date nextAt: new Date(NaN)
  property string nextTarget: ""
  property date lightAtToday: new Date(NaN)
  property date darkAtToday: new Date(NaN)
  property bool usingSun: false
  property string currentTheme: ""
  property string lastAction: ""

  // A manual override holds the applied theme until the next scheduled
  // event; reconcile skips the window so the override is not fought.
  property date overrideUntil: new Date(NaN)

  readonly property string nextTargetTheme: nextTarget === "dark" ? darkTheme : lightTheme
  readonly property string desiredTheme: desiredNow === "dark" ? darkTheme : lightTheme
  readonly property bool sunAvailable: effectiveCoords !== null
  readonly property bool overridden: {
    var now = new Date()
    return overrideUntil && !isNaN(overrideUntil.getTime()) && now < overrideUntil
  }
  readonly property string statusText: {
    if (mode === "manual")
      return currentTheme !== "" ? "Off — " + currentTheme : "Off"
    if (!nextAt || isNaN(nextAt.getTime())) return "Schedule paused"
    var into = (desiredNow === "dark" ? "Dark" : "Light")
    var target = nextTarget === "dark" ? "Dark" : "Light"
    if (overridden)
      return "Manual " + (desiredTheme === darkTheme ? "Dark" : "Light")
        + " · next " + target + " " + Model.formatTime(nextAt)
    return into + " until " + Model.formatTime(nextAt) + " → " + target
  }

  function themeNameFor(which) {
    return which === "dark" ? darkTheme : lightTheme
  }

  function planOptions() {
    return {
      mode: mode,
      latitude: effectiveCoords ? effectiveCoords.latitude : null,
      longitude: effectiveCoords ? effectiveCoords.longitude : null,
      fixedLightMin: fixedLightMin,
      fixedDarkMin: fixedDarkMin,
      sunElevation: sunElevation
    }
  }

  function refreshPlan() {
    if (!root.active) {
      eventTimer.stop()
      return null
    }
    var now = new Date()
    var plan = Model.planDay(now, planOptions(), function(day, lat, lon, elevation) {
      return SunCalc.sunriseSunset(day, lat, lon, elevation)
    })
    root.desiredNow = plan.desired
    root.nextAt = plan.nextAt ? plan.nextAt : new Date(NaN)
    root.nextTarget = plan.nextTarget
    root.lightAtToday = plan.lightAt ? plan.lightAt : new Date(NaN)
    root.darkAtToday = plan.darkAt ? plan.darkAt : new Date(NaN)
    root.usingSun = plan.usingSun
    armTimer()
    return plan
  }

  // Full step: clear any override, recompute the plan and reconcile the
  // active theme with the schedule. Used on startup and settings changes.
  function refresh() {
    root.overrideUntil = new Date(NaN)
    // Re-read the location file on every refresh so a created/deleted
    // weather.json (FileView watchers do not survive deletion) still
    // reach the plan; onLoaded/onLoadFailed then re-plan via the timer.
    locationFile.reload()
    var plan = refreshPlan()
    if (plan && mode !== "manual" && plan.desired !== "")
      probeCurrent("reconcile", themeNameFor(plan.desired))
  }

  // Recompute without enforcing — for read-only surfaces (panel open)
  // where an instant switch would surprise, and for the hourly heartbeat
  // while a manual override is still in force.
  function refreshQuiet() {
    refreshPlan()
    probeStatus()
  }

  // Poll callback: parses the cat'ed weather.json (or the missing sentinel)
  // and only re-plans when the effective location actually changed, so the
  // minute timer never causes churn.
  function onLocationProbe(raw) {
    var text = String(raw || "").replace(/^\s+|\s+$/g, "")
    var parsed = text === "__MISSING__"
      ? Model.parseLocationFile("")
      : Model.parseLocationFile(text)
    var key = JSON.stringify([parsed.name, parsed.latitude, parsed.longitude])
    var cur = JSON.stringify([root.autoLocation.name,
      root.autoLocation.latitude, root.autoLocation.longitude])
    if (key !== cur) {
      root.autoLocation = parsed
      locationSettleTimer.restart()
    }
  }

  function probeStatus() {
    probeCurrent("status", "")
  }

  function armTimer() {
    eventTimer.stop()
    if (mode === "manual" || !nextAt || isNaN(nextAt.getTime())) return
    var ms = nextAt.getTime() - Date.now()
    if (ms < 3000) ms = 3000
    if (ms > 2147483647) ms = 2147483647
    eventTimer.interval = ms
    eventTimer.start()
  }

  function onEventFired() {
    if (!root.active || mode === "manual" || nextTarget === "") return
    doApply(themeNameFor(nextTarget), "Scheduled switch")
    // Let the freshly applied theme settle before re-planning so the
    // reconcile probe sees the new state instead of re-applying.
    settleTimer.restart()
  }

  // ---- Theme probing + guarded switching ----

  property string _probePurpose: ""
  property string _probeTheme: ""
  property bool _probeQueued: false
  property bool _settleQuiet: false

  // ---- Theme -> wallpaper memory ----
  // `omarchy theme set` picks the FIRST background of the target theme
  // unless the current background matches a list entry (then it rotates
  // to the next). We therefore stage the remembered wallpaper as the
  // ALPHABETICALLY-FIRST user background (0-chosen.*) before switching:
  // find -L sorts user backgrounds before theme backgrounds (.config <
  // .local), so the staged symlink is list[0] and the theme switch lands
  // directly on the remembered image in a single cross-fade.
  property var bgMap: ({})
  property string _swTarget: ""
  property string _swReason: ""
  property string _swCurrent: ""
  property bool _bgQueued: false
  property var _switchQueued: null
  property bool _bgSaveQueued: false

  readonly property string bgMapPath: Quickshell.env("HOME")
    + "/.local/state/omarchy/theme-switcher/backgrounds.json"

  // Directory holding the staged "chosen" symlink for a theme's slug.
  function userBgDir(slug) {
    return Quickshell.env("HOME") + "/.config/omarchy/backgrounds/" + slug
  }

  function loadBgMap(raw) {
    try {
      var data = JSON.parse(String(raw || "{}"))
      if (!data || typeof data !== "object") {
        root.bgMap = {}
        return
      }
      // Store bare filenames only: full paths under current/theme are
      // rebuilt on every switch and would go stale. Old absolute entries
      // are reduced to their basename.
      var clean = {}
      for (var k in data) {
        if (typeof data[k] !== "string") continue
        var v = Model.bgMemoryValue(data[k])
        if (v !== "") clean[k] = v
      }
      root.bgMap = clean
    } catch (e) {
      root.bgMap = {}
    }
  }

  function saveBgMap() {
    if (bgSaveProc.running) {
      root._bgSaveQueued = true
      return
    }
    root._bgSaveQueued = false
    bgSaveProc.command = ["bash", "-c",
      "mkdir -p \"${1%/*}\" && printf '%s' \"$2\" >\"$1.tmp.$$\" && mv -f \"$1.tmp.$$\" \"$1\"",
      "bg-save", bgMapPath, JSON.stringify(bgMap)]
    bgSaveProc.running = true
  }

  function snapshotBg(themeDisplay, bgPath) {
    var key = Model.normalizeThemeName(themeDisplay)
    var value = Model.bgMemoryValue(bgPath)
    if (key === "" || value === "") return
    if (bgMap[key] === value) return
    var next = {}
    for (var k in bgMap) next[k] = bgMap[k]
    next[key] = value
    root.bgMap = next
    saveBgMap()
  }

  // One bash call: stage the remembered wallpaper for `target` as its
  // first user background (or clear the stage), then apply the theme.
  // Passing values via $1..$3 keeps the script free of quote escaping.
  function stageAndSwitchCommand(target, slug, remembered) {
    return ["bash", "-c",
      "set -e; " +
      "USER_BGS=\"$HOME/.config/omarchy/backgrounds/$2\"; " +
      "mkdir -p \"$USER_BGS\"; " +
      "rm -f \"$USER_BGS\"/0-chosen.*; " +
      "resolved=\"\"; " +
      "if [[ -n $3 ]]; then " +
      "  if [[ $3 == /* && -f $3 ]]; then resolved=\"$3\"; " +
      "  elif [[ -f \"$USER_BGS/$3\" ]]; then resolved=\"$USER_BGS/$3\"; " +
      "  else " +
      "    for db in \"$HOME/.config/omarchy/themes/$2\" " +
      "             \"${OMARCHY_PATH:-/usr/share/omarchy}/themes/$2\" " +
      "             \"$(omarchy theme dir \"$1\" 2>/dev/null || true)\"; do " +
      "      if [[ -n $db && -f \"$db/backgrounds/$3\" ]]; then resolved=\"$db/backgrounds/$3\"; break; fi; " +
      "    done; " +
      "  fi; " +
      "fi; " +
      "if [[ -n $resolved ]]; then " +
      "  ext=\"${resolved##*.}\"; case \"$ext\" in jpg|jpeg|png|gif|bmp|webp) ;; *) ext=jpg;; esac; " +
      "  ln -s \"$resolved\" \"$USER_BGS/0-chosen.$ext\"; " +
      "fi; " +
      "omarchy theme set \"$1\"",
      "theme-switch", target, slug, remembered]
  }

  function doSwitch(target, reason, fromTheme) {
    if (String(target || "") === "") return
    if (switchProc.running) {
      root._switchQueued = { target: String(target), reason: String(reason || "Switch"), fromTheme: String(fromTheme || "") }
      return
    }
    root._switchQueued = null
    var slug = Model.slugForTheme(target)
    var remembered = ""
    var key = Model.normalizeThemeName(target)
    if (key !== "" && bgMap[key])
      remembered = Model.bgMemoryValue(bgMap[key])
    switchProc.command = root.stageAndSwitchCommand(target, slug, remembered)
    switchProc.running = true
  }

  function probeCurrent(purpose, themeName) {
    if (probeProc.running) {
      root._probePurpose = purpose
      root._probeTheme = themeName || ""
      root._probeQueued = true
      return
    }
    root._probePurpose = purpose
    root._probeTheme = themeName || ""
    root._probeQueued = false
    probeProc.running = true
  }

  function onCurrentTheme(raw) {
    root.currentTheme = String(raw || "").replace(/^\s+|\s+$/g, "")
    root.dbg("onCurrentTheme current=", root.currentTheme,
      "purpose=", root._probePurpose, "target=", root._probeTheme)
    var purpose = root._probePurpose
    var target = root._probeTheme
    root._probePurpose = ""
    root._probeTheme = ""
    if (purpose === "reconcile") {
      if (root.overridden) return
      if (target !== "" && !Model.sameTheme(root.currentTheme, target))
        startSwitch(target, "Auto-switch", root.currentTheme)
      else if (target !== "")
        root.lastAction = target + " already active"
    } else if (purpose === "preapply") {
      // Target travels in _swTarget (doApply probes with an empty slot).
      if (root._swTarget !== "")
        startSwitch(root._swTarget, root._swReason || "Manual switch", root.currentTheme)
    } else if (purpose === "pretoggle") {
      var next = Model.sameTheme(root.currentTheme, darkTheme) ? lightTheme : darkTheme
      startSwitch(next, "Manual switch", root.currentTheme)
    }
    // "status" only updates currentTheme — no action.
  }

  function probeBg() {
    if (bgProc.running) {
      root._bgQueued = true
      return
    }
    root._bgQueued = false
    bgProc.running = true
  }

  // Entry point for every theme switch (scheduled, manual, IPC). Probes
  // the current theme first so the wallpaper snapshot stays accurate.
  function doApply(themeName, reason) {
    if (String(themeName || "") === "") return
    root.dbg("doApply target=", themeName, "reason=", reason)
    root._swTarget = String(themeName)
    root._swReason = String(reason || "Switch")
    probeCurrent("preapply", "")
  }

  // Current theme is known (freshly probed): snapshot its wallpaper,
  // switch, then remember both themes' wallpapers.
  function startSwitch(target, reason, fromTheme) {
    if (String(target || "") === "") return
    root.dbg("startSwitch target=", target, "reason=", reason, "from=", fromTheme)
    root._swTarget = String(target)
    root._swReason = String(reason || "Switch")
    root._swCurrent = String(fromTheme || "")
    probeBg()
  }

  function onBgForSwitch(bg) {
    var rawBg = String(bg || "").replace(/^\s+|\s+$/g, "")
    var target = root._swTarget
    var reason = root._swReason
    var fromTheme = root._swCurrent
    root.dbg("onBgForSwitch bg=", rawBg, "target=", target, "reason=", reason, "from=", fromTheme, "current=", root.currentTheme)
    root._swTarget = ""
    root._swReason = ""
    root._swCurrent = ""
    if (target === "") return
    // 1. Remember where the leaving theme left off (includes manual bg cycles).
    if (fromTheme !== "" && rawBg !== "") snapshotBg(fromTheme, rawBg)
    // 2. Skip a redundant switch entirely — no stage, no background rotate.
    if (Model.sameTheme(root.currentTheme, target)) {
      root.lastAction = target + " already active"
      _settleQuiet = reason !== "Scheduled switch" && reason !== "Auto-switch"
      settleTimer.restart()
      return
    }
    // 3. Stage remembered wallpaper + apply the theme in one detached call.
    root.lastAction = reason + ": " + target
    root.dbg("doSwitch ->", target, "slug=", Model.slugForTheme(target),
      "remembered=", bgMap[Model.normalizeThemeName(target)] || "")
    doSwitch(target, reason, fromTheme)
    // A manual switch is the user's word against the schedule: hold it
    // until the next scheduled event instead of reconciling it away.
    _settleQuiet = reason !== "Scheduled switch" && reason !== "Auto-switch"
    if (_settleQuiet) root.overrideUntil = root.nextAt
    settleTimer.restart()
  }

  function switchToDark() {
    doApply(darkTheme, "Manual switch")
  }

  function switchToLight() {
    doApply(lightTheme, "Manual switch")
  }

  function toggle() {
    probeCurrent("pretoggle", "")
  }

  function status() {
    return JSON.stringify({
      mode: mode,
      configuredMode: configuredMode,
      enabled: enabled,
      desired: desiredNow,
      desiredTheme: desiredTheme,
      current: currentTheme,
      nextAt: nextAt && !isNaN(nextAt.getTime()) ? nextAt.toISOString() : null,
      nextTarget: nextTarget,
      nextTargetTheme: nextTargetTheme,
      usingSun: usingSun,
      sunElevation: sunElevation,
      location: locationLabel,
      rememberedBackgrounds: Object.keys(bgMap).length,
      lastAction: lastAction
    })
  }

  onSettingsChanged: refreshDebounce.restart()
  onActiveChanged: {
    if (root.active) refresh()
    else eventTimer.stop()
  }

  Component.onCompleted: {
    bgMapFile.reload()
    refresh()
  }

  Timer {
    id: refreshDebounce
    interval: 400
    repeat: false
    onTriggered: root.refresh()
  }

  Timer {
    id: eventTimer
    repeat: false
    onTriggered: root.onEventFired()
  }

  Timer {
    id: settleTimer
    interval: 10000
    repeat: false
    onTriggered: {
      if (root._settleQuiet) {
        root._settleQuiet = false
        root.refreshQuiet()
      } else {
        root.refresh()
      }
    }
  }

  // The location file arrived or disappeared: re-plan and reconcile with
  // the fresh coordinates. Never calls refresh() itself, so there is no
  // reload loop (refresh() re-reads the file, which fires this again).
  Timer {
    id: locationSettleTimer
    interval: 200
    repeat: false
    onTriggered: {
      refreshPlan()
      if (mode !== "manual" && root.desiredNow !== "") {
        if (root.overridden) root.refreshQuiet()
        else probeCurrent("reconcile", root.themeNameFor(root.desiredNow))
      }
    }
  }

  // Quickshell FileView watchers die when the watched file is deleted, and
  // reload() on a missing file (or one recreated with identical content)
  // emits nothing, so a cleared weather.json would stick. Read the file
  // directly once a minute instead: the probe cat's it and compares the
  // parsed location against the current one, converging within 60s.
  Timer {
    id: locationPollTimer
    interval: 60000
    repeat: true
    onTriggered: locationProbe.exec()
  }

  Process {
    id: locationProbe
    command: ["bash", "-c",
      "f=\"${HOME}/.local/state/omarchy/settings/weather.json\"; if test -f \"$f\"; then cat \"$f\"; else echo \"__MISSING__\"; fi"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.onLocationProbe(text())
    }
  }

  SystemClock {
    id: dayClock
    precision: SystemClock.Hours
    // Hourly heartbeat: rolls the plan over at midnight and keeps the
    // pill/panel labels fresh. Never reconciles while an override holds.
    onDateChanged: {
      if (root.overridden) root.refreshQuiet()
      else refreshDebounce.restart()
    }
  }

  FileView {
    id: locationFile
    path: Quickshell.env("HOME") + "/.local/state/omarchy/settings/weather.json"
    watchChanges: true
    onLoaded: {
      root.autoLocation = Model.parseLocationFile(text())
      locationSettleTimer.restart()
    }
    onLoadFailed: {
      root.autoLocation = Model.parseLocationFile("")
      locationSettleTimer.restart()
    }
  }

  FileView {
    id: bgMapFile
    path: root.bgMapPath
    onLoaded: root.loadBgMap(text())
    onLoadFailed: root.loadBgMap("")
  }

  Process {
    id: probeProc
    command: ["omarchy", "theme", "current"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.onCurrentTheme(text)
    }
    onExited: function() {
      if (root._probeQueued) {
        var purpose = root._probePurpose
        var theme = root._probeTheme
        root._probeQueued = false
        root.probeCurrent(purpose, theme)
      }
    }
  }

  Process {
    id: bgProc
    // readlink directly: `theme bg current` prints a pretty display
    // name, but remembering needs the real file path.
    command: ["bash", "-c",
      "readlink -f \"${HOME}/.local/state/omarchy/current/background\" 2>/dev/null || true"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.onBgForSwitch(text)
    }
    onExited: function(exitCode, exitStatus) {
      root.dbg("bgProc exited code=", exitCode, "status=", exitStatus,
        "queued=", root._bgQueued)
      if (root._bgQueued) {
        root._bgQueued = false
        root.probeBg()
      }
    }
  }

  Process {
    id: switchProc
    onExited: function(exitCode, exitStatus) {
      root.dbg("switchProc exited code=", exitCode, "status=", exitStatus,
        "running=", running)
      var queued = root._switchQueued
      root._switchQueued = null
      if (queued && queued.target)
        root.doSwitch(queued.target, queued.reason, queued.fromTheme)
    }
  }

  Process {
    id: bgSaveProc
    stdout: StdioCollector {
      waitForEnd: true
    }
    onExited: function() {
      if (root._bgSaveQueued) root.saveBgMap()
    }
  }
}