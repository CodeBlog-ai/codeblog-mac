#!/bin/bash
set -euo pipefail

# CodeBlog macOS — Full release pipeline
#
# Usage: ./scripts/release.sh <version> [--dry-run]
#   e.g. ./scripts/release.sh 2.0.2
#        ./scripts/release.sh 2.0.2 --dry-run
#
# Steps:
#   1. Validate environment (clean worktree, gh auth)
#   2. Bump version in Info.plist
#   3. Build DMG (calls release_dmg.sh)
#   4. Sign update with Sparkle (if key available)
#   5. Git commit + tag (v-prefixed)
#   6. Git push (branch + tag)
#   7. Create GitHub Release with DMG
#   8. Update appcast.xml, commit + push

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
APP_NAME="CodeBlog"
INFO_PLIST="$PROJECT_DIR/$APP_NAME/Info.plist"
APPCAST="$PROJECT_DIR/docs/appcast.xml"

# Load env
if [ -f "$SCRIPT_DIR/release.env" ]; then
  source "$SCRIPT_DIR/release.env"
fi

# --- Parse arguments ---
DRY_RUN=false
VERSION=""

for arg in "$@"; do
  case "$arg" in
    --dry-run) DRY_RUN=true ;;
    -*) echo "Unknown option: $arg"; exit 1 ;;
    *) VERSION="$arg" ;;
  esac
done

if [ -z "$VERSION" ]; then
  CURRENT=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" "$INFO_PLIST")
  CURRENT_BUILD=$(/usr/libexec/PlistBuddy -c "Print CFBundleVersion" "$INFO_PLIST")
  echo "CodeBlog Release Script"
  echo ""
  echo "Current version: $CURRENT (build $CURRENT_BUILD)"
  echo ""
  echo "Usage: $0 <version> [--dry-run]"
  echo "  e.g. $0 2.0.2"
  echo "       $0 2.0.2 --dry-run"
  exit 1
fi

# --- Pre-flight checks ---
CURRENT_VERSION=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" "$INFO_PLIST")
CURRENT_BUILD=$(/usr/libexec/PlistBuddy -c "Print CFBundleVersion" "$INFO_PLIST")
NEW_BUILD=$((CURRENT_BUILD + 1))
TAG="v$VERSION"

echo "==> Pre-flight checks..."

# Check gh CLI
if ! command -v gh &>/dev/null; then
  echo "ERROR: gh CLI not found. Install: brew install gh"
  exit 1
fi

if ! gh auth status &>/dev/null; then
  echo "ERROR: gh not authenticated. Run: gh auth login"
  exit 1
fi

# Check clean worktree (allow Info.plist and appcast changes)
DIRTY=$(git status --porcelain | grep -v "Info.plist" | grep -v "appcast.xml" || true)
if [ -n "$DIRTY" ]; then
  echo "ERROR: Working directory has uncommitted changes:"
  echo "$DIRTY"
  echo ""
  echo "Commit or stash changes before releasing."
  exit 1
fi

# Check tag doesn't exist
if git rev-parse "$TAG" &>/dev/null; then
  echo "ERROR: Tag $TAG already exists."
  exit 1
fi

# --- Confirm ---
echo ""
echo "  Version:  $CURRENT_VERSION → $VERSION"
echo "  Build:    $CURRENT_BUILD → $NEW_BUILD"
echo "  Tag:      $TAG"
echo ""

if [ "$DRY_RUN" = true ]; then
  echo "[DRY RUN] Would execute:"
  echo "  1. Bump Info.plist to $VERSION (build $NEW_BUILD)"
  echo "  2. Build DMG via release_dmg.sh"
  echo "  3. Sparkle sign (if key available)"
  echo "  4. Git commit + tag $TAG"
  echo "  5. Git push origin main + $TAG"
  echo "  6. GitHub Release: $TAG with DMG"
  echo "  7. Update appcast.xml, commit + push"
  exit 0
fi

printf "Proceed? [y/N] "
read -r CONFIRM
if [[ ! "$CONFIRM" =~ ^[Yy]$ ]]; then
  echo "Aborted."
  exit 1
fi

# --- 1. Bump version ---
echo ""
echo "==> [1/7] Bumping version: $VERSION (build $NEW_BUILD)"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$INFO_PLIST"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $NEW_BUILD" "$INFO_PLIST"

# --- 2. Build DMG ---
echo ""
echo "==> [2/7] Building DMG..."
"$SCRIPT_DIR/release_dmg.sh"

DMG_PATH="$PROJECT_DIR/build/$APP_NAME.dmg"
if [ ! -f "$DMG_PATH" ]; then
  echo "ERROR: DMG not found at $DMG_PATH"
  exit 1
fi

echo "  DMG size: $(du -h "$DMG_PATH" | cut -f1)"

# --- 3. Sparkle sign ---
echo ""
echo "==> [3/7] Sparkle signing..."
if [ -n "${SPARKLE_KEY_FILE:-}" ] && [ -f "${SPARKLE_KEY_FILE}" ]; then
  SPARKLE_SIG=$("$SCRIPT_DIR/sparkle_sign_from_keychain.sh" "$DMG_PATH" 2>/dev/null || echo "")
  if [ -n "$SPARKLE_SIG" ]; then
    echo "  Signature: ${SPARKLE_SIG:0:40}..."
  else
    echo "  WARNING: Sparkle signing failed (continuing without)"
  fi
else
  echo "  Skipped (no SPARKLE_KEY_FILE configured)"
fi

# --- 4. Git commit + tag ---
echo ""
echo "==> [4/7] Committing version bump..."
cd "$PROJECT_DIR"
git add "$INFO_PLIST"
git commit -m "release: v$VERSION (build $NEW_BUILD)"
git tag "$TAG"

# --- 5. Git push ---
echo ""
echo "==> [5/7] Pushing to origin..."
git push origin main
git push origin "$TAG"

# --- 6. GitHub Release ---
echo ""
echo "==> [6/7] Creating GitHub Release..."
gh release create "$TAG" \
  --title "CodeBlog $VERSION" \
  --generate-notes \
  "$DMG_PATH"

RELEASE_URL=$(gh release view "$TAG" --json url -q .url)
echo "  Release: $RELEASE_URL"

# --- 7. Update appcast ---
echo ""
echo "==> [7/7] Updating appcast.xml..."
"$SCRIPT_DIR/update_appcast.sh" "$VERSION" "$NEW_BUILD" "$DMG_PATH"

git add "$APPCAST"
git commit -m "chore: update appcast for v$VERSION"
git push origin main

# --- Done ---
echo ""
echo "================================================"
echo "  CodeBlog v$VERSION released successfully!"
echo "  $RELEASE_URL"
echo "================================================"
