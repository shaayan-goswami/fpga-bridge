#!/bin/bash
# Builds "FPGA Bridge.app" (release, ad-hoc signed) into dist/.
#   scripts/make-app.sh
# Set SCRATCH_PATH to build somewhere other than .build (needed when the repo is under ~/Desktop, where Finder
# attributes break code signing of build products).
set -euo pipefail
cd "$(dirname "$0")/.."

scratch=${SCRATCH_PATH:-.build}
swift build -c release --product FPGABridgeApp --scratch-path "$scratch"
bin=$(swift build -c release --product FPGABridgeApp --scratch-path "$scratch" --show-bin-path)

app="dist/FPGA Bridge.app"
rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"

cp "$bin/FPGABridgeApp" "$app/Contents/MacOS/FPGA Bridge"
cp Sources/FPGABridgeApp/Resources/AppIcon-Light.png Sources/FPGABridgeApp/Resources/AppIcon-Dark.png "$app/Contents/Resources/"

# The icon is an Icon Composer document. actool compiles it, as Xcode does, into Assets.car (the Liquid Glass icon
# that follows light and dark mode) plus AppIcon.icns for older systems.
xcrun actool --compile "$app/Contents/Resources" --platform macosx --minimum-deployment-target 14.0 \
  --app-icon AppIcon --output-partial-info-plist "$(mktemp -d)/partial.plist" \
  Sources/FPGABridgeApp/Resources/AppIcon.icon >/dev/null
if [ -d "$bin/fpga-bridge_FPGABridgeApp.bundle" ]; then
  cp -R "$bin/fpga-bridge_FPGABridgeApp.bundle" "$app/Contents/Resources/"
fi

version=$(git describe --tags --abbrev=0 2>/dev/null || echo "0.1.0")
build=$(git rev-list --count HEAD 2>/dev/null || echo "1")
cat > "$app/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>
    <string>FPGA Bridge</string>
    <key>CFBundleDisplayName</key>
    <string>FPGA Bridge</string>
    <key>CFBundleExecutable</key>
    <string>FPGA Bridge</string>
    <key>CFBundleIdentifier</key>
    <string>io.github.shaayan-goswami.fpga-bridge</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>CFBundleIconName</key>
    <string>AppIcon</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>${version#v}</string>
    <key>CFBundleVersion</key>
    <string>${build}</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>LSApplicationCategoryType</key>
    <string>public.app-category.developer-tools</string>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSPrincipalClass</key>
    <string>NSApplication</string>
</dict>
</plist>
PLIST

xattr -cr "$app"
codesign --force --deep --sign - "$app"
echo "Built $app"
