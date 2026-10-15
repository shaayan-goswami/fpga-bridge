#!/bin/bash
# Renders the app icon in each system Icon & widget style (Default, Dark, Clear light/dark) from the Icon Composer
# document, for use inside the app (Quick Start) and as the Dock icon under `swift run`. The packaged app uses the
# .icon itself, compiled by actool, so the system draws every style there, including Tinted.
#   scripts/render-icon.sh
# Needs Xcode 26 or later (Icon Composer ships inside it). Edit the icon by opening
# Sources/FPGABridgeApp/Resources/AppIcon.icon in Icon Composer.
set -euo pipefail
cd "$(dirname "$0")/.."

icon=Sources/FPGABridgeApp/Resources/AppIcon.icon
out=Sources/FPGABridgeApp/Resources
ictool="$(xcode-select -p)/../Applications/Icon Composer.app/Contents/Executables/ictool"
[ -x "$ictool" ] || { echo "Icon Composer's ictool not found; install Xcode 26 or later." >&2; exit 1; }

for rendition in Default Dark ClearLight ClearDark; do
  "$ictool" "$icon" --export-image --output-file "$out/AppIcon-$rendition.png" \
    --platform macOS --rendition "$rendition" --width 512 --height 512 --scale 2
done
echo "wrote $out/AppIcon-{Default,Dark,ClearLight,ClearDark}.png"
