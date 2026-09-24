#!/bin/sh
# Builds the Stay Awake menu bar app into ~/Applications.
set -e
HERE=$(cd "$(dirname "$0")" && pwd)
APP="$HOME/Applications/StayAwake.app"

if ! command -v swiftc >/dev/null 2>&1; then
  echo "error: swiftc not found. Install the command line tools first:" >&2
  echo "       xcode-select --install" >&2
  exit 1
fi

# Build for whatever machine this is, rather than a pinned architecture.
ARCH=$(uname -m)

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"

swiftc -O -parse-as-library -target "${ARCH}-apple-macos14.0" \
  -o "$APP/Contents/MacOS/StayAwake" "$HERE/StayAwakeApp.swift"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleName</key><string>StayAwake</string>
	<key>CFBundleDisplayName</key><string>Stay Awake</string>
	<key>CFBundleIdentifier</key><string>com.macstayawake.app</string>
	<key>CFBundleExecutable</key><string>StayAwake</string>
	<key>CFBundlePackageType</key><string>APPL</string>
	<key>CFBundleShortVersionString</key><string>1.0</string>
	<key>CFBundleVersion</key><string>1</string>
	<key>LSMinimumSystemVersion</key><string>14.0</string>
	<key>LSUIElement</key><true/>
</dict>
</plist>
PLIST

# Ad-hoc signature: an unsigned bundle cannot post notifications.
codesign --force --sign - "$APP"
echo "built: $APP"
