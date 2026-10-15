#!/bin/bash
# Renders the app icon and builds AppIcon.icns from it.
#   scripts/make-icon.sh
# Writes Sources/FPGABridgeApp/Resources/AppIcon.png and AppIcon.icns.
set -euo pipefail
cd "$(dirname "$0")/.."

out=Sources/FPGABridgeApp/Resources
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

swift scripts/make-icon.swift "$out/AppIcon.png"

set=$work/AppIcon.iconset
mkdir -p "$set"
for size in 16 32 128 256 512; do
  sips -z $size $size "$out/AppIcon.png" --out "$set/icon_${size}x${size}.png" >/dev/null
  double=$((size * 2))
  sips -z $double $double "$out/AppIcon.png" --out "$set/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns "$set" -o "$out/AppIcon.icns"
echo "wrote $out/AppIcon.icns"
