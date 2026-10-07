#!/bin/bash
# Assembles a double-clickable .app around the SwiftPM binaries.
#
#   ./build.sh           release build, ad-hoc signed
#   ./build.sh debug     faster compile while iterating
#
# The first run downloads Chromium (CEF, ~130 MB) into vendor/cef.
set -euo pipefail

cd "$(dirname "$0")"
CONFIG="${1:-release}"
APP="build/Zinbox.app"
NAME="Zinbox"
VERSION="$(tr -d '[:space:]' < VERSION)"
BUILD="$(date +%Y%m%d%H%M)"
MINIMUM="14.0"
CEF="vendor/cef/Release/Chromium Embedded Framework.framework"

./scripts/fetch-cef.sh
swift build -c "$CONFIG"
BIN=".build/$CONFIG"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Frameworks"
cp "$BIN/Zinbox" "$APP/Contents/MacOS/$NAME"

# Chromium: the framework, and one helper app per process type it launches.
ditto "$CEF" "$APP/Contents/Frameworks/Chromium Embedded Framework.framework"
for kind in "" " (GPU)" " (Renderer)" " (Plugin)" " (Alerts)"; do
  helper="$NAME Helper$kind"
  dir="$APP/Contents/Frameworks/$helper.app/Contents"
  mkdir -p "$dir/MacOS"
  cp "$BIN/ZinboxHelper" "$dir/MacOS/$helper"
  suffix="$(echo "$kind" | tr -d ' ()' | tr '[:upper:]' '[:lower:]')"
  cat > "$dir/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key><string>$helper</string>
  <key>CFBundleName</key><string>$helper</string>
  <key>CFBundleIdentifier</key><string>app.zinbox.helper${suffix:+.$suffix}</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$BUILD</string>
  <key>LSMinimumSystemVersion</key><string>$MINIMUM</string>
  <key>LSUIElement</key><true/>
  <key>NSSupportsAutomaticGraphicsSwitching</key><true/>
</dict>
</plist>
PLIST
done

if [ "$CONFIG" = "release" ]; then
  rm -rf "$APP.dSYM"
  dsymutil "$BIN/Zinbox" -o "$APP.dSYM" 2>/dev/null || echo "no dSYM this time" >&2
  strip -x "$APP/Contents/MacOS/$NAME"
  for helper in "$APP"/Contents/Frameworks/*Helper*.app/Contents/MacOS/*; do strip -x "$helper"; done
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
  <key>NSPrincipalClass</key><string>ZBApplication</string>
  <key>LSMinimumSystemVersion</key><string>$MINIMUM</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.productivity</string>
  <key>NSHumanReadableCopyright</key><string>Zinbox</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSSupportsAutomaticGraphicsSwitching</key><true/>
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

# Sign inside-out: Chromium's libraries, the framework, the helpers, the app.
sign() { codesign --force --sign - --timestamp=none "$@" >/dev/null; }
for lib in "$APP/Contents/Frameworks/Chromium Embedded Framework.framework/Libraries/"*.dylib; do sign "$lib"; done
sign "$APP/Contents/Frameworks/Chromium Embedded Framework.framework"
for helper in "$APP"/Contents/Frameworks/*Helper*.app; do sign "$helper"; done
sign --entitlements Zinbox.entitlements "$APP"

echo "built: $APP ($VERSION, build $BUILD)"
