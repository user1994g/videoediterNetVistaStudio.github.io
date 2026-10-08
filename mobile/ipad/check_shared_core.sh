#!/bin/bash
# Compile the existing Mac engines for UIKit; do not copy/fork their source.
set -euo pipefail
SOURCE_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_DIR="$(cd "$SOURCE_DIR/../.." && pwd)"
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode-beta.app/Contents/Developer}"
OUTPUT_DIR="${1:-$(mktemp -d /private/tmp/netvista-ios-shared-core.XXXXXX)}"
mkdir -p "$OUTPUT_DIR/NetVistaSharedCoreChecks.app"
APP_DIR="$OUTPUT_DIR/NetVistaSharedCoreChecks.app"
SDK="$(xcrun --sdk iphonesimulator --show-sdk-path)"
cp "$SOURCE_DIR/Info.plist" "$APP_DIR/Info.plist"
/usr/libexec/PlistBuddy -c 'Set :CFBundleIdentifier com.netvistastudio.shared-core-checks' "$APP_DIR/Info.plist"
xcrun --sdk iphonesimulator swiftc -swift-version 5 -O -D NETVISTA_SHARED_CORE_QA \
  -sdk "$SDK" -target arm64-apple-ios16.0-simulator -module-cache-path "$OUTPUT_DIR/SharedModuleCache" \
  "$REPO_DIR/PhotoRaster.swift" "$REPO_DIR/Tests/PhotoRasterChecks.swift" \
  "$REPO_DIR/GameProject.swift" "$REPO_DIR/GameGraph.swift" "$REPO_DIR/GameRuntime.swift" \
  "$REPO_DIR/GameEditingSupport.swift" "$REPO_DIR/GameExport.swift" \
  "$REPO_DIR/ModelingDocument.swift" "$REPO_DIR/ModelingSculpt.swift" \
  "$REPO_DIR/ModelingGenerators.swift" "$REPO_DIR/ModelingPhysics.swift" \
  "$REPO_DIR/AdvancedGrade.swift" "$REPO_DIR/CubeLUT.swift" "$REPO_DIR/UltraKey.swift" \
  "$SOURCE_DIR/Tests/SharedCoreChecks.swift" \
  -framework UIKit -framework CoreImage -framework ImageIO -framework SceneKit \
  -o "$APP_DIR/NetVistaStudio"
codesign --force --sign - "$APP_DIR"
printf 'Isolated shared-engine simulator QA app: %s\n' "$APP_DIR"
