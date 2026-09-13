// Shared helpers for the theme-switcher plugin.
//
// Pure functions with no QML dependencies so the schedule logic stays
// testable outside the shell (e.g. `node Model.js` runs a self-check).
// QML files import this as `import "Model.js" as Model`.

// weather.json holds {"name": ..., "latitude": ..., "longitude": ...} (see
// omarchy-weather-location, which owns the format). Missing, blank, or
// unparseable means no automatic coordinates are available.
function parseLocationFile(raw) {
  var unset = { name: "", latitude: null, longitude: null };
  try {
    var data = JSON.parse(String(raw || ""));
    if (!data || typeof data !== "object") return unset;
    var latitude = parseFloat(data.latitude);
    var longitude = parseFloat(data.longitude);
    var hasCoordinates = !isNaN(latitude) && !isNaN(longitude);
    return {
      name: typeof data.name === "string" ? data.name.replace(/^\s+|\s+$/g, "") : "",
      latitude: hasCoordinates ? latitude : null,
      longitude: hasCoordinates ? longitude : null
    };
  } catch (e) {
    return unset;
  }
}

// First result of an open-meteo geocoding response (the weather panel's
// location picker uses the same API) -> { name, latitude, longitude }.
function parseGeoFirst(raw) {
  var unset = { name: "", latitude: null, longitude: null };
  try {
    var data = JSON.parse(String(raw || ""));
    var result = data && data.results && data.results[0] ? data.results[0] : null;
    if (!result) return unset;
    var latitude = parseFloat(result.latitude);
    var longitude = parseFloat(result.longitude);
    if (isNaN(latitude) || isNaN(longitude)) return unset;
    return {
      name: String(result.name || ""),
      latitude: latitude,
      longitude: longitude
    };
  } catch (e) {
    return unset;
  }
}

function parseCoord(value) {
  var n = parseFloat(String(value === undefined || value === null ? "" : value));
  return isNaN(n) ? null : n;
}

function validCoords(latitude, longitude) {
  return latitude !== null && longitude !== null
    && latitude >= -90 && latitude <= 90
    && longitude >= -180 && longitude <= 180;
}

// "HH:MM" (24h) -> minutes after midnight, or null when invalid.
function parseTimeToMinutes(text) {
  var m = /^\s*(\d{1,2})\s*:\s*(\d{1,2})\s*$/.exec(String(text || ""));
  if (!m) return null;
  var h = parseInt(m[1], 10);
  var min = parseInt(m[2], 10);
  if (h < 0 || h > 23 || min < 0 || min > 59) return null;
  return h * 60 + min;
}

function minutesToTimeString(minutes) {
  var m = ((Math.round(minutes) % 1440) + 1440) % 1440;
  var h = Math.floor(m / 60);
  var mm = m % 60;
  return (h < 10 ? "0" + h : "" + h) + ":" + (mm < 10 ? "0" + mm : "" + mm);
}

function formatTime(date) {
  if (!date || isNaN(date.getTime())) return "--:--";
  return minutesToTimeString(date.getHours() * 60 + date.getMinutes());
}

// A readable elevation label: 0 -> "0°", -0.83 -> "-0.8°", 6 -> "6°".
function formatElevation(elevation) {
  var n = parseFloat(elevation);
  if (!isFinite(n)) return "0°";
  var rounded = Math.round(n * 10) / 10;
  if (rounded === 0) rounded = 0;
  return String(rounded) + "°";
}

// "Tokyo Night" and "tokyo-night" describe the same theme:
// `omarchy theme set` accepts both, `omarchy theme current` prints the
// display form. Normalize for comparisons.
function normalizeThemeName(name) {
  return String(name || "").replace(/^\s+|\s+$/g, "").toLowerCase().replace(/-/g, " ");
}

function sameTheme(a, b) {
  var na = normalizeThemeName(a);
  return na !== "" && na === normalizeThemeName(b);
}

// Slug form Omarchy uses for directories ("Tokyo Night" -> "tokyo-night").
function slugForTheme(name) {
  return normalizeThemeName(name).replace(/ +/g, "-");
}

// One line of `omarchy theme list` -> display name, or "" for blanks.
function parseThemeList(raw) {
  var out = [];
  var lines = String(raw || "").split("\n");
  for (var i = 0; i < lines.length; i++) {
    var name = lines[i].replace(/^\s+|\s+$/g, "");
    if (name !== "") out.push(name);
  }
  return out;
}

// Wallpaper memory key/value helpers. The value stored per theme is the bare
// FILENAME (not a full path): full paths under ~/.local/state/omarchy/current/
// are rebuilt on every theme switch and go stale. The filename is resolved
// against the target theme's own directories when a switch happens, so a theme
// keeps its wallpaper no matter what else was active in between.
function bgMemoryValue(rawPath) {
  var s = String(rawPath || "").replace(/^\s+|\s+$/g, "");
  if (s === "" || s.indexOf("/") === -1) return s;
  var parts = s.split("/");
  return parts[parts.length - 1];
}

