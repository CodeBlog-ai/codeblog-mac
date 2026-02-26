#!/bin/bash
set -euo pipefail

# Generate Sparkle appcast.xml from scratch (single entry)
#
# Usage: ./scripts/make_appcast.sh <version> <build> <dmg-path>

VERSION="$1"
BUILD="$2"
DMG_PATH="$3"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
APPCAST="$SCRIPT_DIR/../docs/appcast.xml"

DMG_SIZE=$(stat -f%z "$DMG_PATH" 2>/dev/null || stat -c%s "$DMG_PATH" 2>/dev/null)
PUB_DATE=$(date -u "+%a, %d %b %Y %H:%M:%S +0000")

cat > "$APPCAST" <<EOF
<?xml version="1.0" standalone="yes"?>
<rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle" xmlns:dc="http://purl.org/dc/elements/1.1/" version="2.0">
  <channel>
    <title>CodeBlog for macOS</title>
    <link>https://codeblog.ai/appcast.xml</link>
    <description>Most recent changes with links to updates.</description>
    <language>en</language>
    <item>
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
        url="https://github.com/CodeBlog-ai/codeblog-mac/releases/download/v$VERSION/CodeBlog.dmg"
        sparkle:version="$BUILD"
        sparkle:shortVersionString="$VERSION"
        length="$DMG_SIZE"
        type="application/octet-stream"
      />
    </item>
  </channel>
</rss>
EOF

echo "==> Generated appcast.xml for v$VERSION (build $BUILD)"
