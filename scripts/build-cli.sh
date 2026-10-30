#!/bin/zsh
# Build BLEUnlock.app with only the Command Line Tools (no Xcode). Usage: scripts/build-cli.sh
# Differences from an Xcode build:
# - No compiled xibs (needs ibtool): AppDelegate is created in a generated main.swift; About box won't open.
# - No asset catalog (needs actool): status bar PDFs are copied and registered as template images.
# - No Launcher helper: "Launch at Login" won't work; add the app in System Settings > Login Items instead.
set -euo pipefail

ROOT=${0:A:h:h}
SRC=$ROOT/BLEUnlock
OUT=$ROOT/build/cli
WORK=$OUT/work
APP=$OUT/BLEUnlock.app
SDK=$(xcrun --show-sdk-path)
TARGET=$(uname -m)-apple-macos11.0

rm -rf "$OUT"
mkdir -p "$WORK/swift" "$APP/Contents/MacOS" "$APP/Contents/Resources"

# Sources: drop @NSApplicationMain (it loads MainMenu.nib, which we can't build) and add our own entry point
cp "$SRC"/*.swift "$WORK/swift/"
sed -i '' '/^@NSApplicationMain$/d' "$WORK/swift/AppDelegate.swift"
cat > "$WORK/swift/main.swift" <<'EOF'
import Cocoa

// Stand-in for Images.xcassets: register the status bar icons as template images under their asset names
for name in ["StatusBarConnected", "StatusBarDisconnected"] {
    if let url = Bundle.main.url(forResource: name, withExtension: "pdf"), let image = NSImage(contentsOf: url) {
        image.isTemplate = true
        image.setName(name)
    }
}
let delegate = AppDelegate()
NSApplication.shared.delegate = delegate
NSApplication.shared.run()
EOF

clang -c -O2 -include CoreFoundation/CoreFoundation.h -target "$TARGET" -isysroot "$SDK" "$SRC/lowlevel.c" -o "$WORK/lowlevel.o"

swiftc -O -swift-version 5 -module-name BLEUnlock -target "$TARGET" -sdk "$SDK" \
    -import-objc-header "$SRC/BLEUnlock-Bridging-Header.h" \
    "$WORK"/swift/*.swift "$WORK/lowlevel.o" \
    -F "$SDK/System/Library/PrivateFrameworks" -framework MediaRemote -framework login \
    -framework IOKit -framework CoreBluetooth -framework ServiceManagement \
    -o "$APP/Contents/MacOS/BLEUnlock"

# Info.plist: fill in Xcode build variables, drop the main nib
sed -e 's/$(DEVELOPMENT_LANGUAGE)/en/' -e 's/$(EXECUTABLE_NAME)/BLEUnlock/' \
    -e 's/$(PRODUCT_BUNDLE_IDENTIFIER)/jp.sone.BLEUnlock/' -e 's/$(PRODUCT_NAME)/BLEUnlock/' \
    -e 's/$(MACOSX_DEPLOYMENT_TARGET)/11.0/' "$SRC/Info.plist" > "$APP/Contents/Info.plist"
plutil -remove NSMainNibFile "$APP/Contents/Info.plist"
plutil -replace CFBundleIconFile -string AppIcon "$APP/Contents/Info.plist"

# Resources
cp "$SRC/Images.xcassets/StatusBarConnected.imageset/app.pdf" "$APP/Contents/Resources/StatusBarConnected.pdf"
cp "$SRC/Images.xcassets/StatusBarDisconnected.imageset/unlock-off.pdf" "$APP/Contents/Resources/StatusBarDisconnected.pdf"
for lproj in "$SRC"/*.lproj; do
    mkdir -p "$APP/Contents/Resources/${lproj:t}"
    cp "$lproj/Localizable.strings" "$APP/Contents/Resources/${lproj:t}/"
done
ICONSET=$WORK/AppIcon.iconset
mkdir -p "$ICONSET"
for size in 16 32 128 256 512; do
    cp "$SRC/Images.xcassets/AppIcon.appiconset/mac-${size}x${size}.png" "$ICONSET/icon_${size}x${size}.png"
    cp "$SRC/Images.xcassets/AppIcon.appiconset/mac-${size}x${size}@2x.png" "$ICONSET/icon_${size}x${size}@2x.png"
done
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"

codesign -s - -f --entitlements "$SRC/BLEUnlock.entitlements" "$APP"
codesign -v "$APP"
echo "Built $APP"