function atMinutesOf(base, minutes) {
  return new Date(base.getFullYear(), base.getMonth(), base.getDate(),
    0, minutes, 0, 0);
}

// Full day plan for `now`. Dependencies (sun math) are injected so this
// stays pure and unit-testable: sunFor(date, lat, lon, elevationDeg) must
// return { sunrise: Date|null, sunset: Date|null }.
//
// opts: { mode, latitude, longitude, fixedLightMin, fixedDarkMin,
//         sunElevation }
//
// Returns { desired: "dark"|"light"|"", nextAt: Date|null,
//           nextTarget: "dark"|"light"|"", lightAt: Date|null,
//           darkAt: Date|null, usingSun: bool }.
// lightAt/darkAt describe today's events (at the configured sun
// elevation); nextAt is the next upcoming switch.
function planDay(now, opts, sunFor) {
  var empty = {
    desired: "", nextAt: null, nextTarget: "",
    lightAt: null, darkAt: null, usingSun: false
  };
  var mode = String((opts && opts.mode) || "sun");
  if (mode !== "sun" && mode !== "fixed") return empty;

  var lat = opts ? opts.latitude : null;
  var lon = opts ? opts.longitude : null;
  var useSun = mode === "sun" && validCoords(lat, lon) && typeof sunFor === "function";

  function eventsFor(day) {
    var light = null;
    var dark = null;
    if (useSun) {
      var ev = sunFor(day, lat, lon, opts.sunElevation);
      if (ev && ev.sunrise) light = ev.sunrise;
      if (ev && ev.sunset) dark = ev.sunset;
    }
    if (!light || !dark) {
      light = atMinutesOf(day, opts.fixedLightMin);
      dark = atMinutesOf(day, opts.fixedDarkMin);
    }
    return [
      { at: light, theme: "light" },
      { at: dark, theme: "dark" }
    ];
  }

  var yesterday = new Date(now.getTime() - 86400000);
  var all = eventsFor(yesterday).concat(eventsFor(now));
  var valid = [];
  for (var i = 0; i < all.length; i++) {
    if (all[i].at && !isNaN(all[i].at.getTime())) valid.push(all[i]);
  }
  valid.sort(function(a, b) { return a.at - b.at; });
  if (valid.length === 0) return empty;

  var desired = "";
  var next = null;
  for (var j = 0; j < valid.length; j++) {
    if (valid[j].at <= now) desired = valid[j].theme;
    else if (!next) next = valid[j];
  }
  if (desired === "") {
    // Before the first known event (e.g. just after midnight): the active
    // theme is the one the last event yesterday selected.
    desired = valid[valid.length - 1].theme;
    if (next && next.at > now && valid[valid.length - 1].at > now) {
      // All known events are still ahead — fall back to the earliest one.
      desired = valid[0].theme === "light" ? "dark" : "light";
    }
  }
  if (!next) {
    // Everything known already passed: roll today's events into tomorrow.
    var first = null;
    var todayEvents = eventsFor(now);
    for (var k = 0; k < todayEvents.length; k++) {
      var t = new Date(todayEvents[k].at.getTime() + 86400000);
      if (!first || t < first.at) first = { at: t, theme: todayEvents[k].theme };
    }
    next = first;
  }

  var todayEvents2 = eventsFor(now);
  return {
    desired: desired,
    nextAt: next ? next.at : null,
    nextTarget: next ? next.theme : "",
    lightAt: todayEvents2[0].at,
    darkAt: todayEvents2[1].at,
    usingSun: useSun
  };
}

// Filenames of Omarchy's theme preview cache
// (~/.cache/omarchy/theme-selector/previews/<slug>.<ext>) -> map of
// slug -> filename. Shared by the settings panel and the overlay picker.
function parsePreviewList(raw) {
  var map = {};
  var lines = String(raw || "").split("\n");
  for (var i = 0; i < lines.length; i++) {
    var file = lines[i].replace(/^\s+|\s+$/g, "");
    if (file === "") continue;
    var slug = file.replace(/\.[^.]+$/, "").toLowerCase();
    if (slug !== "" && !map[slug]) map[slug] = file;
  }
  return map;
}

