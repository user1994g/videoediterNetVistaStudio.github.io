#!/bin/sh
set -eu
APP="NetVista Studio.app"
CACHE_DIR=$(mktemp -d /private/tmp/netvista_studio_swift_cache.XXXXXX)
trap 'rm -rf "$CACHE_DIR"' EXIT HUP INT TERM
mkdir -p "$APP/Contents/MacOS"
mkdir -p "$APP/Contents/Resources"
cp NetVistaStudio-Info.plist "$APP/Contents/Info.plist"
cp assets/NetVistaStudio.icns "$APP/Contents/Resources/NetVistaStudio.icns"
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
    UltraKey.swift \
    ShareServer.swift \
    SharePanel.swift \
    AppUpdateService.swift \
    ModModels.swift \
    StudioTheme.swift \
    ModManager.swift \
    ModsStudio.swift \
    ProfessionalTimelineView.swift \
    NetVistaStudio.swift \
    EffectsStudio.swift \
    NativeTimelineExportEngine.swift \
    ExportWorkspace.swift \
    SceneEditor.swift \
    -o "$APP/Contents/MacOS/NetVistaStudio"
SIGNING_IDENTITY=${CODESIGN_IDENTITY:--}
if [ "$SIGNING_IDENTITY" = "-" ]; then
    codesign --force --sign - "$APP"
    echo "Built $APP with a local ad-hoc signature"
elif [ -n "${CODESIGN_KEYCHAIN:-}" ]; then
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
    codesign \
        --force \
        --options runtime \
        --timestamp \
        --sign "$SIGNING_IDENTITY" \
        "$APP"
    codesign --verify --deep --strict --verbose=2 "$APP"
    echo "Built $APP with Developer ID: $SIGNING_IDENTITY"
fi
