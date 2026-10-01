#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
swift build --package-path "$ROOT" -c release
OUTPUT_DIR="${OUTPUT_DIR:-$ROOT/dist}"
APP="$OUTPUT_DIR/iMessage Spam Blocker.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$ROOT/.build/release/QuietMessages" "$APP/Contents/MacOS/QuietMessages"
cp -f "$ROOT/vendor/node-v25.5.0-darwin-arm64/bin/node" "$APP/Contents/Resources/node"
cp -f "$ROOT/vendor/node-v25.5.0-darwin-arm64/LICENSE" "$APP/Contents/Resources/Node-LICENSE"
rm -rf "$APP/Contents/Resources/bridge"
cp -R "$ROOT/bridge" "$APP/Contents/Resources/bridge"
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>QuietMessages</string>
<key>CFBundleIdentifier</key><string>com.quietmessages.app</string>
<key>CFBundleName</key><string>iMessage Spam Blocker</string>
<key>CFBundleDisplayName</key><string>iMessage Spam Blocker</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>0.1.0</string>
<key>CFBundleVersion</key><string>1</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>NSContactsUsageDescription</key><string>iMessage Spam Blocker uses the macOS sender block list to block spam and restore senders you choose.</string>
<key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST
xattr -cr "$APP"
SIGN_IDENTITY="${QUIET_MESSAGES_SIGN_IDENTITY:?Set QUIET_MESSAGES_SIGN_IDENTITY to a Developer ID Application identity to preserve macOS permission identity}"
while IFS= read -r -d '' native_module; do
  codesign --force --timestamp --options runtime --sign "$SIGN_IDENTITY" "$native_module"
done < <(find "$APP/Contents/Resources/bridge" -type f -name '*.node' -print0)
codesign --force --timestamp --options runtime --sign "$SIGN_IDENTITY" --entitlements "$ROOT/config/node-entitlements.plist" "$APP/Contents/Resources/node"
codesign --force --timestamp --options runtime --sign "$SIGN_IDENTITY" --entitlements "$ROOT/config/entitlements.plist" "$APP"
xattr -cr "$APP"
codesign --verify --deep --strict "$APP"
printf '%s\n' "$APP"
