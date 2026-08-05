#!/usr/bin/env bash
# Assembles ApexClean.app from the SwiftPM build product.
#
# Kept as a plain script rather than an Xcode project so the whole build is
# reproducible from a checkout with no IDE state.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONFIG="${CONFIG:-release}"
APP="$ROOT/dist/ApexClean.app"
VERSION="${VERSION:-1.5.0}"
BUILD_NUMBER="${BUILD_NUMBER:-$(date +%Y%m%d%H%M)}"

# Release artefacts must run on both Apple Silicon and Intel. Local builds stay
# single-arch because a universal build costs roughly twice the compile time.
UNIVERSAL="${UNIVERSAL:-0}"

# Ad-hoc by default so the script runs with no credentials. CI substitutes a
# Developer ID for anything that leaves the machine.
SIGN_IDENTITY="${SIGN_IDENTITY:--}"

cd "$ROOT"
if [ "$UNIVERSAL" = "1" ]; then
    echo "==> Building ($CONFIG, arm64 + x86_64)"
    swift build -c "$CONFIG" --product ApexClean --arch arm64 --arch x86_64
    # Universal builds land in a different tree from single-arch ones.
    CONFIG_DIR="$(tr '[:lower:]' '[:upper:]' <<<"${CONFIG:0:1}")${CONFIG:1}"
    BINARY="$ROOT/.build/apple/Products/$CONFIG_DIR/ApexClean"
else
    echo "==> Building ($CONFIG, host architecture)"
    swift build -c "$CONFIG" --product ApexClean
    BINARY="$ROOT/.build/$CONFIG/ApexClean"
fi

[ -f "$BINARY" ] || { echo "error: no binary at $BINARY" >&2; exit 1; }

echo "==> Assembling bundle"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cp "$BINARY" "$APP/Contents/MacOS/ApexClean"

RESOURCE_BUNDLE="$(dirname "$BINARY")/ApexClean_ApexClean.bundle"
[ -d "$RESOURCE_BUNDLE" ] || {
    echo "error: no resource bundle at $RESOURCE_BUNDLE" >&2
    exit 1
}
cp -R "$RESOURCE_BUNDLE" "$APP/Contents/Resources/ApexClean_ApexClean.bundle"

# GPL-3.0 requires the license to travel with the binary.
cp "$ROOT/LICENSE" "$APP/Contents/Resources/LICENSE"
cp "$ROOT/NOTICE" "$APP/Contents/Resources/NOTICE"

echo "==> Rendering icon"
ICONSET="$ROOT/.build/ApexClean.iconset"
rm -rf "$ICONSET"
swift "$ROOT/Scripts/make-icon.swift" \
    "$ICONSET" "$ROOT/Sources/ApexClean/Resources/CoastalAtlasAppIcon.png" >/dev/null
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>ApexClean</string>
    <key>CFBundleDisplayName</key><string>ApexClean</string>
    <key>CFBundleIdentifier</key><string>fit.apexclean.app</string>
    <key>CFBundleExecutable</key><string>ApexClean</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>$VERSION</string>
    <key>CFBundleVersion</key><string>$BUILD_NUMBER</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSSupportsAutomaticGraphicsSwitching</key><true/>
    <key>LSApplicationCategoryType</key><string>public.app-category.utilities</string>
    <key>NSHumanReadableCopyright</key>
    <string>ApexClean is free software under GPL-3.0. Cleanup path knowledge and safety boundaries adapted from the Mole CLI.</string>
    <key>NSDesktopFolderUsageDescription</key>
    <string>ApexClean needs access to measure and clean files on your Desktop.</string>
    <key>NSDocumentsFolderUsageDescription</key>
    <string>ApexClean needs access to map storage usage in your Documents folder.</string>
    <key>NSDownloadsFolderUsageDescription</key>
    <string>ApexClean needs access to find installers and incomplete downloads.</string>
    <key>NSRemovableVolumesUsageDescription</key>
    <string>ApexClean needs access to analyse storage on external volumes.</string>
</dict>
</plist>
PLIST

ENTITLEMENTS="$ROOT/.build/ApexClean.entitlements"
cat > "$ENTITLEMENTS" <<ENT
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict/>
</plist>
ENT

if [ "$SIGN_IDENTITY" = "-" ]; then
    # Ad-hoc is enough to run locally and keeps the script usable with no
    # credentials. The runtime flag is best-effort here because older codesign
    # refuses to pair it with an ad-hoc identity.
    echo "==> Signing (ad-hoc)"
    codesign --force --deep --sign - --options runtime \
        --entitlements "$ENTITLEMENTS" "$APP" 2>/dev/null \
        || codesign --force --deep --sign - --entitlements "$ENTITLEMENTS" "$APP"
else
    # Distribution signing. The hardened runtime and a secure timestamp are both
    # mandatory for notarisation, so there is no fallback path here — if this
    # cannot be done properly it must fail rather than ship something unusable.
    echo "==> Signing (${SIGN_IDENTITY})"
    codesign --force --deep --sign "$SIGN_IDENTITY" --options runtime --timestamp \
        --entitlements "$ENTITLEMENTS" "$APP"
fi

codesign --verify --deep --strict --verbose=1 "$APP" 2>&1 | sed 's/^/    /'

echo "==> Built $APP"
echo "    version $VERSION ($BUILD_NUMBER)"
echo "    architectures: $(lipo -archs "$APP/Contents/MacOS/ApexClean")"
du -sh "$APP" | sed 's/^/    /'
