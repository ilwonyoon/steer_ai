#!/usr/bin/env bash
# Generate the macOS .icns from a single 1024x1024 master PNG.
# Usage: scripts/generate-app-icon.sh [path/to/master-1024.png]
# Default master:  apps/mac/Resources/AppIcon-master.png
# Output icns:     apps/mac/Resources/AppIcon.icns
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MASTER_DEFAULT="$ROOT_DIR/apps/mac/Resources/AppIcon-master.png"
MASTER_PATH="${1:-$MASTER_DEFAULT}"
OUT_DIR="$ROOT_DIR/apps/mac/Resources"
ICONSET="$OUT_DIR/AppIcon.iconset"
ICNS_PATH="$OUT_DIR/AppIcon.icns"

if [ ! -f "$MASTER_PATH" ]; then
  echo "error: master icon not found at $MASTER_PATH" >&2
  echo "supply a 1024x1024 PNG either at the default path or as the first argument" >&2
  exit 1
fi

actual_size="$(sips -g pixelWidth -g pixelHeight "$MASTER_PATH" 2>/dev/null | awk '/pixel(Width|Height)/ {print $2}' | xargs)"
if [ "$actual_size" != "1024 1024" ]; then
  echo "error: master must be 1024x1024 px (got $actual_size)" >&2
  exit 1
fi

mkdir -p "$OUT_DIR"
rm -rf "$ICONSET"
mkdir -p "$ICONSET"

# Apple iconset spec — name and size pairs.
declare -a SIZES=(
  "icon_16x16.png:16"
  "icon_16x16@2x.png:32"
  "icon_32x32.png:32"
  "icon_32x32@2x.png:64"
  "icon_128x128.png:128"
  "icon_128x128@2x.png:256"
  "icon_256x256.png:256"
  "icon_256x256@2x.png:512"
  "icon_512x512.png:512"
  "icon_512x512@2x.png:1024"
)

for entry in "${SIZES[@]}"; do
  name="${entry%%:*}"
  size="${entry##*:}"
  sips -z "$size" "$size" "$MASTER_PATH" --out "$ICONSET/$name" >/dev/null
done

iconutil -c icns "$ICONSET" -o "$ICNS_PATH"
rm -rf "$ICONSET"

echo "$ICNS_PATH"
