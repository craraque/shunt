#!/bin/bash
# Render Resources/Icon.svg and Icon-compact.svg into a macOS .icns with all
# required slot sizes. Outputs build/AppIcon.icns which build.sh copies into the
# app bundle.
#
# Uses rsvg-convert (brew install librsvg) for crisp vector → raster output.

set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
BUILD_DIR="$PROJECT_DIR/build"
ICONSET="$BUILD_DIR/AppIcon.iconset"

SVG_FULL="$PROJECT_DIR/Resources/Icon.svg"
SVG_COMPACT="$PROJECT_DIR/Resources/Icon-compact.svg"

command -v rsvg-convert >/dev/null || { echo "ERROR: rsvg-convert missing. Run: brew install librsvg"; exit 1; }
[[ -f "$SVG_FULL" ]] || { echo "ERROR: $SVG_FULL not found"; exit 1; }
[[ -f "$SVG_COMPACT" ]] || { echo "ERROR: $SVG_COMPACT not found"; exit 1; }

rm -rf "$ICONSET"
mkdir -p "$ICONSET"

# render(svg, pixel_size, out_file)
render() {
    rsvg-convert -w "$2" -h "$2" "$1" -o "$ICONSET/$3"
}

# Actual pixel sizes required in a macOS .icns:
#   16, 32, 64, 128, 256, 512, 1024
# Use compact SVG for ≤64, full SVG for ≥128.
render "$SVG_COMPACT"   16 icon_16x16.png
render "$SVG_COMPACT"   32 icon_16x16@2x.png
render "$SVG_COMPACT"   32 icon_32x32.png
render "$SVG_COMPACT"   64 icon_32x32@2x.png
render "$SVG_FULL"     128 icon_128x128.png
render "$SVG_FULL"     256 icon_128x128@2x.png
render "$SVG_FULL"     256 icon_256x256.png
render "$SVG_FULL"     512 icon_256x256@2x.png
render "$SVG_FULL"     512 icon_512x512.png
render "$SVG_FULL"    1024 icon_512x512@2x.png

iconutil -c icns "$ICONSET" -o "$BUILD_DIR/AppIcon.icns"
rm -rf "$ICONSET"

echo "✓ $BUILD_DIR/AppIcon.icns"
