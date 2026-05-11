#!/bin/bash
#
# release.sh — package + publish a Shunt release.
#
# Pipeline:
#   1. Build + sign + notarize Shunt.app via Scripts/build.sh notarize
#   2. Bundle Shunt.app into a Developer ID-signed, notarized DMG
#   3. Tag the current commit as vX.Y.Z (from CFBundleShortVersionString)
#   4. Push the tag to origin
#   5. Create a GitHub release attaching the DMG
#
# Idempotent: if the tag already exists locally, we skip retagging but still
# upload the DMG (`gh release upload --clobber`). If no GitHub release exists
# for that tag, we create one.
#
# Requires: gh CLI authenticated for the target repository.
#
# Output: a public release at github.com/$GH_REPO/releases/tag/vX.Y.Z
# whose DMG is what `UpdateChecker` polls for.

set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
BUILD_DIR="$PROJECT_DIR/build"
APP_NAME="Shunt"
APP_BUNDLE="$BUILD_DIR/$APP_NAME.app"
DMG_PATH="$BUILD_DIR/$APP_NAME.dmg"
DMG_VOL_NAME="Shunt"

TEAM_ID="${SHUNT_TEAM_ID:-6NSZVJU6BP}"
SIGN_IDENTITY="${SHUNT_SIGN_IDENTITY:-}"
NOTARY_PROFILE="${SHUNT_NOTARY_PROFILE:-DeveloperIDNotaryProfile}"

if [[ -z "$SIGN_IDENTITY" ]]; then
    echo "ERROR: set SHUNT_SIGN_IDENTITY to your Developer ID Application signing identity"
    exit 1
fi
GH_REPO="${GH_REPO:-craraque/shunt}"

# Pre-flight
command -v gh >/dev/null 2>&1 || { echo "ERROR: gh CLI not found"; exit 1; }
gh auth status -h github.com >/dev/null 2>&1 || { echo "ERROR: gh not authed"; exit 1; }

# Step 1 — produce a notarized .app under build/
"$PROJECT_DIR/Scripts/build.sh" notarize

[[ -d "$APP_BUNDLE" ]] || { echo "ERROR: build did not produce $APP_BUNDLE"; exit 1; }

VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$APP_BUNDLE/Contents/Info.plist")
BUILD_NUMBER=$(/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" "$APP_BUNDLE/Contents/Info.plist")
TAG="v$VERSION"
echo "▸ Releasing $TAG (build $BUILD_NUMBER)"

# Step 2 — DMG. Use hdiutil's UDZO compression with the .app inside +
# a symlink to /Applications so the user can drag-install. No fancy
# layout (background image, custom volume icon) — keeps it minimal and
# scriptable. We can polish in a later iteration.
echo "▸ Building DMG"
DMG_STAGING="$BUILD_DIR/dmg-staging"
rm -rf "$DMG_STAGING" "$DMG_PATH"
mkdir -p "$DMG_STAGING"
cp -R "$APP_BUNDLE" "$DMG_STAGING/$APP_NAME.app"
ln -s /Applications "$DMG_STAGING/Applications"

hdiutil create \
    -volname "$DMG_VOL_NAME" \
    -srcfolder "$DMG_STAGING" \
    -ov \
    -format UDZO \
    -fs HFS+ \
    "$DMG_PATH"

rm -rf "$DMG_STAGING"

# Sign + notarize the DMG itself so Gatekeeper accepts it on first
# download (the .app inside is already notarized, but the DMG wrapper
# also needs its own ticket for the "downloaded from the internet"
# quarantine path).
echo "▸ Signing DMG"
codesign --force --timestamp --sign "$SIGN_IDENTITY" "$DMG_PATH"

echo "▸ Submitting DMG to Apple notary service"
xcrun notarytool submit "$DMG_PATH" \
    --keychain-profile "$NOTARY_PROFILE" \
    --wait

echo "▸ Stapling DMG"
xcrun stapler staple "$DMG_PATH"
xcrun stapler validate "$DMG_PATH"

# Step 3 — tag (idempotent)
if git rev-parse "$TAG" >/dev/null 2>&1; then
    echo "▸ Tag $TAG already exists locally — skipping retag"
else
    echo "▸ Tagging $TAG"
    git tag -a "$TAG" -m "Shunt $TAG (build $BUILD_NUMBER)"
fi

# Step 4 — push tag (idempotent)
if git ls-remote --tags origin "refs/tags/$TAG" | grep -q "$TAG"; then
    echo "▸ Tag $TAG already on origin — skipping push"
else
    echo "▸ Pushing $TAG to origin"
    git push origin "$TAG"
fi

# Step 5 — GitHub release (create or upload)
DMG_FILENAME="Shunt-$TAG.dmg"
DMG_RENAMED="$BUILD_DIR/$DMG_FILENAME"
cp "$DMG_PATH" "$DMG_RENAMED"

if gh release view "$TAG" --repo "$GH_REPO" >/dev/null 2>&1; then
    echo "▸ Release $TAG exists — uploading asset (clobbering)"
    gh release upload "$TAG" "$DMG_RENAMED" --repo "$GH_REPO" --clobber
else
    echo "▸ Creating release $TAG"
    gh release create "$TAG" "$DMG_RENAMED" \
        --repo "$GH_REPO" \
        --title "Shunt $TAG" \
        --generate-notes
fi

echo
echo "✓ Released: https://github.com/$GH_REPO/releases/tag/$TAG"
echo "  DMG: $DMG_RENAMED"
