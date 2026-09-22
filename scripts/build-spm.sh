#!/bin/bash
# Сборка MacOSRoute.app без Xcode: swift build → упаковка бандла → подпись → самопроверка.
# Нужны только Command Line Tools и сертификат для подписи в связке ключей.
#
#   scripts/build-spm.sh                    # подпись сертификатом «MacOSRoute Local Signing»
#   SIGN_IDENTITY="Apple Development: …" scripts/build-spm.sh
set -euo pipefail
cd "$(dirname "$0")/.."

SIGN_IDENTITY="${SIGN_IDENTITY:-MacOSRoute Local Signing}"
APP_ID="com.hyperits.app.MacOSRoute"
HELPER_ID="$APP_ID.helper"
VERSION="1.0.1"
BUILD_NUMBER="4"
MIN_MACOS="14.0"
APP="build/MacOSRoute.app"

echo "→ Компиляция"
swift build -c release --product MacOSRoute
swift build -c release --product MacOSRouteHelper
BIN="$(swift build -c release --show-bin-path)"

echo "→ Упаковка $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN/MacOSRoute" "$APP/Contents/MacOS/MacOSRoute"
# HelperInstaller ищет службу через Bundle.main.url(forAuxiliaryExecutable:) — это Contents/MacOS
cp "$BIN/MacOSRouteHelper" "$APP/Contents/MacOS/$HELPER_ID"
cp "Sources/MacOSRoute/Resources/$HELPER_ID.plist" "$APP/Contents/Resources/"

# Картинки службы: PNG вместо Assets.xcassets (каталог компилирует только Xcode)
IMAGESET="Sources/MacOSRoute/Assets.xcassets/HelperIcon.imageset"
for f in HelperIcon.png HelperIcon@2x.png HelperIcon-dark.png HelperIcon-dark@2x.png; do
    cp "$IMAGESET/$f" "$APP/Contents/Resources/$f"
done

# Иконка приложения: .icns из готового PNG 1024×1024
ICONSET="$(mktemp -d)/AppIcon.iconset"
mkdir -p "$ICONSET"
SRC_ICON="Design/Icons/Exports/AppIcon-Default.png"
for size in 16 32 128 256 512; do
    sips -z $size $size "$SRC_ICON" --out "$ICONSET/icon_${size}x${size}.png" >/dev/null
    sips -z $((size * 2)) $((size * 2)) "$SRC_ICON" --out "$ICONSET/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"
rm -rf "$(dirname "$ICONSET")"

# Info.plist: подставляем переменные, которые раньше подставлял Xcode
sed -e "s/\$(DEVELOPMENT_LANGUAGE)/ru/" \
    -e "s/\$(EXECUTABLE_NAME)/MacOSRoute/" \
    -e "s/\$(PRODUCT_BUNDLE_IDENTIFIER)/$APP_ID/" \
    -e "s/\$(PRODUCT_NAME)/MacOSRoute/" \
    -e "s/\$(MARKETING_VERSION)/$VERSION/" \
    -e "s/\$(CURRENT_PROJECT_VERSION)/$BUILD_NUMBER/" \
    -e "s/\$(MACOSX_DEPLOYMENT_TARGET)/$MIN_MACOS/" \
    Config/MacOSRoute-Info.plist > "$APP/Contents/Info.plist"
plutil -insert CFBundleIconFile -string AppIcon "$APP/Contents/Info.plist"
if grep -q '\$(' "$APP/Contents/Info.plist"; then
    echo "✗ В Info.plist остались неподставленные переменные:" >&2
    grep '\$(' "$APP/Contents/Info.plist" >&2
    exit 1
fi
plutil -lint "$APP/Contents/Info.plist" >/dev/null

echo "→ Подпись «${SIGN_IDENTITY}»"
if ! security find-certificate -c "$SIGN_IDENTITY" >/dev/null 2>&1; then
    echo "✗ Сертификат «${SIGN_IDENTITY}» не найден в связке ключей" >&2
    exit 1
fi
# Hardened runtime: без него в процесс можно подгрузить чужой код через DYLD_INSERT_LIBRARIES
codesign --force --options runtime --timestamp=none --sign "$SIGN_IDENTITY" \
    --identifier "$HELPER_ID" "$APP/Contents/MacOS/$HELPER_ID"
codesign --force --options runtime --timestamp=none --sign "$SIGN_IDENTITY" \
    --identifier "$APP_ID" "$APP"
codesign --verify --strict --deep "$APP"

echo "→ Самопроверка: служба примет это приложение, а подделку — нет"
REQUIREMENT="$("$APP/Contents/MacOS/$HELPER_ID" --print-client-requirement)"
echo "   требование службы: $REQUIREMENT"
codesign --verify -R="$REQUIREMENT" "$APP" || { echo "✗ Служба не примет собственное приложение" >&2; exit 1; }
FAKE="$(mktemp -d)/fake"
cp "$APP/Contents/MacOS/MacOSRoute" "$FAKE"
codesign --force --sign - --identifier "$APP_ID" "$FAKE" 2>/dev/null
if codesign --verify -R="$REQUIREMENT" "$FAKE" 2>/dev/null; then
    echo "✗ Служба примет подделку с ad-hoc подписью" >&2
    exit 1
fi
rm -rf "$(dirname "$FAKE")"

echo "✓ Готово: $APP"
