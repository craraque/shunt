#!/bin/bash
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
BUILD_DIR="$PROJECT_DIR/build"
APP_NAME="Shunt"
APP_BUNDLE="$BUILD_DIR/$APP_NAME.app"

MAIN_BUNDLE_ID="com.craraque.shunt"
EXT_BUNDLE_ID="com.craraque.shunt.proxy"
EXT_BUNDLE_NAME="$EXT_BUNDLE_ID.systemextension"

TEAM_ID="6NSZVJU6BP"
SIGN_IDENTITY="Developer ID Application: CESAR RAUL ARAQUE BLANCO ($TEAM_ID)"
NOTARY_PROFILE="ShuntNotary"

MAIN_PROFILE="$PROJECT_DIR/Resources/profiles/Shunt_Developer_ID.provisionprofile"
EXT_PROFILE="$PROJECT_DIR/Resources/profiles/Shunt_Proxy_Developer_ID.provisionprofile"

for p in "$MAIN_PROFILE" "$EXT_PROFILE"; do
    [[ -f "$p" ]] || { echo "ERROR: provisioning profile missing: $p"; exit 1; }
done

MODE="${1:-build}"

echo "▸ Cleaning previous build"
rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR"

echo "▸ Rendering app icon"
"$PROJECT_DIR/Scripts/render-icon.sh"

echo "▸ Building Shunt (main app)"
swift build -c release --arch arm64 --product "$APP_NAME" --package-path "$PROJECT_DIR"

echo "▸ Building ShuntProxy (system extension)"
swift build -c release --arch arm64 --product ShuntProxy --package-path "$PROJECT_DIR"

echo "▸ Building ShuntTest (CLI)"
swift build -c release --arch arm64 --product ShuntTest --package-path "$PROJECT_DIR"

echo "▸ Assembling .app bundle"
mkdir -p "$APP_BUNDLE/Contents/MacOS"
mkdir -p "$APP_BUNDLE/Contents/Resources"
mkdir -p "$APP_BUNDLE/Contents/Library/SystemExtensions/$EXT_BUNDLE_NAME/Contents/MacOS"

cp "$PROJECT_DIR/.build/release/$APP_NAME" "$APP_BUNDLE/Contents/MacOS/$APP_NAME"
cp "$PROJECT_DIR/Resources/Shunt-Info.plist" "$APP_BUNDLE/Contents/Info.plist"
cp "$BUILD_DIR/AppIcon.icns" "$APP_BUNDLE/Contents/Resources/AppIcon.icns"

EXT_PATH="$APP_BUNDLE/Contents/Library/SystemExtensions/$EXT_BUNDLE_NAME"
cp "$PROJECT_DIR/.build/release/ShuntProxy" "$EXT_PATH/Contents/MacOS/ShuntProxy"
cp "$PROJECT_DIR/Resources/ShuntProxy-Info.plist" "$EXT_PATH/Contents/Info.plist"

SHORT_VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$APP_BUNDLE/Contents/Info.plist")
COUNTER_FILE="$PROJECT_DIR/Scripts/.build-number"
if [[ -n "${BUILD_NUMBER:-}" ]]; then
    : "${BUILD_NUMBER:?}"
else
    PREV=$(cat "$COUNTER_FILE" 2>/dev/null || echo 0)
    BUILD_NUMBER=$((PREV + 1))
    echo "$BUILD_NUMBER" > "$COUNTER_FILE"
fi
echo "▸ Version $SHORT_VERSION build $BUILD_NUMBER"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $BUILD_NUMBER" "$APP_BUNDLE/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $BUILD_NUMBER" "$EXT_PATH/Contents/Info.plist"
# Only bump this when the app requires a newer provider runtime/protocol.
# Leave it unchanged for app-only UI/updater changes so macOS does not prompt
# for an unnecessary System Extension replacement.
if [[ -n "${MIN_REQUIRED_EXTENSION_BUILD:-}" ]]; then
    /usr/libexec/PlistBuddy -c "Set :ShuntMinimumRequiredExtensionBuild $MIN_REQUIRED_EXTENSION_BUILD" "$APP_BUNDLE/Contents/Info.plist"
