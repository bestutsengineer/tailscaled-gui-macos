#!/bin/bash
# Builds Tailnet.app into ./build. Pass --install to copy it to ~/Applications.
set -euo pipefail
cd "$(dirname "$0")"

APP=build/Tailnet.app
rm -rf build
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

swiftc -module-cache-path build/module-cache -O -swift-version 5 -target "$(uname -m)-apple-macos14.0" \
    -framework AppKit \
    Sources/*.swift -o "$APP/Contents/MacOS/Tailnet"

cp Info.plist "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP/Contents/Resources/"
codesign --force --sign - "$APP"
echo "Built $APP"

if [ "${1:-}" = "--install" ]; then
    DEST="$HOME/Applications/Tailnet.app"
    WAS_RUNNING=0
    if pgrep -x Tailnet >/dev/null; then
        WAS_RUNNING=1
        pkill -x Tailnet || true
        sleep 1
    fi
    rm -rf "$DEST"
    cp -R "$APP" "$DEST"
    echo "Installed $DEST"
    if [ "$WAS_RUNNING" = 1 ]; then open "$DEST"; echo "Reopened"; fi
fi
