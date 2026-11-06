#!/bin/bash
# Builds Clarping with SwiftPM and assembles build/Clarping.app (no Xcode needed).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

swift build -c release 2>&1 | tail -3
BIN="$(swift build -c release --show-bin-path)/Clarping"

APP="$ROOT/build/Clarping.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Clarping"

if [ ! -f "$ROOT/build/AppIcon.icns" ]; then
  "$ROOT/scripts/make-icon.sh"
fi
cp "$ROOT/build/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>Clarping</string>
  <key>CFBundleDisplayName</key><string>Clarping</string>
  <key>CFBundleIdentifier</key><string>org.hackyard.clarping</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>CFBundleShortVersionString</key><string>0.1.0</string>
  <key>CFBundleExecutable</key><string>Clarping</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSHumanReadableCopyright</key><string>Local tool. No telemetry.</string>
</dict>
</plist>
PLIST

codesign --force --deep -s - "$APP"
echo "Built $APP"
