#!/usr/bin/env bash
# Builds Macky's app icon (Macky/Resources/AppIcon.icns) from a PNG, with the tools that come with macOS.
# Source, in order: the image given as argument, Macky/Resources/AppIcon.png, ~/Downloads/LOGO Macky.png.
set -euo pipefail
cd "$(dirname "$0")/.."

RESOURCES="Macky/Resources"
SOURCE_COPY="$RESOURCES/AppIcon.png"
ICON="$RESOURCES/AppIcon.icns"
mkdir -p "$RESOURCES"

source_image="${1:-}"
if [[ -z "$source_image" ]]; then
  if [[ -f "$SOURCE_COPY" ]]; then
    source_image="$SOURCE_COPY"
  elif [[ -f "$HOME/Downloads/LOGO Macky.png" ]]; then
    source_image="$HOME/Downloads/LOGO Macky.png"
  else
    exit 0
  fi
fi
[[ -f "$source_image" ]] || { echo "✗ Nu găsesc imaginea: $source_image"; exit 1; }

# Keep a copy next to the project, so the icon survives even if the file in Downloads is moved.
if [[ "$source_image" != "$SOURCE_COPY" ]]; then
  sips -s format png "$source_image" --out "$SOURCE_COPY" >/dev/null
fi
# Up to date already.
if [[ -f "$ICON" && "$ICON" -nt "$SOURCE_COPY" ]]; then exit 0; fi

echo "→ Creez iconița aplicației…"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

# A non-square logo is padded (transparent) to a square, so it is not stretched.
width=$(sips -g pixelWidth "$SOURCE_COPY" | awk '/pixelWidth/ {print $2}')
height=$(sips -g pixelHeight "$SOURCE_COPY" | awk '/pixelHeight/ {print $2}')
side=$(( width > height ? width : height ))
cp "$SOURCE_COPY" "$work/square.png"
if [[ "$width" != "$height" ]]; then
  sips -p "$side" "$side" "$work/square.png" >/dev/null
fi

iconset="$work/AppIcon.iconset"
mkdir -p "$iconset"
for size in 16 32 128 256 512; do
  sips -z "$size" "$size" "$work/square.png" --out "$iconset/icon_${size}x${size}.png" >/dev/null
  double=$(( size * 2 ))
  sips -z "$double" "$double" "$work/square.png" --out "$iconset/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns "$iconset" -o "$ICON"
echo "   Iconița e gata: $ICON"
