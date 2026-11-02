#!/bin/sh
# Builds a release GetMyIP.app into ./build (universal, ad-hoc signed).
# Optional env: VERSION (e.g. 1.2.0), BUILD_NUMBER (integer), ZIP=1 to also produce build/GetMyIP-<version>.zip.
set -eu
cd "$(dirname "$0")"

swift build -c release --arch arm64 --arch x86_64
BIN="$(swift build -c release --arch arm64 --arch x86_64 --show-bin-path)/GetMyIP"

APP=build/GetMyIP.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
cp "$BIN" "$APP/Contents/MacOS/GetMyIP"
strip -x "$APP/Contents/MacOS/GetMyIP"

PLIST="$APP/Contents/Info.plist"
if [ -n "${VERSION:-}" ]; then
    /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$PLIST"
fi
if [ -n "${BUILD_NUMBER:-}" ]; then
    /usr/libexec/PlistBuddy -c "Set :CFBundleVersion $BUILD_NUMBER" "$PLIST"
fi

codesign --force --sign - --options runtime "$APP"
codesign --verify --strict "$APP"
VER="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$PLIST")"
echo "Built $APP ($VER)"

if [ "${ZIP:-0}" = "1" ]; then
    ZIPFILE="build/GetMyIP-$VER.zip"
    rm -f "$ZIPFILE"
    ditto -c -k --sequesterRsrc --keepParent "$APP" "$ZIPFILE"
    shasum -a 256 "$ZIPFILE" | sed 's|build/||' > "$ZIPFILE.sha256"
    echo "Packed $ZIPFILE"
fi
