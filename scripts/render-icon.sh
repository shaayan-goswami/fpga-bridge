#!/bin/bash
# Renders light and dark previews of the app icon from the Icon Composer document, for use inside the app
# (Quick Start, About) and under `swift run`. The packaged app uses the .icon itself, compiled by actool.
#   scripts/render-icon.sh
# Needs Xcode 26 or later (Icon Composer ships inside it). Edit the icon by opening
# Sources/FPGABridgeApp/Resources/AppIcon.icon in Icon Composer.
set -euo pipefail
cd "$(dirname "$0")/.."

icon=Sources/FPGABridgeApp/Resources/AppIcon.icon
out=Sources/FPGABridgeApp/Resources
ictool="$(xcode-select -p)/../Applications/Icon Composer.app/Contents/Executables/ictool"
[ -x "$ictool" ] || { echo "Icon Composer's ictool not found; install Xcode 26 or later." >&2; exit 1; }

"$ictool" "$icon" --export-image --output-file "$out/AppIcon-Light.png" \
  --platform macOS --rendition Default --width 512 --height 512 --scale 2
"$ictool" "$icon" --export-image --output-file "$out/AppIcon-Dark.png" \
  --platform macOS --rendition Dark --width 512 --height 512 --scale 2
echo "wrote $out/AppIcon-Light.png and AppIcon-Dark.png"
