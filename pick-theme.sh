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
# refreshed here with --preload so it never stales. The current slot's
# theme is preselected so the gallery opens on the familiar entry.

set -u

slot="${1:-light}"
current_name="${2:-}"

if [[ $slot != dark ]]; then
  slot="light"
fi

CACHE_DIR="${XDG_CACHE_HOME:-$HOME/.cache}/omarchy/theme-selector/previews"

# Rebuild preview symlinks + warm thumbnails when the theme set changed.
# Fast no-op otherwise.
omarchy-theme-switcher --preload >/dev/null 2>&1

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

picked_slug=$(omarchy-menu-images --print-name --show-labels --filterable \
  --lazy-thumbnails --selected "$selected" "$CACHE_DIR" 2>/dev/null | head -n 1)
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