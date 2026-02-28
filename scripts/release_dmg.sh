#!/bin/bash
set -euo pipefail

# CodeBlog macOS — Build, sign, notarize, and package as DMG
#
# Usage: ./scripts/release_dmg.sh
#
# Requires: Xcode, create-dmg, codesign identity, notarytool credentials

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
APP_NAME="CodeBlog"
SCHEME="CodeBlog"
BUILD_DIR="$PROJECT_DIR/build"
ARCHIVE_PATH="$BUILD_DIR/$APP_NAME.xcarchive"
EXPORT_PATH="$BUILD_DIR/export"
DMG_OUTPUT="$BUILD_DIR/$APP_NAME.dmg"

# Load env
if [ -f "$SCRIPT_DIR/release.env" ]; then
  source "$SCRIPT_DIR/release.env"
fi

echo "==> Cleaning build directory..."
rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR"

echo "==> Archiving $APP_NAME..."
xcodebuild archive \
  -project "$PROJECT_DIR/$APP_NAME.xcodeproj" \
  -scheme "$SCHEME" \
  -archivePath "$ARCHIVE_PATH" \
  -configuration Release \
  SKIP_INSTALL=NO \
  BUILD_LIBRARY_FOR_DISTRIBUTION=YES

echo "==> Exporting archive..."
xcodebuild -exportArchive \
  -archivePath "$ARCHIVE_PATH" \
  -exportOptionsPlist "$PROJECT_DIR/scripts/ExportOptions.plist" \
  -exportPath "$EXPORT_PATH" 2>/dev/null || true

APP_PATH="$EXPORT_PATH/$APP_NAME.app"
if [ ! -d "$APP_PATH" ]; then
  APP_PATH="$ARCHIVE_PATH/Products/Applications/$APP_NAME.app"
fi

echo "==> App bundle: $APP_PATH"

# Notarize if credentials are set
if [ -n "${APPLE_ID:-}" ] && [ -n "${APPLE_PASSWORD:-}" ] && [ -n "${TEAM_ID:-}" ]; then
  echo "==> Creating zip for notarization..."
  ZIP_PATH="$BUILD_DIR/$APP_NAME.zip"
  ditto -c -k --keepParent "$APP_PATH" "$ZIP_PATH"

  echo "==> Submitting for notarization..."
  xcrun notarytool submit "$ZIP_PATH" \
    --apple-id "$APPLE_ID" \
    --password "$APPLE_PASSWORD" \
    --team-id "$TEAM_ID" \
    --wait

  echo "==> Stapling notarization ticket..."
  xcrun stapler staple "$APP_PATH"
fi

# Create DMG
echo "==> Creating DMG..."
if command -v create-dmg &>/dev/null; then
  DMG_BG="$PROJECT_DIR/docs/assets/dmg-background.png"

  # Background is 1600x800 @2x retina; window is displayed at @1x (800x400)
  # Icon at left (200, 190), Applications link at right (600, 185)
  CREATE_DMG_ARGS=(
    --volname "$APP_NAME"
    --window-pos 200 120
    --window-size 800 400
    --icon-size 120
    --icon "$APP_NAME.app" 200 190
    --hide-extension "$APP_NAME.app"
    --app-drop-link 600 185
    --no-internet-enable
  )

  if [ -f "$DMG_BG" ]; then
    CREATE_DMG_ARGS+=(--background "$DMG_BG")
  fi

  create-dmg "${CREATE_DMG_ARGS[@]}" "$DMG_OUTPUT" "$APP_PATH"
else
  echo "create-dmg not found. Install with: brew install create-dmg"
  hdiutil create -volname "$APP_NAME" -srcfolder "$APP_PATH" -ov -format UDZO "$DMG_OUTPUT"
fi

echo "==> Done: $DMG_OUTPUT"
