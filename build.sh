#!/bin/bash
# Builds "Claude Voice.app" (arm64, ad-hoc signed) and installs it to ~/Applications.
set -euo pipefail
cd "$(dirname "$0")"

NAME="Claude Voice"
APP="build/$NAME.app"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

swiftc -parse-as-library -swift-version 5 -O \
  -target arm64-apple-macos14.0 \
  Sources/*.swift -o "$APP/Contents/MacOS/ClaudeVoice"

if [ ! -f build/AppIcon.icns ]; then
  swift scripts/make_icon.swift build
  iconutil -c icns build/AppIcon.iconset -o build/AppIcon.icns
fi
cp build/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>Claude Voice</string>
  <key>CFBundleDisplayName</key><string>Claude Voice</string>
  <key>CFBundleIdentifier</key><string>local.claude-voice</string>
  <key>CFBundleExecutable</key><string>ClaudeVoice</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSMicrophoneUsageDescription</key><string>Claude Voice listens for spoken commands such as "Hey Claude, play last response". Audio is turned into text on this Mac and is not recorded.</string>
  <key>NSSpeechRecognitionUsageDescription</key><string>Claude Voice recognizes your spoken commands on this Mac.</string>
</dict>
</plist>
PLIST

codesign --force --sign - "$APP"

mkdir -p "$HOME/Applications"
rm -rf "$HOME/Applications/$NAME.app"
cp -R "$APP" "$HOME/Applications/"
echo "Installed $HOME/Applications/$NAME.app"
