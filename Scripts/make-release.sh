#!/bin/bash
# One-command release to GitHub Releases:
#   build → notarize → package → sign the Sparkle update → write the appcast →
#   publish a GitHub Release with the zip and appcast as assets.
#
#   ./Scripts/make-release.sh
#
# Sparkle's feed (SUFeedURL, baked into the app by build-app.sh) is:
#   https://github.com/<REPO>/releases/latest/download/appcast.xml
# which always resolves to the newest release's appcast. Override REPO to fork.
set -euo pipefail
cd "$(dirname "$0")/.."

REPO="${REPO:-gjeffrey/littleripper}"
APP="build/Little Ripper.app"
ZIP="build/LittleRipper.zip"           # fixed name: GitHub serves a fresh object per
                                       # release, so there's no stale-cache concern
APPCAST="build/appcast.xml"
SIGN_UPDATE="$(find .build -path '*/bin/sign_update' ! -path '*old_dsa*' 2>/dev/null | head -1)"

echo "▸ Building + notarizing…"
./Scripts/build-app.sh
./Scripts/notarize.sh

PLIST="$APP/Contents/Info.plist"
SHORT=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$PLIST")
BUILD=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$PLIST")
MINOS=$(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' "$PLIST")
TAG="v$SHORT-$BUILD"                    # unique per build (short version + timestamp)
FEED="https://github.com/$REPO/releases/latest/download/appcast.xml"
ENCLOSURE="https://github.com/$REPO/releases/download/$TAG/LittleRipper.zip"

echo "▸ Packaging $ZIP…"
rm -f "$ZIP"
ditto -c -k --keepParent "$APP" "$ZIP"
LEN=$(stat -f%z "$ZIP")

echo "▸ Signing the update (EdDSA)…"
[ -x "$SIGN_UPDATE" ] || { echo "sign_update not found — run 'swift build' first."; exit 1; }
SIG=$("$SIGN_UPDATE" "$ZIP" | sed -E 's/.*sparkle:edSignature="([^"]+)".*/\1/')

PUBDATE=$(date -u "+%a, %d %b %Y %H:%M:%S +0000")
echo "▸ Writing $APPCAST ($SHORT / $BUILD)…"
cat > "$APPCAST" <<XML
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
    <channel>
        <title>Little Ripper</title>
        <link>$FEED</link>
        <description>Updates for Little Ripper.</description>
        <language>en</language>
        <item>
            <title>$SHORT</title>
            <pubDate>$PUBDATE</pubDate>
            <sparkle:version>$BUILD</sparkle:version>
            <sparkle:shortVersionString>$SHORT</sparkle:shortVersionString>
            <sparkle:minimumSystemVersion>$MINOS</sparkle:minimumSystemVersion>
            <sparkle:hardwareRequirements>arm64</sparkle:hardwareRequirements>
            <enclosure url="$ENCLOSURE"
                       length="$LEN"
                       type="application/octet-stream"
                       sparkle:edSignature="$SIG" />
        </item>
    </channel>
</rss>
XML

echo "▸ Publishing GitHub Release $TAG on $REPO…"
gh release create "$TAG" "$ZIP" "$APPCAST" \
    --repo "$REPO" \
    --title "Little Ripper $SHORT ($BUILD)" \
    --notes "Automated release. Updates install in place via Sparkle." \
    --latest

echo "✓ Released $TAG"
echo "  Appcast (Sparkle feed): $FEED"
echo "  Download:               https://github.com/$REPO/releases/latest/download/LittleRipper.zip"
