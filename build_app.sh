#!/bin/sh
set -eu
APP="NetVista Studio.app"
CACHE_DIR=$(mktemp -d /private/tmp/netvista_studio_swift_cache.XXXXXX)
trap 'rm -rf "$CACHE_DIR"' EXIT HUP INT TERM
mkdir -p "$APP/Contents/MacOS"
mkdir -p "$APP/Contents/Resources"
mkdir -p "$APP/Contents/Helpers"
cp NetVistaStudio-Info.plist "$APP/Contents/Info.plist"
cp assets/NetVistaStudio.icns "$APP/Contents/Resources/NetVistaStudio.icns"
cp assets/welcome-studio-hero.png "$APP/Contents/Resources/welcome-studio-hero.png"
cp assets/home-video-coast.png "$APP/Contents/Resources/home-video-coast.png"
cp assets/home-photo-petals.png "$APP/Contents/Resources/home-photo-petals.png"
mkdir -p "$APP/Contents/Resources/game-runtime"
for GAME_RUNTIME_FILE in assets/game-runtime/*; do
    if [ -f "$GAME_RUNTIME_FILE" ]; then
        cp "$GAME_RUNTIME_FILE" "$APP/Contents/Resources/game-runtime/"
    fi
done
CLANG_MODULE_CACHE_PATH="$CACHE_DIR" xcrun swiftc \
    -target arm64-apple-macos11.0 -suppress-warnings \
    -framework Cocoa -framework Security \
    AppUpdateService.swift UpdateInstaller.swift UpdateHelper.swift \
    -o "$APP/Contents/Helpers/NetVistaUpdateHelper"
CLANG_MODULE_CACHE_PATH="$CACHE_DIR" xcrun swiftc \
    -target arm64-apple-macos11.0 \
    -suppress-warnings \
    -framework Cocoa \
    -framework AVKit \
    -framework AVFoundation \
    -framework SceneKit \
    -framework ModelIO \
    -framework SpriteKit \
    -framework VideoToolbox \
    -framework Network \
    -framework Security \
    -framework CoreImage \
    CubeLUT.swift \
    AdvancedGrade.swift \
    UltraKey.swift \
    ShareServer.swift \
    SharePanel.swift \
    AppUpdateService.swift \
    UpdateInstaller.swift \
    UpdateRecovery.swift \
    AppUpdateCoordinator.swift \
    StudioAccount.swift \
    StudioAccountWindow.swift \
    ModModels.swift \
    StudioTheme.swift \
    ModManager.swift \
    ModsStudio.swift \
    ProfessionalTimelineView.swift \
    NetVistaStudio.swift \
    StudioHome.swift \
    GameProject.swift \
    GameGraph.swift \
    GameModelSupport.swift \
    GameRuntime.swift \
    GameExport.swift \
    GameLogicPanel.swift \
    GameEditor.swift \
    PhotoEditor.swift \
    PhotoRaster.swift \
    EffectsStudio.swift \
    NativeTimelineExportEngine.swift \
    ExportWorkspace.swift \
    SceneRigging.swift \
    SceneEditor.swift \
    AdvancedColorStudio.swift \
    -o "$APP/Contents/MacOS/NetVistaStudio"
SIGNING_IDENTITY=${CODESIGN_IDENTITY:--}
if [ "$SIGNING_IDENTITY" = "-" ]; then
    codesign --force --sign - "$APP/Contents/Helpers/NetVistaUpdateHelper"
    codesign --force --sign - "$APP"
    echo "Built $APP with a local ad-hoc signature"
elif [ -n "${CODESIGN_KEYCHAIN:-}" ]; then
    codesign --force --options runtime --timestamp --keychain "$CODESIGN_KEYCHAIN" --sign "$SIGNING_IDENTITY" "$APP/Contents/Helpers/NetVistaUpdateHelper"
    codesign \
        --force \
        --options runtime \
        --timestamp \
        --keychain "$CODESIGN_KEYCHAIN" \
        --sign "$SIGNING_IDENTITY" \
        "$APP"
    codesign --verify --deep --strict --verbose=2 "$APP"
    echo "Built $APP with Developer ID: $SIGNING_IDENTITY"
else
    codesign --force --options runtime --timestamp --sign "$SIGNING_IDENTITY" "$APP/Contents/Helpers/NetVistaUpdateHelper"
    codesign \
        --force \
        --options runtime \
        --timestamp \
        --sign "$SIGNING_IDENTITY" \
        "$APP"
    codesign --verify --deep --strict --verbose=2 "$APP"
    echo "Built $APP with Developer ID: $SIGNING_IDENTITY"
fi
