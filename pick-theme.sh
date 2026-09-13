#!/bin/bash
# Opens Omarchy's stock theme picker (the same image grid as
# `omarchy theme switcher`) to choose the theme for one slot.
# Prints the picked theme's display name, or nothing when cancelled.
#
# Usage: pick-theme.sh <light|dark> [current-theme-name]
#
# The slot headline is shown by the plugin (Headline.qml banner above
# the grid). The picker works on the preview cache maintained by
# omarchy-theme-switcher (theme preview.png or first background),
# preloaded once on first use. The current slot's
# theme is preselected so the gallery opens on the familiar entry.
#
# Instead of letting `omarchy-menu-images` open the grid and keep us in
# the dark about when that happened, this script drives the same
# `image-selector open` IPC itself: it prepares the rows cache, opens
# the picker, then immediately emits a READY token on stdout. The plugin
# reacts to that moment and stacks the headline over the (now mapped)
# picker, so the banner lands deterministically on top for light and
# dark alike instead of racing an open that may still be in flight.

set -u

TSW_READY="TSW-PICKER-READY"

slot="${1:-light}"
current_name="${2:-}"

if [[ $slot != dark ]]; then
  slot="light"
fi

CACHE_DIR="${XDG_CACHE_HOME:-$HOME/.cache}/omarchy/theme-selector/previews"

# Rebuild preview symlinks + warm thumbnails when the theme set changed.
# This costs ~300 ms per call, so only preload when nothing is previewed
# yet; the picker works on what already exists.
if ! compgen -G "$CACHE_DIR"/*.png >/dev/null 2>&1; then
  omarchy-theme-switcher --preload >/dev/null 2>&1
fi

current_slug=$(printf '%s' "$current_name" | tr '[:upper:]' '[:lower:]' | tr ' ' '-')

selected=""
for ext in png jpg jpeg webp gif bmp; do
  if [[ -e $CACHE_DIR/$current_slug.$ext ]]; then
    selected="$CACHE_DIR/$current_slug.$ext"
    break
  fi
done

# The picker needs a preselection to open its interactive grid; without
# one it resolves to the current theme immediately. Fall back to the
# first available preview so the grid always opens.
if [[ -z $selected ]]; then
  selected=$(find -L "$CACHE_DIR" -maxdepth 1 -type f \
    \( -iname '*.png' -o -iname '*.jpg' -o -iname '*.jpeg' \
     -o -iname '*.webp' -o -iname '*.gif' -o -iname '*.bmp' \) \
    -print 2>/dev/null | sort | head -n 1)
fi

# No previews at all (should not happen once --preload ran): nothing to pick.
[[ -n $selected ]] || exit 0

# Build the picker's row list from the preview cache. Always inline from
# the preview files themselves: the previews are the small source images
# (~4 KB each), while the image-selector rows cache points at 300-400 KB
# thumbs and decodes that whole set on the way in — stalling the picker's
# event loop and with it the headline banner. image==image is also the
# exact lazy mode men-ui-selector launches with, so the grid appears the
# same instant as in the stock flow.
rows=""
while IFS= read -r -d '' f; do
  rows+="$f"$'\t'"$f"$'\n'
done < <(find -L "$CACHE_DIR" -maxdepth 1 -type f \
  \( -iname '*.png' -o -iname '*.jpg' -o -iname '*.jpeg' \
   -o -iname '*.webp' -o -iname '*.gif' -o -iname '*.bmp' \) \
  -print0 2>/dev/null | sort -z)
rows="${rows%$'\n'}"
[[ -n $rows ]] || exit 0

# Resolve the preselection to the path inside the preview dir (same
# samefile search omarchy-menu-images performs) so the grid opens on it.
selected_list_image=""
current_image=$(readlink -f "$selected" 2>/dev/null)
if [[ -n $current_image ]]; then
  selected_list_image=$(find -L "$CACHE_DIR" -maxdepth 1 -type f \
    -samefile "$current_image" -print -quit 2>/dev/null)
fi

selection_file=$(mktemp)
done_file=$(mktemp)
rm -f "$done_file"
trap 'rm -f "$selection_file" "$done_file"' EXIT

rows_b64=$(printf '%s' "$rows" | base64 -w 0)
if ! open_result=$(omarchy-shell image-selector open \
     "" \
     "$rows_b64" \
     "$selected_list_image" \
     "$selection_file" \
     "$done_file" \
     "true" \
     "true"); then
  exit 1
fi
if [[ $open_result != "ok" ]]; then
  exit 1
fi

# The picker window mapped with `open` accepted; run the plugin's headline
# banner now, before the grid reveals, so it stacks on top.
printf '%s\n' "$TSW_READY"

while [[ ! -e $done_file ]]; do
  sleep 0.01
done

picked_slug=""
if [[ -s $selection_file ]]; then
  picked_slug=$(<"$selection_file")
  picked_slug=${picked_slug##*/}
  picked_slug=${picked_slug%.*}
fi
picked_slug=$(printf '%s' "$picked_slug" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')
[[ -n $picked_slug ]] || exit 0

# Translate the slug back to the display name from `omarchy theme list`
# so the plugin can persist (and show) the same form everywhere.
normalized=$(printf '%s' "$picked_slug" | tr '[:upper:]' '[:lower:]' | tr '-' ' ')
display=""
while IFS= read -r name; do
  [[ -n $name ]] || continue
  if [[ $(printf '%s' "$name" | tr '[:upper:]' '[:lower:]') == "$normalized" ]]; then
    display="$name"
    break
  fi
done < <(omarchy theme list 2>/dev/null)

if [[ -z $display ]]; then
  # Unknown slug (custom theme): prettify like `omarchy theme current`.
  display=$(printf '%s' "$picked_slug" | tr '-' ' ' | sed -E 's/(^| )([a-z])/\1\u\2/g')
fi

printf '%s\n' "$display"