#!/bin/sh
set -eu
APP="NetVista Studio.app"
mkdir -p "$APP/Contents/MacOS"
cp NetVistaStudio-Info.plist "$APP/Contents/Info.plist"
CLANG_MODULE_CACHE_PATH=/private/tmp/netvista_studio_swift_cache xcrun swiftc \
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
    -framework SystemConfiguration \
    -framework CoreImage \
    CubeLUT.swift \
    UltraKey.swift \
    ShareServer.swift \
    SharePanel.swift \
    ProfessionalTimelineView.swift \
    NetVistaStudio.swift \
    EffectsStudio.swift \
    NativeTimelineExportEngine.swift \
    ExportWorkspace.swift \
    SceneEditor.swift \
    -o "$APP/Contents/MacOS/NetVistaStudio"
codesign --force --sign - "$APP"
echo "Built $APP"
