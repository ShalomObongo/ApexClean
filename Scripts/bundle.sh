#!/usr/bin/env bash
# Assembles ApexClean.app from the SwiftPM build product.
#
# Kept as a plain script rather than an Xcode project so the whole build is
# reproducible from a checkout with no IDE state.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONFIG="${CONFIG:-release}"
BUILD_DIR="$ROOT/.build/$CONFIG"
APP="$ROOT/dist/ApexClean.app"
VERSION="1.0.0"
BUILD_NUMBER="$(date +%Y%m%d%H%M)"

echo "==> Building ($CONFIG)"
cd "$ROOT"
swift build -c "$CONFIG" --product ApexClean

echo "==> Assembling bundle"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cp "$BUILD_DIR/ApexClean" "$APP/Contents/MacOS/ApexClean"

# GPL-3.0 requires the license to travel with the binary.
cp "$ROOT/LICENSE" "$APP/Contents/Resources/LICENSE"
cp "$ROOT/NOTICE" "$APP/Contents/Resources/NOTICE"

echo "==> Rendering icon"
ICONSET="$ROOT/.build/ApexClean.iconset"
rm -rf "$ICONSET"
swift "$ROOT/Scripts/make-icon.swift" "$ICONSET" >/dev/null
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
    <key>NSAppleEventsUsageDescription</key>
    <string>ApexClean asks Finder to empty the Trash. macOS keeps the Trash private unless an app has Full Disk Access, so Finder does it instead.</string>
</dict>
</plist>
PLIST

# The hardened runtime blocks Apple events unless the entitlement is present,
# and emptying the Trash without Full Disk Access has to go through Finder.
ENTITLEMENTS="$ROOT/.build/ApexClean.entitlements"
cat > "$ENTITLEMENTS" <<ENT
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>com.apple.security.automation.apple-events</key><true/>
</dict>
</plist>
ENT

# Ad-hoc signature. A distribution build would substitute a Developer ID here
# and run notarytool; ad-hoc is enough for local use and keeps the script
# runnable without credentials.
echo "==> Signing (ad-hoc)"
codesign --force --deep --sign - --options runtime \
    --entitlements "$ENTITLEMENTS" "$APP" 2>/dev/null \
    || codesign --force --deep --sign - --entitlements "$ENTITLEMENTS" "$APP"

codesign --verify --verbose=1 "$APP" 2>&1 | sed 's/^/    /'

echo "==> Built $APP"
du -sh "$APP" | sed 's/^/    /'
