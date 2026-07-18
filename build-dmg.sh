#!/usr/bin/env bash
# Package the .app into a distributable DMG with the classic drag-to-Applications layout.
# No paid tools: just build-app.sh + hdiutil (ships with macOS).
# Usage: ./build-dmg.sh  ->  build/MacOSWebSocketProxy.dmg
set -euo pipefail

APP_NAME="MacOSWebSocketProxy"
DMG="build/${APP_NAME}.dmg"
STAGING="build/dmg-staging"

./build-app.sh

rm -rf "$STAGING" "$DMG"
mkdir -p "$STAGING"
cp -R "build/${APP_NAME}.app" "$STAGING/"
ln -s /Applications "$STAGING/Applications" # the "drag here" target in the DMG window

# UDZO = zlib-compressed read-only DMG, the standard for app distribution.
hdiutil create -volname "WebSocket Proxy" -srcfolder "$STAGING" -ov -format UDZO "$DMG"
rm -rf "$STAGING"

echo "Built $DMG"
