#!/bin/bash
# Build an isolated simulator-only executable; never an installable public IPA.
set -euo pipefail
SOURCE_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_DIR="$(cd "$SOURCE_DIR/../.." && pwd)"
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode-beta.app/Contents/Developer}"
OUTPUT_DIR="${1:-$(mktemp -d /private/tmp/netvista-ios-ui-check.XXXXXX)}"
mkdir -p "$OUTPUT_DIR/NetVistaWorkspaceChecks.app"
APP_DIR="$OUTPUT_DIR/NetVistaWorkspaceChecks.app"
SDK="$(xcrun --sdk iphonesimulator --show-sdk-path)"
cp "$SOURCE_DIR/Info.plist" "$APP_DIR/Info.plist"
/usr/libexec/PlistBuddy -c 'Set :CFBundleIdentifier com.netvistastudio.workspace-checks' "$APP_DIR/Info.plist"
cp "$REPO_DIR/assets/NetVistaStudio.png" "$REPO_DIR/assets/home-video-coast.png" "$REPO_DIR/assets/home-photo-petals.png" "$APP_DIR/"
cp "$REPO_DIR/assets/home-game-world.png" "$REPO_DIR/assets/home-modeling.png" "$APP_DIR/"
cp -R "$REPO_DIR/assets/game-runtime" "$APP_DIR/game-runtime"
ffmpeg -hide_banner -loglevel error -f lavfi -i color=c=red:s=320x180:r=30:d=3 -an -c:v libx264 -pix_fmt yuv420p -y "$APP_DIR/red.mov"
ffmpeg -hide_banner -loglevel error -f lavfi -i color=c=blue:s=180x320:r=30:d=3 -an -c:v libx264 -pix_fmt yuv420p -y "$APP_DIR/blue.mov"
# Production entry point main.swift and all Tests are excluded by explicit list.
xcrun --sdk iphonesimulator swiftc -swift-version 5 -O -sdk "$SDK" \
  -target arm64-apple-ios16.0-simulator -module-cache-path "$OUTPUT_DIR/ModuleCache" \
  "$REPO_DIR/StudioAccount.swift" "$SOURCE_DIR/Sources/MobileAccount.swift" \
  "$SOURCE_DIR/Sources/MobileProject.swift" "$SOURCE_DIR/Sources/VideoEngine.swift" \
  "$SOURCE_DIR/Sources/WorkspaceViews.swift" "$SOURCE_DIR/Sources/EditorViewController.swift" \
  "$SOURCE_DIR/Sources/StudioWorkspaceCard.swift" \
  "$REPO_DIR/GameProject.swift" "$REPO_DIR/GameGraph.swift" "$REPO_DIR/GameRuntime.swift" "$REPO_DIR/GameEditingSupport.swift" "$REPO_DIR/GameExport.swift" "$REPO_DIR/GameModelSupport.swift" \
  "$REPO_DIR/ModelingDocument.swift" "$REPO_DIR/ModelingSculpt.swift" "$REPO_DIR/ModelingGenerators.swift" "$REPO_DIR/ModelingPhysics.swift" \
  "$SOURCE_DIR"/Sources/GameWorkspace*.swift "$SOURCE_DIR"/Sources/ModelingWorkspace*.swift \
  "$SOURCE_DIR/Tests/GameWorkspaceChecks.swift" "$SOURCE_DIR/Tests/ModelingWorkspaceChecks.swift" \
  "$REPO_DIR/PhotoRaster.swift" "$REPO_DIR/PhotoDocumentCore.swift" "$REPO_DIR/PhotoRenderEngine.swift" \
  "$REPO_DIR/PhotoProjectCodec.swift" "$REPO_DIR/PhotoEditingSession.swift" \
  "$SOURCE_DIR/Sources/PhotoCanvasView.swift" "$SOURCE_DIR/Sources/PhotoBrushLibraryView.swift" "$SOURCE_DIR/Sources/PhotoLayerPanelView.swift" "$SOURCE_DIR/Sources/PhotoColourControls.swift" "$SOURCE_DIR/Sources/PhotoEditorViewController.swift" \
  "$SOURCE_DIR/Tests/PhotoLayerPanelChecks.swift" "$SOURCE_DIR/Tests/PhotoColourControlsChecks.swift" "$SOURCE_DIR/Tests/PhotoExportLifecycleChecks.swift" "$SOURCE_DIR/Tests/PhotoBrushLibraryChecks.swift" "$SOURCE_DIR/Tests/PhotoWorkspaceChecks.swift" "$SOURCE_DIR/Tests/WorkspaceChecks.swift" \
  -framework UIKit -framework AVFoundation -framework AVKit -framework CoreImage -framework CoreVideo \
  -framework Security -framework UniformTypeIdentifiers -framework SceneKit -framework ModelIO -o "$APP_DIR/NetVistaStudio"
codesign --force --sign - "$APP_DIR"
printf 'Isolated simulator QA app (not for distribution): %s\n' "$APP_DIR"
