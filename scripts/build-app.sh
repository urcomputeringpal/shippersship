#!/bin/bash
# Builds a release "Shippers Ship.app" into ./build. Pass --install to copy it to /Applications.
# VERSION=1.2.3 sets the app version (defaults to the latest git tag, or 0.0.0).
set -euo pipefail
VERSION="${VERSION:-$(git describe --tags --abbrev=0 2>/dev/null | sed 's/^v//' || true)}"
VERSION="${VERSION:-0.0.0}"
cd "$(dirname "$0")/.."

swift build -c release --product ShippersShip
BIN="$(swift build -c release --show-bin-path)/ShippersShip"
APP="build/Shippers Ship.app"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/ShippersShip"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>Shippers Ship</string>
  <key>CFBundleDisplayName</key><string>Shippers Ship</string>
  <key>CFBundleIdentifier</key><string>com.urcomputeringpal.shippersship</string>
  <key>CFBundleExecutable</key><string>ShippersShip</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>${VERSION}</string>
  <key>CFBundleVersion</key><string>${VERSION}</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHumanReadableCopyright</key><string>Ship it.</string>
</dict>
</plist>
PLIST

codesign --force --sign - "$APP"
echo "Built $APP ($VERSION)"

if [[ "${1:-}" == "--install" ]]; then
  rm -rf "/Applications/Shippers Ship.app"
  cp -R "$APP" /Applications/
  echo "Installed to /Applications/Shippers Ship.app"
fi
