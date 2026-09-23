#!/bin/bash
# Builds Tunnelside.app without Xcode: swift build → bundle packaging → signing → self-check.
# Needs only the Command Line Tools and a code signing certificate in the keychain.
#
#   scripts/build-spm.sh                    # sign with the "Tunnelside Local Signing" certificate
#   SIGN_IDENTITY="Apple Development: …" scripts/build-spm.sh
#   CONFIG=debug APP=/tmp/x/Tunnelside.app scripts/build-spm.sh   # debug build (needed for screenshots)
set -euo pipefail
cd "$(dirname "$0")/.."

SIGN_IDENTITY="${SIGN_IDENTITY:-Tunnelside Local Signing}"
APP_ID="io.github.kirillkarmanov.Tunnelside"
HELPER_ID="$APP_ID.helper"
VERSION="1.0.1"
BUILD_NUMBER="4"
MIN_MACOS="14.0"
CONFIG="${CONFIG:-release}"
APP="${APP:-build/Tunnelside.app}"

echo "→ Compiling ($CONFIG)"
swift build -c "$CONFIG" --product Tunnelside
swift build -c "$CONFIG" --product TunnelsideHelper
BIN="$(swift build -c "$CONFIG" --show-bin-path)"

echo "→ Packaging $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN/Tunnelside" "$APP/Contents/MacOS/Tunnelside"
# HelperInstaller looks for the service via Bundle.main.url(forAuxiliaryExecutable:), which is Contents/MacOS
cp "$BIN/TunnelsideHelper" "$APP/Contents/MacOS/$HELPER_ID"
cp "Sources/Tunnelside/Resources/$HELPER_ID.plist" "$APP/Contents/Resources/"
# Info.plist translations: the interface is translated in code (L(...)), system texts via .lproj
cp -R Sources/Tunnelside/Resources/*.lproj "$APP/Contents/Resources/"

# Service images: PNGs instead of Assets.xcassets (only Xcode compiles the catalog)
IMAGESET="Sources/Tunnelside/Assets.xcassets/HelperIcon.imageset"
for f in HelperIcon.png HelperIcon@2x.png HelperIcon-dark.png HelperIcon-dark@2x.png; do
    cp "$IMAGESET/$f" "$APP/Contents/Resources/$f"
done

# App icon: .icns from a ready-made 1024×1024 PNG
ICONSET="$(mktemp -d)/AppIcon.iconset"
mkdir -p "$ICONSET"
SRC_ICON="Design/Icons/Exports/AppIcon-Default.png"
for size in 16 32 128 256 512; do
    sips -z $size $size "$SRC_ICON" --out "$ICONSET/icon_${size}x${size}.png" >/dev/null
    sips -z $((size * 2)) $((size * 2)) "$SRC_ICON" --out "$ICONSET/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"
rm -rf "$(dirname "$ICONSET")"

# Info.plist: substitute the variables Xcode used to fill in
sed -e "s/\$(DEVELOPMENT_LANGUAGE)/en/" \
    -e "s/\$(EXECUTABLE_NAME)/Tunnelside/" \
    -e "s/\$(PRODUCT_BUNDLE_IDENTIFIER)/$APP_ID/" \
    -e "s/\$(PRODUCT_NAME)/Tunnelside/" \
    -e "s/\$(MARKETING_VERSION)/$VERSION/" \
    -e "s/\$(CURRENT_PROJECT_VERSION)/$BUILD_NUMBER/" \
    -e "s/\$(MACOSX_DEPLOYMENT_TARGET)/$MIN_MACOS/" \
    Config/Tunnelside-Info.plist > "$APP/Contents/Info.plist"
plutil -insert CFBundleIconFile -string AppIcon "$APP/Contents/Info.plist"
if grep -q '\$(' "$APP/Contents/Info.plist"; then
    echo "✗ Info.plist still has unsubstituted variables:" >&2
    grep '\$(' "$APP/Contents/Info.plist" >&2
    exit 1
fi
plutil -lint "$APP/Contents/Info.plist" >/dev/null

echo "→ Signing with \"${SIGN_IDENTITY}\""
if ! security find-certificate -c "$SIGN_IDENTITY" >/dev/null 2>&1; then
    echo "✗ Certificate \"${SIGN_IDENTITY}\" not found in the keychain" >&2
    exit 1
fi
# Hardened runtime: without it foreign code can be injected into the process via DYLD_INSERT_LIBRARIES
codesign --force --options runtime --timestamp=none --sign "$SIGN_IDENTITY" \
    --identifier "$HELPER_ID" "$APP/Contents/MacOS/$HELPER_ID"
codesign --force --options runtime --timestamp=none --sign "$SIGN_IDENTITY" \
    --identifier "$APP_ID" "$APP"
codesign --verify --strict --deep "$APP"

echo "→ Self-check: the service accepts this app and rejects a fake"
REQUIREMENT="$("$APP/Contents/MacOS/$HELPER_ID" --print-client-requirement)"
echo "   service requirement: $REQUIREMENT"
codesign --verify -R="$REQUIREMENT" "$APP" || { echo "✗ The service would reject its own app" >&2; exit 1; }
FAKE="$(mktemp -d)/fake"
cp "$APP/Contents/MacOS/Tunnelside" "$FAKE"
codesign --force --sign - --identifier "$APP_ID" "$FAKE" 2>/dev/null
if codesign --verify -R="$REQUIREMENT" "$FAKE" 2>/dev/null; then
    echo "✗ The service would accept a fake with an ad-hoc signature" >&2
    exit 1
fi
rm -rf "$(dirname "$FAKE")"

echo "✓ Done: $APP"
