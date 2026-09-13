// Offline sunrise/sunset calculation (NOAA solar equations).
//
// Pure functions with no QML dependencies so the math stays testable
// outside the shell (e.g. `node SunCalc.js` runs a self-check).
// Costs a few dozen trig operations per day — no network, no polling.
//
// The switch elevation is a sun altitude in degrees (0 = horizon,
// positive = above, negative = below). An elevation behaves identically
// at every place on earth and in every season — unlike a minute offset,
// which stretches near the poles and across seasons.

var DEG = Math.PI / 180;
var RAD = 180 / Math.PI;
// Standard sunrise/sunset elevation: sun center 0.833° below the horizon
// (accounts for refraction + solar disc radius). The plugin defaults to
// 0° (geometric horizon); callers may pass any elevation they like.
var DEFAULT_ELEVATION = -0.833;

function dayOfYear(date) {
  var start = new Date(date.getFullYear(), 0, 0);
  return Math.floor((date - start) / 86400000);
}

function clampDay(date) {
  return new Date(date.getFullYear(), date.getMonth(), date.getDate(), 12, 0, 0, 0);
}

// One event (isSunrise true/false) for the given midday date, at the
// moment the sun center crosses `elevationDeg`.
// Returns minutes after local midnight, or null when the sun never
// reaches that elevation that day (polar night/day, or an elevation the
// sun never attains at this latitude).
function calcEventMinutes(date, latitude, longitude, isSunrise, elevationDeg) {
  var elevation = isFinite(elevationDeg) ? elevationDeg : DEFAULT_ELEVATION;
  var zenith = 90 - elevation;
  var noon = clampDay(date);
  var n = dayOfYear(noon);
  var lngHour = longitude / 15;
  var t = isSunrise
    ? n + (6 - lngHour) / 24
    : n + (18 - lngHour) / 24;

  var m = 0.9856 * t - 3.289;
  var l = m + 1.916 * Math.sin(m * DEG) + 0.020 * Math.sin(2 * m * DEG) + 282.634;
  l = ((l % 360) + 360) % 360;

  var ra = Math.atan(0.91764 * Math.tan(l * DEG)) * RAD;
  ra = ((ra % 360) + 360) % 360;
  var lQuadrant = Math.floor(l / 90) * 90;
  var raQuadrant = Math.floor(ra / 90) * 90;
  ra = ra + (lQuadrant - raQuadrant);
  ra = ra / 15;

  var sinDec = 0.39782 * Math.sin(l * DEG);
  var cosDec = Math.cos(Math.asin(sinDec));
  var cosH = (Math.cos(zenith * DEG) - sinDec * Math.sin(latitude * DEG))
    / (cosDec * Math.cos(latitude * DEG));

  if (cosH > 1 || cosH < -1) return null;

  var h = isSunrise
    ? 360 - Math.acos(cosH) * RAD
    : Math.acos(cosH) * RAD;
  h = h / 15;

  var utc = h + ra - 0.06571 * t - 6.622 - lngHour;
  utc = ((utc % 24) + 24) % 24;

  // Local timezone offset for that date (handles DST via the host).
  var tzMinutes = -noon.getTimezoneOffset();
  var local = utc * 60 + tzMinutes;
  return ((local % 1440) + 1440) % 1440;
}

function atMinutes(date, minutes) {
  return new Date(date.getFullYear(), date.getMonth(), date.getDate(),
    0, minutes, 0, 0);
}

// Sunrise and sunset as local Date objects for date's calendar day, at
// the moment the sun crosses `elevationDeg` (default: standard -0.833°).
// Either may be null near the poles; both null only with invalid input.
function sunriseSunset(date, latitude, longitude, elevationDeg) {
  var lat = parseFloat(latitude);
  var lon = parseFloat(longitude);
  if (!isFinite(lat) || !isFinite(lon) || lat < -90 || lat > 90
      || lon < -180 || lon > 180) {
    return { sunrise: null, sunset: null };
  }
  var riseMin = calcEventMinutes(date, lat, lon, true, elevationDeg);
  var setMin = calcEventMinutes(date, lat, lon, false, elevationDeg);
  return {
    sunrise: riseMin === null ? null : atMinutes(date, Math.round(riseMin)),
    sunset: setMin === null ? null : atMinutes(date, Math.round(setMin))
  };
}

// Node self-check: `node SunCalc.js`
if (typeof module !== "undefined" && require.main === module) {
  var assert = require("assert");
  // Berlin, 2026-06-21: sunrise ~04:43, sunset ~21:33 local (CEST).
  var summer = sunriseSunset(new Date(2026, 5, 21, 12), 52.52, 13.405);
  var riseMin = summer.sunrise.getHours() * 60 + summer.sunrise.getMinutes();
  var setMin = summer.sunset.getHours() * 60 + summer.sunset.getMinutes();
  // TZ-dependent host check: allow a wide band, assert ordering + daytime length.
  assert(summer.sunrise && summer.sunset, "both events exist");
  assert(setMin - riseMin > 12 * 60, "summer day longer than 12h in Berlin");
  assert(setMin - riseMin < 18 * 60, "summer day shorter than 18h in Berlin");
  // Berlin, 2026-12-21: short day.
  var winter = sunriseSunset(new Date(2026, 11, 21, 12), 52.52, 13.405);
  var wRise = winter.sunrise.getHours() * 60 + winter.sunrise.getMinutes();
  var wSet = winter.sunset.getHours() * 60 + winter.sunset.getMinutes();
  assert(wSet - wRise > 6 * 60 && wSet - wRise < 10 * 60, "winter day 6-10h in Berlin");
  // Polar night: Longyearbyen in December has no sunrise.
  var polar = sunriseSunset(new Date(2026, 11, 21, 12), 78.22, 15.63);
  assert(polar.sunrise === null, "no sunrise in polar night");
  // Elevation behaves symmetrically: +6° crosses later in the morning
  // and earlier in the evening than the standard -0.833°.
  var std = sunriseSunset(new Date(2026, 5, 21, 12), 52.52, 13.405);
  var high = sunriseSunset(new Date(2026, 5, 21, 12), 52.52, 13.405, 6);
  assert(high.sunrise > std.sunrise, "higher elevation rises later");
  assert(high.sunset < std.sunset, "higher elevation sets earlier");
  // 0° (geometric horizon) sits between the standard -0.833° and +6°.
  var zero = sunriseSunset(new Date(2026, 5, 21, 12), 52.52, 13.405, 0);
  assert(zero.sunrise > std.sunrise && zero.sunrise < high.sunrise,
    "0° rises after -0.833° but before +6°");
  // An elevation the sun never reaches yields nulls (→ fixed fallback).
  var never = sunriseSunset(new Date(2026, 11, 21, 12), 52.52, 13.405, 60);
  assert(never.sunrise === null && never.sunset === null, "unreachable elevation -> nulls");
  // Invalid input yields nulls.
  var bad = sunriseSunset(new Date(2026, 5, 21, 12), NaN, 13.4);
  assert(bad.sunrise === null && bad.sunset === null, "invalid input -> nulls");
  console.log("SunCalc.js self-check OK");
}