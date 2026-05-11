#!/bin/bash
# Render Resources/Icon*.svg into macOS .icns files.
#   Icon.svg + Icon-compact.svg  → build/AppIcon.icns        (main Shunt.app)
#   Icon-test.svg + Icon-test-compact.svg → build/AppIconTest.icns (ShuntTest.app)
# build.sh copies each .icns into the corresponding bundle's Resources/.
#
# Uses rsvg-convert (brew install librsvg) for crisp vector → raster output.

set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
BUILD_DIR="$PROJECT_DIR/build"

command -v rsvg-convert >/dev/null || { echo "ERROR: rsvg-convert missing. Run: brew install librsvg"; exit 1; }

# render_icon <full_svg> <compact_svg> <output_icns_name>
render_icon() {
    local svg_full="$1"
    local svg_compact="$2"
    local icns_name="$3"
    local iconset="$BUILD_DIR/${icns_name%.icns}.iconset"

    [[ -f "$svg_full" ]] || { echo "ERROR: $svg_full not found"; exit 1; }
    [[ -f "$svg_compact" ]] || { echo "ERROR: $svg_compact not found"; exit 1; }

    rm -rf "$iconset"
    mkdir -p "$iconset"

    # Actual pixel sizes required in a macOS .icns:
    #   16, 32, 64, 128, 256, 512, 1024
    # Use compact SVG for ≤64, full SVG for ≥128.
    rsvg-convert -w   16 -h   16 "$svg_compact" -o "$iconset/icon_16x16.png"
    rsvg-convert -w   32 -h   32 "$svg_compact" -o "$iconset/icon_16x16@2x.png"
    rsvg-convert -w   32 -h   32 "$svg_compact" -o "$iconset/icon_32x32.png"
    rsvg-convert -w   64 -h   64 "$svg_compact" -o "$iconset/icon_32x32@2x.png"
    rsvg-convert -w  128 -h  128 "$svg_full"    -o "$iconset/icon_128x128.png"
    rsvg-convert -w  256 -h  256 "$svg_full"    -o "$iconset/icon_128x128@2x.png"
    rsvg-convert -w  256 -h  256 "$svg_full"    -o "$iconset/icon_256x256.png"
    rsvg-convert -w  512 -h  512 "$svg_full"    -o "$iconset/icon_256x256@2x.png"
    rsvg-convert -w  512 -h  512 "$svg_full"    -o "$iconset/icon_512x512.png"
    rsvg-convert -w 1024 -h 1024 "$svg_full"    -o "$iconset/icon_512x512@2x.png"

    iconutil -c icns "$iconset" -o "$BUILD_DIR/$icns_name"
    rm -rf "$iconset"

    echo "✓ $BUILD_DIR/$icns_name"
}

render_icon "$PROJECT_DIR/Resources/Icon.svg"       "$PROJECT_DIR/Resources/Icon-compact.svg"       "AppIcon.icns"
render_icon "$PROJECT_DIR/Resources/Icon-test.svg"  "$PROJECT_DIR/Resources/Icon-test-compact.svg"  "AppIconTest.icns"
