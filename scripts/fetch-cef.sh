#!/bin/bash
# Downloads the Chromium Embedded Framework (CEF) binary distribution into
# vendor/cef and builds its C++ wrapper library. Run once; build.sh calls it.
set -euo pipefail
cd "$(dirname "$0")/.."

CEF_VERSION="154.0.34+g14c5a08+chromium-154.0.8037.98"
CEF_SHA1="b7081f6609e5edccf07be96b5d7977329fbe1bdf"
NAME="cef_binary_${CEF_VERSION}_macosarm64_minimal"
DEST="vendor/cef"

if [ -f "$DEST/.version" ] && [ "$(cat "$DEST/.version")" = "$CEF_VERSION" ] && [ -f "$DEST/build/libcef_dll_wrapper/libcef_dll_wrapper.a" ]; then
  exit 0
fi

mkdir -p vendor
ARCHIVE="vendor/$NAME.tar.bz2"
if [ ! -f "$ARCHIVE" ]; then
  URL="https://cef-builds.spotifycdn.com/$(python3 -c "import urllib.parse,sys;print(urllib.parse.quote(sys.argv[1]))" "$NAME.tar.bz2")"
  echo "downloading CEF ${CEF_VERSION}..."
  curl -fL --retry 3 -o "$ARCHIVE.part" "$URL"
  mv "$ARCHIVE.part" "$ARCHIVE"
fi
echo "$CEF_SHA1  $ARCHIVE" | shasum -a 1 -c - >/dev/null

rm -rf "$DEST" "vendor/$NAME"
tar -xjf "$ARCHIVE" -C vendor
mv "vendor/$NAME" "$DEST"

echo "building libcef_dll_wrapper..."
cmake -S "$DEST" -B "$DEST/build" -G Ninja -DPROJECT_ARCH=arm64 -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_OSX_DEPLOYMENT_TARGET=14.0 >/dev/null
cmake --build "$DEST/build" --target libcef_dll_wrapper >/dev/null
echo "$CEF_VERSION" > "$DEST/.version"
echo "CEF ready: $DEST"
