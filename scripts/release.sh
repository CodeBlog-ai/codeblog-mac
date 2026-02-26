#!/bin/bash
set -euo pipefail

# CodeBlog macOS — Full release pipeline
#
# Usage: ./scripts/release.sh [version]
#   e.g. ./scripts/release.sh 1.9.0
#
# Steps:
#   1. Bump version in Info.plist
#   2. Build DMG (calls release_dmg.sh)
#   3. Sign update with Sparkle
#   4. Create GitHub Release
#   5. Update appcast.xml
#   6. Commit and push

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
APP_NAME="CodeBlog"
INFO_PLIST="$PROJECT_DIR/$APP_NAME/Info.plist"
APPCAST="$PROJECT_DIR/docs/appcast.xml"

# Load env
if [ -f "$SCRIPT_DIR/release.env" ]; then
  source "$SCRIPT_DIR/release.env"
fi

# Get version
VERSION="${1:-}"
if [ -z "$VERSION" ]; then
  CURRENT=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" "$INFO_PLIST")
  echo "Current version: $CURRENT"
  echo "Usage: $0 <new-version>"
  exit 1
fi

# Bump build number
CURRENT_BUILD=$(/usr/libexec/PlistBuddy -c "Print CFBundleVersion" "$INFO_PLIST")
NEW_BUILD=$((CURRENT_BUILD + 1))

echo "==> Bumping version: $VERSION (build $NEW_BUILD)"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$INFO_PLIST"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $NEW_BUILD" "$INFO_PLIST"

# Build DMG
echo "==> Building DMG..."
"$SCRIPT_DIR/release_dmg.sh"

DMG_PATH="$PROJECT_DIR/build/$APP_NAME.dmg"
if [ ! -f "$DMG_PATH" ]; then
  echo "ERROR: DMG not found at $DMG_PATH"
  exit 1
fi

# Sparkle sign
if [ -n "${SPARKLE_KEY_FILE:-}" ] && [ -f "${SPARKLE_KEY_FILE}" ]; then
  echo "==> Signing with Sparkle..."
  SPARKLE_SIG=$(./scripts/sparkle_sign_from_keychain.sh "$DMG_PATH" 2>/dev/null || echo "")
  echo "Sparkle signature: $SPARKLE_SIG"
fi

# GitHub Release
if [ -n "${GITHUB_TOKEN:-}" ]; then
  echo "==> Creating GitHub Release v$VERSION..."
  gh release create "v$VERSION" \
    --title "v$VERSION" \
    --notes "CodeBlog for macOS v$VERSION (build $NEW_BUILD)" \
    "$DMG_PATH"
fi

# Update appcast
echo "==> Updating appcast.xml..."
"$SCRIPT_DIR/update_appcast.sh" "$VERSION" "$NEW_BUILD" "$DMG_PATH"

# Commit
echo "==> Committing version bump..."
cd "$PROJECT_DIR"
git add "$INFO_PLIST" "$APPCAST"
git commit -m "release: v$VERSION (build $NEW_BUILD)"
git tag "v$VERSION"

echo "==> Done! Don't forget to: git push && git push --tags"
