#!/bin/bash
# Builds Little Ripper.app into ./build
#
# Forking? Override any of these with environment variables to point the build at your
# own identity, update feed, and Sparkle signing key — e.g.:
#   BUNDLE_ID=com.example.littleripper \
#   FEED_URL=https://example.com/littleripper/appcast.xml \
#   SU_PUBLIC_ED_KEY="$(./bin/generate_keys -p)" ./Scripts/build-app.sh
# Signing identity is picked automatically (see below) or set via SIGN_IDENTITY.
set -euo pipefail
cd "$(dirname "$0")/.."

APP_NAME="${APP_NAME:-Little Ripper}"
BUNDLE_ID="${BUNDLE_ID:-com.gabrieljeffrey.littleripper}"
BUILD_DIR="build"
APP="$BUILD_DIR/$APP_NAME.app"
SHORT_VERSION="${SHORT_VERSION:-1.0}"
BUILD_VERSION="${BUILD_VERSION:-$(date +%Y%m%d%H%M)}"   # Sparkle sparkle:version — sortable timestamp
FEED_URL="${FEED_URL:-https://github.com/gjeffrey/littleripper/releases/latest/download/appcast.xml}"
# Sparkle EdDSA *public* key for update verification (not a secret). Replace with your
# own from `generate_keys` if you distribute your own signed updates.
SU_PUBLIC_ED_KEY="${SU_PUBLIC_ED_KEY:-TM8yvT30uFU2LjT3tGN72/bwV1tjrtjZjpnqX9Avtyc=}"

echo "▸ Compiling (release)…"
swift build -c release

echo "▸ Assembling $APP…"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp ".build/release/LittleRipper" "$APP/Contents/MacOS/$APP_NAME"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleName</key><string>$APP_NAME</string>
	<key>CFBundleDisplayName</key><string>$APP_NAME</string>
	<key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
	<key>CFBundleExecutable</key><string>$APP_NAME</string>
	<key>CFBundlePackageType</key><string>APPL</string>
	<key>CFBundleShortVersionString</key><string>$SHORT_VERSION</string>
	<key>CFBundleVersion</key><string>$BUILD_VERSION</string>
	<key>CFBundleIconFile</key><string>AppIcon</string>
	<key>LSMinimumSystemVersion</key><string>14.0</string>
	<key>LSApplicationCategoryType</key><string>public.app-category.utilities</string>
	<key>NSHumanReadableCopyright</key><string>Rips discs so you don't have to.</string>
	<key>SUFeedURL</key><string>$FEED_URL</string>
	<key>SUPublicEDKey</key><string>$SU_PUBLIC_ED_KEY</string>
	<key>SUEnableInstallerLauncherService</key><true/>
</dict>
</plist>
PLIST

# Icon (regenerate only when missing)
if [ ! -f "$BUILD_DIR/AppIcon.icns" ]; then
    echo "▸ Rendering app icon…"
    mkdir -p "$BUILD_DIR/AppIcon.iconset"
    swift Scripts/make-icon.swift "$BUILD_DIR/icon-1024.png" > /dev/null
    for size in 16 32 128 256 512; do
        sips -z $size $size "$BUILD_DIR/icon-1024.png" --out "$BUILD_DIR/AppIcon.iconset/icon_${size}x${size}.png" > /dev/null
        double=$((size * 2))
        sips -z $double $double "$BUILD_DIR/icon-1024.png" --out "$BUILD_DIR/AppIcon.iconset/icon_${size}x${size}@2x.png" > /dev/null
    done
    iconutil -c icns "$BUILD_DIR/AppIcon.iconset" -o "$BUILD_DIR/AppIcon.icns"
    rm -rf "$BUILD_DIR/AppIcon.iconset" "$BUILD_DIR/icon-1024.png"
fi
cp "$BUILD_DIR/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"

