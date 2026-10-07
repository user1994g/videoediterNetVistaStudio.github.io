#!/bin/bash
set -euo pipefail
SOURCE_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_DIR="$(cd "$SOURCE_DIR/../.." && pwd)"
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode-beta.app/Contents/Developer}"
OUTPUT_DIR="${1:-$SOURCE_DIR/build}"
mkdir -p "$OUTPUT_DIR"
OUTPUT_DIR="$(cd "$OUTPUT_DIR" && pwd)"
STAGE_DIR="$(mktemp -d /private/tmp/netvista-ipad-build.XXXXXX)"
APP_DIR="$STAGE_DIR/Payload/NetVistaStudio.app"
mkdir -p "$APP_DIR" "$STAGE_DIR/Assets.xcassets/AppIcon.appiconset"
PLATFORM="${NETVISTA_IOS_PLATFORM:-iphoneos}"
if [[ "$PLATFORM" != iphoneos && "$PLATFORM" != iphonesimulator ]]; then
  printf 'Unsupported iOS build platform\n' >&2; exit 1
fi
SDK="$(xcrun --sdk "$PLATFORM" --show-sdk-path)"
TARGET=arm64-apple-ios16.0
if [[ "$PLATFORM" == iphonesimulator ]]; then TARGET=arm64-apple-ios16.0-simulator; fi
cp "$SOURCE_DIR/Info.plist" "$APP_DIR/Info.plist"
cp "$REPO_DIR/assets/NetVistaStudio.png" "$APP_DIR/NetVistaStudio.png"
cp -R "$SOURCE_DIR/Assets.xcassets/." "$STAGE_DIR/Assets.xcassets/"
for SIZE in 76 152 167 1024; do
  sips -z "$SIZE" "$SIZE" "$REPO_DIR/assets/NetVistaStudio.png" --out "$STAGE_DIR/Assets.xcassets/AppIcon.appiconset/AppIcon$SIZE.png" >/dev/null
done
xcrun actool "$STAGE_DIR/Assets.xcassets" --compile "$APP_DIR" --platform "$PLATFORM" \
  --minimum-deployment-target 16.0 --target-device ipad --app-icon AppIcon \
  --output-partial-info-plist "$STAGE_DIR/asset-info.plist" >/dev/null
/usr/libexec/PlistBuddy -c "Merge $STAGE_DIR/asset-info.plist" "$APP_DIR/Info.plist"
xcrun --sdk "$PLATFORM" swiftc -swift-version 5 -O -whole-module-optimization \
  -sdk "$SDK" -target "$TARGET" -module-cache-path "$STAGE_DIR/ModuleCache" \
  "$REPO_DIR/StudioAccount.swift" "$SOURCE_DIR"/Sources/*.swift \
  -framework UIKit -framework AVFoundation -framework AVKit -framework Security \
  -framework UniformTypeIdentifiers -Xlinker -rpath -Xlinker @executable_path/Frameworks \
  -o "$APP_DIR/NetVistaStudio"
# Ad-hoc signature permits package inspection; AltStore supplies the user's real
# iOS development signature and provisioning profile when installing the IPA.
codesign --force --sign - "$APP_DIR"
codesign --verify --strict "$APP_DIR"
plutil -lint "$APP_DIR/Info.plist"
xcrun vtool -show-build "$APP_DIR/NetVistaStudio" | tee "$OUTPUT_DIR/ipad-build-platform.txt"
if [[ "$PLATFORM" == iphonesimulator ]]; then
  xcrun vtool -show-build "$APP_DIR/NetVistaStudio" | rg -q 'platform IOSSIMULATOR$'
  cp -R "$APP_DIR" "$OUTPUT_DIR/NetVistaStudio-Simulator.app"
  printf 'Simulator app (not an installable IPA): %s\n' "$OUTPUT_DIR/NetVistaStudio-Simulator.app"
  exit 0
fi
grep -Eq 'platform IOS$' "$OUTPUT_DIR/ipad-build-platform.txt"
IPA="$OUTPUT_DIR/NetVista-Studio-iPadOS-1.4-Beta-7.ipa"
ditto -c -k --norsrc --keepParent "$STAGE_DIR/Payload" "$IPA"
unzip -t "$IPA" >/dev/null
shasum -a 256 "$IPA"
printf 'Built native iPadOS IPA for AltStore re-signing: %s\n' "$IPA"
printf 'App staging directory retained for verification: %s\n' "$APP_DIR"