// Node self-check: `node Model.js`
if (typeof module !== "undefined" && require.main === module) {
  var assert = require("assert");

  assert.deepStrictEqual(parseLocationFile('{"name":"Berlin","latitude":52.5,"longitude":13.4}'),
    { name: "Berlin", latitude: 52.5, longitude: 13.4 });
  assert.deepStrictEqual(parseLocationFile(""), { name: "", latitude: null, longitude: null });
  assert.deepStrictEqual(parseLocationFile('{"name":"X"}'), { name: "X", latitude: null, longitude: null });

  assert.deepStrictEqual(parseGeoFirst(""),
    { name: "", latitude: null, longitude: null });
  assert.deepStrictEqual(parseGeoFirst('{"results":[{"name":"Bochum","latitude":51.48,"longitude":7.22}]}'),
    { name: "Bochum", latitude: 51.48, longitude: 7.22 });
  assert.deepStrictEqual(parseGeoFirst('{"results":[]}'),
    { name: "", latitude: null, longitude: null });

  assert.strictEqual(parseTimeToMinutes("07:00"), 420);
  assert.strictEqual(parseTimeToMinutes("7:5"), 425);
  assert.strictEqual(parseTimeToMinutes("24:00"), null);
  assert.strictEqual(parseTimeToMinutes("abc"), null);
  assert.strictEqual(minutesToTimeString(420), "07:00");
  assert.strictEqual(normalizeThemeName("Tokyo-Night"), "tokyo night");
  assert.strictEqual(slugForTheme("Tokyo Night"), "tokyo-night");
  assert(sameTheme("Tokyo Night", "tokyo-night"), "slug/display match");
  assert(!sameTheme("", ""), "empty never matches");
  assert.deepStrictEqual(parseThemeList("A\n\nB\n"), ["A", "B"]);
  assert.deepStrictEqual(parsePreviewList("tokyo-night.png\ncatppuccin-latte.jpg\n\n"),
    { "tokyo-night": "tokyo-night.png", "catppuccin-latte": "catppuccin-latte.jpg" });
  assert.strictEqual(formatElevation(-0.833), "-0.8°");
  assert.strictEqual(formatElevation(0), "0°");
  assert.strictEqual(formatElevation(6), "6°");
  // Wallpaper memory never stores a volatile absolute path.
  assert.strictEqual(bgMemoryValue("2-crescent.webp"), "2-crescent.webp");
  assert.strictEqual(bgMemoryValue("/home/u/.local/state/omarchy/current/theme/backgrounds/2-crescent.webp"),
    "2-crescent.webp");
  assert.strictEqual(bgMemoryValue("/home/u/.config/omarchy/backgrounds/tokyo-night/1-orb.png"),
    "1-orb.png");
  assert.strictEqual(bgMemoryValue(""), "");

  var fixedSun = function(day) {
    return { sunrise: atMinutesOf(day, 360), sunset: atMinutesOf(day, 1260) };
  };
  var base = { mode: "sun", latitude: 52.5, longitude: 13.4,
    fixedLightMin: 420, fixedDarkMin: 1140, sunElevation: -0.833 };

  var noon = new Date(2026, 5, 21, 12, 0);
  var p = planDay(noon, base, fixedSun);
  assert.strictEqual(p.desired, "light", "midday is light");
  assert.strictEqual(p.nextTarget, "dark", "next is dark");
  assert.strictEqual(formatTime(p.nextAt), "21:00", "sunset at 21:00");

  var night = new Date(2026, 5, 21, 23, 0);
  var p2 = planDay(night, base, fixedSun);
  assert.strictEqual(p2.desired, "dark", "night is dark");
  assert.strictEqual(p2.nextTarget, "light", "next is light");
  assert.strictEqual(formatTime(p2.nextAt), "06:00", "next sunrise tomorrow");

  var early = new Date(2026, 5, 21, 3, 0);
  var p3 = planDay(early, base, fixedSun);
  assert.strictEqual(p3.desired, "dark", "before sunrise is dark");

  var fixed = planDay(noon, { mode: "fixed", latitude: null, longitude: null,
    fixedLightMin: 420, fixedDarkMin: 1140, sunElevation: -0.833 }, null);
  assert.strictEqual(fixed.usingSun, false, "fixed mode ignores sun");
  assert.strictEqual(fixed.desired, "light", "fixed midday is light");

  var noCoords = planDay(noon, { mode: "sun", latitude: null, longitude: null,
    fixedLightMin: 420, fixedDarkMin: 1140, sunElevation: -0.833 }, fixedSun);
  assert.strictEqual(noCoords.usingSun, false, "sun without coords falls back to fixed");
  assert.strictEqual(formatTime(noCoords.nextAt), "19:00", "fallback dark at 19:00");

  var manual = planDay(noon, { mode: "manual" }, fixedSun);
  assert.strictEqual(manual.desired, "", "manual plans nothing");

  var seenElevation = null;
  var recordingSun = function(day, lat, lon, elevation) {
    seenElevation = elevation;
    return fixedSun(day);
  };
  planDay(noon, { mode: "sun", latitude: 52.5, longitude: 13.4,
    fixedLightMin: 420, fixedDarkMin: 1140, sunElevation: 3.5 }, recordingSun);
  assert.strictEqual(seenElevation, 3.5, "elevation forwarded to sun math");

  console.log("Model.js self-check OK");
}