# --- Bundle the audio-CD engines so no Homebrew is needed (drag-and-drop install) ---
# MakeMKV (DVD/Blu-ray) can't be bundled — it's a licensed GUI app with its own key,
# so video ripping still requires installing MakeMKV once. Audio works out of the box.
echo "▸ Bundling audio engines (cd-paranoia, flac) + their libraries…"
HELPERS="$APP/Contents/Helpers"
LIBS="$APP/Contents/libs"
mkdir -p "$HELPERS"
for tool in cd-paranoia flac metaflac; do
    src="$(command -v "$tool" || true)"
    if [ -z "$src" ]; then
        echo "  ⚠︎  $tool not found on PATH — install it (brew install libcdio-paranoia flac) and rebuild."
        continue
    fi
    cp "$src" "$HELPERS/$tool"
done
chmod u+w "$HELPERS"/* 2>/dev/null || true

# Gather every non-system dylib into Contents/libs and rewrite load paths to be
# relative to the app, so the binaries run on a machine that has never seen Homebrew.
XARGS=()
for tool in cd-paranoia flac metaflac; do
    [ -f "$HELPERS/$tool" ] && XARGS+=(-x "$HELPERS/$tool")
done
if [ ${#XARGS[@]} -gt 0 ]; then
    dylibbundler -of -cd -b -d "$LIBS" -p "@executable_path/../libs/" "${XARGS[@]}" > /dev/null
fi

# --- Embed Sparkle.framework (auto-updates); the exe finds it via the rpath set in
#     Package.swift (@executable_path/../Frameworks) ---
FRAMEWORKS="$APP/Contents/Frameworks"
SPARKLE_SRC="$(find .build -path '*macos-arm64*/Sparkle.framework' -type d 2>/dev/null | head -1)"
if [ -n "$SPARKLE_SRC" ]; then
    echo "▸ Embedding Sparkle.framework…"
    mkdir -p "$FRAMEWORKS"
    rm -rf "$FRAMEWORKS/Sparkle.framework"
    cp -R "$SPARKLE_SRC" "$FRAMEWORKS/Sparkle.framework"
else
    echo "  ⚠︎  Sparkle.framework not found — run 'swift build' first. Auto-updates disabled."
fi

# --- Sign (Developer ID + hardened runtime for notarization; else ad-hoc) ---
# Pick the Developer ID Application identity unless SIGN_IDENTITY overrides it.
IDENTITY="${SIGN_IDENTITY:-$(security find-identity -v -p codesigning | awk -F\" '/Developer ID Application/{print $2; exit}')}"
if [ -n "$IDENTITY" ]; then
    echo "▸ Signing (Developer ID + hardened runtime): $IDENTITY"
    SIGN=(codesign --force --timestamp --options runtime --sign "$IDENTITY")
else
    echo "▸ Signing (ad-hoc — NOT notarizable; no Developer ID cert found)"
    SIGN=(codesign --force --sign -)
fi
# Sign nested code first (inside-out), then seal the bundle. (--deep is deprecated and
# skips our non-standard Helpers/libs folders, so sign them explicitly.)
[ -d "$LIBS" ] && find "$LIBS" -name '*.dylib' -exec "${SIGN[@]}" {} +
find "$HELPERS" -type f -exec "${SIGN[@]}" {} + 2>/dev/null || true

# Sparkle's nested code (XPC services, Autoupdate, Updater.app) must each be re-signed
# with our identity + hardened runtime. Downloader.xpc keeps its network entitlement.
SP="$FRAMEWORKS/Sparkle.framework/Versions/B"
if [ -d "$SP" ]; then
    for xpc in "$SP"/XPCServices/*.xpc; do
        [ -e "$xpc" ] && "${SIGN[@]}" --preserve-metadata=entitlements "$xpc"
    done
    [ -e "$SP/Autoupdate" ] && "${SIGN[@]}" "$SP/Autoupdate"
    [ -e "$SP/Updater.app" ] && "${SIGN[@]}" "$SP/Updater.app"
    "${SIGN[@]}" "$FRAMEWORKS/Sparkle.framework"
fi

"${SIGN[@]}" "$APP/Contents/MacOS/$APP_NAME"
"${SIGN[@]}" "$APP"

echo "▸ Verifying…"
codesign --verify --strict --deep "$APP" && echo "  codesign OK"

echo "✓ Built $APP"
