#!/usr/bin/env bash
# Builds Glow.app (menu-bar app) and glowctl (CLI) in release mode.
#   scripts/build-app.sh            -> build/Glow.app, build/glowctl
#   scripts/build-app.sh --install  -> also copies Glow.app to ~/Applications and glowctl to ~/.local/bin
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="0.1.0"
APP="build/Glow.app"

swift build -c release --product Glow
swift build -c release --product glowctl
BIN="$(swift build -c release --show-bin-path)"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN/Glow" "$APP/Contents/MacOS/Glow"
cp "$BIN/glowctl" build/glowctl

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>Glow</string>
  <key>CFBundleDisplayName</key><string>Glow</string>
  <key>CFBundleIdentifier</key><string>dev.glow.menubar</string>
  <key>CFBundleExecutable</key><string>Glow</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>${VERSION}</string>
  <key>CFBundleVersion</key><string>${VERSION}</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
  <key>NSLocalNetworkUsageDescription</key>
  <string>Glow talks to your smart bulb directly over your home Wi-Fi.</string>
</dict>
</plist>
PLIST

ICONSET="build/AppIcon.iconset"
rm -rf "$ICONSET"
swift scripts/make_icon.swift "$ICONSET"
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"
rm -rf "$ICONSET"

# Ad-hoc signature: fine for your own Mac. Distribution needs a Developer ID + notarization.
codesign --force --deep --sign - "$APP"
echo "Built $APP and build/glowctl"

if [[ "${1:-}" == "--install" ]]; then
  mkdir -p "$HOME/Applications" "$HOME/.local/bin"
  rm -rf "$HOME/Applications/Glow.app"
  cp -R "$APP" "$HOME/Applications/Glow.app"
  cp build/glowctl "$HOME/.local/bin/glowctl"
  echo "Installed ~/Applications/Glow.app and ~/.local/bin/glowctl"
  echo "Tip: add ~/.local/bin to PATH to run 'glowctl' anywhere."
fi
