# Theme Switcher

Automatic dark/light theme switcher for the [Omarchy](https://omarchy.org/) Quattro bar.

Pick a dark theme and a light theme — the plugin switches between them at
**sunrise/sunset** (computed offline from your location) or on a **fixed
schedule**. The location is taken from Omarchy's own weather setting
automatically, or set manually in the panel. The wallpaper belongs to the
theme and follows the switch in the same transition.

## Install

```sh
omarchy plugin add https://github.com/oldchiefphil/omarchy-theme-switcher.git --enable
```

Then place the widget in the bar (default section is `right`):

```sh
omarchy bar move io.github.oldchiefphil.theme-switcher --section right
```

Click the pill (sun/moon) to open the settings panel. Right-click to toggle
the theme immediately; middle-click refreshes the schedule.

The panel follows the Bluetooth/Wi-Fi pattern: a hero row with the status,
the master on/off switch, and live info (active theme, schedule, location),
then all options below it. The bar pill shows only a sun/moon icon; the
full status lives in the panel.

## Usage

- **Sun mode** (default): switches to the light theme when the sun climbs
  past the configured elevation and to the dark theme when it sinks below
  it. The elevation (default `0°`, the horizon) is a sun altitude in
  degrees: `0` is sunrise/sunset, `-6°` is civil twilight, `-12°` nautical,
  `-18°` astronomical. Positive values switch earlier to dark, negative
  values later. Unlike a minute offset, an elevation behaves the same
  everywhere on earth and in every season.
- **Fixed mode**: switches at two configurable times (`HH:MM`, default
  `07:00` / `19:00`).
- The master switch in the panel hero turns automatic switching off
  entirely; off, the plugin is just a quick toggle (right-click).
- Picking a theme uses Omarchy's stock theme gallery: **Choose…** on a
  slot first shows a centered headline ("Choose the LIGHT/DARK theme")
  above the grid, then the familiar fullscreen picker opens. The choice
  is saved to that slot; cancelling (Esc) changes nothing.
- Each theme keeps its wallpaper: switching to a theme restores that
  theme's remembered background in the same cross-fade as the theme
  colors. Memory lives in
  `~/.local/state/omarchy/theme-switcher/backgrounds.json`.
- A manual switch ("Light now" / "Dark now", or right-click) lasts until
  the next scheduled event — the schedule stays armed underneath. Switching
  is always done through `omarchy theme set`, so backgrounds, hooks
  (`theme-set.d/`), and theme transitions behave exactly like a manual
  theme change. A switch only happens when the target theme differs from
  the active one, so backgrounds are never rotated needlessly.

## Configure

All settings live inline on the bar entry in `~/.config/omarchy/shell.json`
(no separate config file):

| Key | Default | Meaning |
|-----|---------|---------|
| `enabled` | `true` | Master switch (hero toggle); off stops automatic switching |
| `mode` | `"sun"` | `"sun"` or `"fixed"` |
| `darkTheme` | `"Tokyo Night"` | Theme for the dark phase |
| `lightTheme` | `"Catppuccin Latte"` | Theme for the light phase |
| `fixedLightTime` | `"07:00"` | Fixed switch-to-light time |
| `fixedDarkTime` | `"19:00"` | Fixed switch-to-dark time |
| `sunElevation` | `0` | Sun elevation in degrees (-18…18) |
| `useAutoLocation` | `true` | Read Omarchy's location automatically |
| `locationName` | `""` | Manual place name (label only) |
| `latitude` / `longitude` | `""` | Manual coordinates (used when auto is off) |

Example entry:

```json
{ "id": "io.github.oldchiefphil.theme-switcher", "mode": "sun",
  "darkTheme": "Tokyo Night", "lightTheme": "Catppuccin Latte",
  "sunElevation": 0 }
```

The panel can also be driven over shell IPC:

```sh
omarchy-shell shell summon io.github.oldchiefphil.theme-switcher '{}'
omarchy-shell shell hide io.github.oldchiefphil.theme-switcher
```

## Location & privacy

- When `useAutoLocation` is on, coordinates come from
  `~/.local/state/omarchy/settings/weather.json` — the same file owned by
  `omarchy-weather-location` that the built-in weather widget reads. No
  extra location service, no tracking.
- Without coordinates (no weather location set and no manual coordinates),
  sun mode falls back to the fixed times.
- Sunrise/sunset are computed locally with the NOAA solar equations
  (`SunCalc.js`, no network). The plugin makes no network requests at all.

## Remove

```sh
omarchy plugin remove io.github.oldchiefphil.theme-switcher
```

## Development

The schedule math (`SunCalc.js`, `Model.js`) is plain dependency-free JS
with built-in self-checks:

```sh
node SunCalc.js && node Model.js
```

Validate the plugin folder the official way:

```sh
omarchy plugin validate .
```

## License

MIT — see [LICENSE](LICENSE).