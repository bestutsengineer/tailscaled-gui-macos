#!/bin/bash
# Builds tailscaled-gui.app into ./build. Pass --install to copy it to ~/Applications.
set -euo pipefail
cd "$(dirname "$0")"

APP=build/tailscaled-gui.app
rm -rf build
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

swiftc -module-cache-path build/module-cache -O -swift-version 5 -target "$(uname -m)-apple-macos14.0" \
    -framework AppKit \
    Sources/*.swift -o "$APP/Contents/MacOS/tailscaled-gui"

cp Info.plist "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP/Contents/Resources/"
codesign --force --sign - "$APP"
echo "Built $APP"

if [ "${1:-}" = "--install" ]; then
    DEST="$HOME/Applications/tailscaled-gui.app"
    WAS_RUNNING=0
    if pgrep -x tailscaled-gui >/dev/null || pgrep -x Tailnet >/dev/null; then
        WAS_RUNNING=1
        # Stop the old login job first so it cannot relaunch the previous app.
        launchctl bootout "gui/$(id -u)/local.tailnet.agent" >/dev/null 2>&1 || true
        pkill -x tailscaled-gui || true
        pkill -x Tailnet || true
        sleep 1
    fi
    rm -rf "$DEST"
    cp -R "$APP" "$DEST"
    echo "Installed $DEST"
    if [ "$WAS_RUNNING" = 1 ]; then open "$DEST"; echo "Reopened"; fi
fi
