#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUTPUT_DIR="${OUTPUT_DIR:?Set OUTPUT_DIR to a local release directory}"
NOTARY_PROFILE="${NOTARY_PROFILE:?Set NOTARY_PROFILE to a notarytool Keychain profile}"
QUIET_MESSAGES_SIGN_IDENTITY="${QUIET_MESSAGES_SIGN_IDENTITY:?Set QUIET_MESSAGES_SIGN_IDENTITY}"
export OUTPUT_DIR QUIET_MESSAGES_SIGN_IDENTITY
"$ROOT/scripts/package.sh"
APP="$OUTPUT_DIR/iMessage Spam Blocker.app"
DMG="$OUTPUT_DIR/iMessage-Spam-Blocker-0.1.0-arm64.dmg"
STAGING="$(mktemp -d)"
trap 'rm -rf "$STAGING"' EXIT
ditto --norsrc --noextattr "$APP" "$STAGING/iMessage Spam Blocker.app"
ln -s /Applications "$STAGING/Applications"
hdiutil create -quiet -ov -fs HFS+ -volname 'iMessage Spam Blocker' -srcfolder "$STAGING" -format UDZO "$DMG"
codesign --force --timestamp --sign "$QUIET_MESSAGES_SIGN_IDENTITY" "$DMG"
hdiutil verify "$DMG"
xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait --output-format json > "$OUTPUT_DIR/notarization.json"
test "$(plutil -extract status raw -o - "$OUTPUT_DIR/notarization.json")" = Accepted
xcrun stapler staple "$DMG"
xcrun stapler validate "$DMG"
spctl --assess --type open --context context:primary-signature --verbose=4 "$DMG"
shasum -a 256 "$DMG" > "$OUTPUT_DIR/SHA256SUMS.txt"
printf '%s\n' "$DMG"
