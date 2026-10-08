#!/bin/bash
set -euo pipefail
SOURCE_DIR="$(cd "$(dirname "$0")/.." && pwd)"
CHECK_DIR="$(mktemp -d /private/tmp/netvista-ios-effects.XXXXXX)"
printf 'iOS effect fixtures: %s\n' "$CHECK_DIR"
if [ -d /Applications/Xcode-beta.app/Contents/Developer ]; then
  export DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer
fi
ffmpeg -hide_banner -loglevel error -f lavfi -i color=c=red:s=320x180:r=30:d=1 \
  -vf 'drawbox=x=160:y=0:w=160:h=90:color=lime:t=fill,drawbox=x=0:y=90:w=160:h=90:color=blue:t=fill,drawbox=x=160:y=90:w=160:h=90:color=white:t=fill' \
  -an -c:v libx264 -pix_fmt yuv420p "$CHECK_DIR/quadrants.mov"
swiftc -swift-version 5 "$SOURCE_DIR/Sources/MobileProject.swift" "$SOURCE_DIR/Sources/VideoEngine.swift" \
  "$SOURCE_DIR/Tests/EffectsPixelChecks.swift" -module-cache-path "$CHECK_DIR/ModuleCache" \
  -o "$CHECK_DIR/effects-pixel-checks"
"$CHECK_DIR/effects-pixel-checks" "$CHECK_DIR"
