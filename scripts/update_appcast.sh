#!/bin/bash
set -euo pipefail

# Update appcast.xml with a new version entry
#
# Usage: ./scripts/update_appcast.sh <version> <build> <dmg-path>

VERSION="$1"
BUILD="$2"
DMG_PATH="$3"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
APPCAST="$SCRIPT_DIR/../docs/appcast.xml"

DMG_SIZE=$(stat -f%z "$DMG_PATH" 2>/dev/null || stat -c%s "$DMG_PATH" 2>/dev/null)
PUB_DATE=$(date -u "+%a, %d %b %Y %H:%M:%S +0000")

NEW_ITEM="    <item>
      <title>Version $VERSION</title>
      <sparkle:version>$BUILD</sparkle:version>
      <sparkle:shortVersionString>$VERSION</sparkle:shortVersionString>
      <description>
        <![CDATA[
          <ul>
            <li>See release notes on GitHub</li>
          </ul>
        ]]>
      </description>
      <pubDate>$PUB_DATE</pubDate>
      <enclosure
        url=\"https://github.com/CodeBlog-ai/codeblog-mac/releases/download/v$VERSION/CodeBlog.dmg\"
        sparkle:version=\"$BUILD\"
        sparkle:shortVersionString=\"$VERSION\"
        length=\"$DMG_SIZE\"
        type=\"application/octet-stream\"
      />
    </item>"

# Insert new item after <language>en</language>
sed -i '' "/<language>en<\/language>/a\\
$NEW_ITEM
" "$APPCAST"

echo "==> Updated appcast.xml with v$VERSION (build $BUILD)"
