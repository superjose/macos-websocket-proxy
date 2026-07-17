#!/usr/bin/env bash
# Build a real .app bundle (enables launch-at-login via SMAppService, proper Dock icon,
# no terminal parent). Usage: ./build-app.sh  ->  build/MacOSWebSocketProxy.app
set -euo pipefail

APP_NAME="MacOSWebSocketProxy"
BUNDLE_ID="com.superjose.macos-websocket-proxy"
OUT="build/${APP_NAME}.app"

swift build -c release
rm -rf "$OUT"
mkdir -p "$OUT/Contents/MacOS"
cp ".build/release/${APP_NAME}" "$OUT/Contents/MacOS/${APP_NAME}"

cat > "$OUT/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>WebSocket Proxy</string>
  <key>CFBundleDisplayName</key><string>WebSocket Proxy</string>
  <key>CFBundleIdentifier</key><string>${BUNDLE_ID}</string>
  <key>CFBundleExecutable</key><string>${APP_NAME}</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>LSUIElement</key><false/>
  <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
EOF

echo "Built $OUT"
echo "Run with: open $OUT"