fi

echo "▸ Embedding provisioning profiles"
cp "$MAIN_PROFILE" "$APP_BUNDLE/Contents/embedded.provisionprofile"
cp "$EXT_PROFILE" "$EXT_PATH/Contents/embedded.provisionprofile"

echo "▸ Signing system extension"
codesign --force --options runtime --timestamp \
    --entitlements "$PROJECT_DIR/Resources/ShuntProxy.entitlements" \
    --sign "$SIGN_IDENTITY" \
    "$EXT_PATH"

echo "▸ Signing main app"
codesign --force --options runtime --timestamp \
    --entitlements "$PROJECT_DIR/Resources/Shunt.entitlements" \
    --sign "$SIGN_IDENTITY" \
    "$APP_BUNDLE"

echo "▸ Assembling + signing ShuntTest.app"
TEST_APP="$BUILD_DIR/ShuntTest.app"
mkdir -p "$TEST_APP/Contents/MacOS"
mkdir -p "$TEST_APP/Contents/Resources"
cp "$PROJECT_DIR/.build/release/ShuntTest" "$TEST_APP/Contents/MacOS/ShuntTest"
cp "$PROJECT_DIR/Resources/ShuntTest-Info.plist" "$TEST_APP/Contents/Info.plist"
cp "$BUILD_DIR/AppIconTest.icns" "$TEST_APP/Contents/Resources/AppIcon.icns"
codesign --force --options runtime --timestamp \
    --sign "$SIGN_IDENTITY" \
    "$TEST_APP"

echo "▸ Verifying signatures"
codesign --verify --deep --strict --verbose=2 "$APP_BUNDLE"
echo

if [[ "$MODE" == "notarize" ]]; then
    ZIP_PATH="$BUILD_DIR/$APP_NAME.zip"
    echo "▸ Creating zip for notarization"
    ditto -c -k --keepParent "$APP_BUNDLE" "$ZIP_PATH"

    echo "▸ Submitting to Apple notary service (this takes 1-5 min)"
    xcrun notarytool submit "$ZIP_PATH" \
        --keychain-profile "$NOTARY_PROFILE" \
        --wait

    echo "▸ Stapling ticket"
    xcrun stapler staple "$APP_BUNDLE"
    xcrun stapler validate "$APP_BUNDLE"

    echo "▸ Gatekeeper assessment"
    spctl -a -vvv -t install "$APP_BUNDLE" || true

    rm -f "$ZIP_PATH"

    # System extension activation requires the app to live under /Applications.
    # Replace any previous copy in place so the user can re-launch immediately.
    if [[ "${SKIP_INSTALL:-}" != "1" ]]; then
        INSTALL_PATH="/Applications/$APP_NAME.app"
        echo "▸ Installing to $INSTALL_PATH (set SKIP_INSTALL=1 to opt out)"
        # Stop any currently-running copy so we can overwrite its bundle.
        pkill -f "$APP_NAME.app/Contents/MacOS/$APP_NAME" 2>/dev/null || true
        sleep 0.3
        rm -rf "$INSTALL_PATH"
        cp -R "$APP_BUNDLE" "$INSTALL_PATH"
        echo "  installed — launch with: open \"$INSTALL_PATH\""
    fi
fi

echo
echo "✓ Built: $APP_BUNDLE"
echo
echo "Next:"
if [[ "$MODE" != "notarize" ]]; then
    echo "  • Run with notarization: ./Scripts/build.sh notarize"
fi
echo "  • Open: open \"$APP_BUNDLE\""
echo "  • Stream logs: log stream --predicate 'subsystem BEGINSWITH \"com.craraque.shunt\"' --info"
