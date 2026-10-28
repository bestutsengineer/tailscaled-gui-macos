#!/bin/bash
# Regenerates Resources/AppIcon.icns from the pixel map in Sources/SwordIcon.swift.
set -euo pipefail
cd "$(dirname "$0")/.."
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
swiftc -O -parse-as-library -module-cache-path "$TMP/module-cache" -framework AppKit Sources/SwordIcon.swift tools/MakeIcon.swift -o "$TMP/make-icon"
"$TMP/make-icon" "$TMP/AppIcon.iconset"
iconutil -c icns "$TMP/AppIcon.iconset" -o Resources/AppIcon.icns
"$TMP/make-icon" --preview Resources/SwordPreview.png
echo "Wrote Resources/AppIcon.icns"
