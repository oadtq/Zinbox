#!/bin/bash
# Assembles a double-clickable .app around the SwiftPM binary.
#
#   ./build.sh           debug-free release build, ad-hoc signed
#   ./build.sh debug     faster compile while iterating
set -euo pipefail

cd "$(dirname "$0")"
CONFIG="${1:-release}"
APP="build/Zinbox.app"
NAME="Zinbox"
VERSION="$(tr -d '[:space:]' < VERSION)"
BUILD="$(date +%Y%m%d%H%M)"
MINIMUM="14.0"

swift build -c "$CONFIG"
BINARY=".build/$CONFIG/Zinbox"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BINARY" "$APP/Contents/MacOS/$NAME"

if [ "$CONFIG" = "release" ]; then
  rm -rf "$APP.dSYM"
  dsymutil "$BINARY" -o "$APP.dSYM" 2>/dev/null || echo "no dSYM this time" >&2
  strip -x "$APP/Contents/MacOS/$NAME"
fi

ICONSET="build/AppIcon.iconset"
rm -rf "$ICONSET"
GLYPH="build/glyph.png"
swift Icon/icon.swift "$ICONSET" "$GLYPH" > /dev/null
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"

# macOS 26+ shows plain bitmap icons shrunk onto a grey plate. An Icon
# Composer icon (black fill + the bubbles layer), compiled to Assets.car and
# named by CFBundleIconName, gets the native shape. The .icns stays for older
# systems.
CATALOG="build/AppIcon.icon"
rm -rf "$CATALOG"
mkdir -p "$CATALOG/Assets"
mv "$GLYPH" "$CATALOG/Assets/glyph.png"
cp Icon/icon.json "$CATALOG/icon.json"
# actool runs in a helper process with its own working directory: absolute paths only.
xcrun actool --compile "$PWD/$APP/Contents/Resources" --platform macosx --minimum-deployment-target "$MINIMUM" \
  --app-icon AppIcon --output-partial-info-plist "$PWD/build/AssetsInfo.plist" "$PWD/$CATALOG" > /dev/null
rm -rf "$ICONSET" "$CATALOG" build/AssetsInfo.plist

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>$NAME</string>
  <key>CFBundleDisplayName</key><string>$NAME</string>
  <key>CFBundleExecutable</key><string>$NAME</string>
  <key>CFBundleIdentifier</key><string>app.zinbox</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$BUILD</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundleIconName</key><string>AppIcon</string>
  <key>LSMinimumSystemVersion</key><string>$MINIMUM</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.productivity</string>
  <key>NSHumanReadableCopyright</key><string>Zinbox</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSAppTransportSecurity</key>
  <dict><key>NSAllowsArbitraryLoads</key><true/></dict>
  <key>NSCameraUsageDescription</key>
  <string>Messaging sites you add can ask to use your camera for calls. Zinbox asks you the first time.</string>
  <key>NSMicrophoneUsageDescription</key>
  <string>Messaging sites you add can ask to use your microphone for calls. Zinbox asks you the first time.</string>
  <key>NSDownloadsFolderUsageDescription</key>
  <string>Files you download are saved to your Downloads folder.</string>
</dict>
</plist>
PLIST

if [ -f Zinbox.entitlements ]; then
  codesign --force --deep --sign - --entitlements Zinbox.entitlements "$APP" 2>/dev/null \
    || codesign --force --deep --sign - "$APP" 2>/dev/null || true
else
  codesign --force --deep --sign - "$APP" 2>/dev/null || true
fi

echo "built: $APP ($VERSION, build $BUILD)"
