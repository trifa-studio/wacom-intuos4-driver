#!/bin/bash
# Assemble IntuosDriver.app from the release build.
set -euo pipefail
cd "$(dirname "$0")/.."

swift build -c release

APP="IntuosDriver.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
mkdir -p "$APP/Contents/Resources"

BIN="$(swift build -c release --show-bin-path)/IntuosDriverApp"
cp "$BIN" "$APP/Contents/MacOS/IntuosDriver"

if [ -f "Resources/AppIcon.icns" ]; then
    cp "Resources/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
fi

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
    <string>IntuosDriver</string>
    <key>CFBundleIdentifier</key>
    <string>com.trifa.intuosdriver</string>
    <key>CFBundleName</key>
    <string>IntuosDriver</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0.0</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSHighResolutionCapable</key>
    <true/>
</dict>
</plist>
PLIST

# Stable self-signed identity keeps TCC grants alive across rebuilds
# (ad-hoc cdhash changes per build and invalidates Accessibility /
# Input Monitoring grants). Falls back to ad-hoc if the identity is missing.
if security find-certificate -c "IntuosDriver Local" >/dev/null 2>&1; then
  codesign --force --deep -s "IntuosDriver Local" "$APP"
else
  codesign --force --deep -s - "$APP"
fi
echo "Built $APP ($(du -sh "$APP" | cut -f1))"
echo "Run: open $APP   (or copy to /Applications)"
