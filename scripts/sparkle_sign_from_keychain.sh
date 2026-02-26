#!/bin/bash
set -euo pipefail

# Sign a Sparkle update using Ed25519 key from Keychain or file
#
# Usage: ./scripts/sparkle_sign_from_keychain.sh <dmg-path>

DMG_PATH="$1"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

if [ -f "$SCRIPT_DIR/release.env" ]; then
  source "$SCRIPT_DIR/release.env"
fi

KEY_FILE="${SPARKLE_KEY_FILE:-$HOME/.sparkle/ed25519_private_key}"

if [ ! -f "$KEY_FILE" ]; then
  echo "ERROR: Sparkle private key not found at $KEY_FILE"
  echo "Generate one with: ./Sparkle.framework/bin/generate_keys"
  exit 1
fi

# Use Sparkle's sign_update tool if available
SIGN_TOOL=$(find /Library/Frameworks/Sparkle.framework ~/Library/Frameworks/Sparkle.framework -name "sign_update" 2>/dev/null | head -1)

if [ -n "$SIGN_TOOL" ]; then
  "$SIGN_TOOL" "$DMG_PATH" --ed-key-file "$KEY_FILE"
else
  echo "WARNING: Sparkle sign_update tool not found."
  echo "Install Sparkle framework or use: brew install sparkle"
  exit 1
fi
