#!/bin/bash
set -euo pipefail
SOURCE_DIR="$(cd "$(dirname "$0")" && pwd)"
CHECK_DIR="$(mktemp -d /private/tmp/netvista-ipad-checks.XXXXXX)"
swiftc "$SOURCE_DIR/Sources/MobileProject.swift" "$SOURCE_DIR/Tests/ProjectChecks.swift" \
  -module-cache-path "$CHECK_DIR/ModuleCache" -o "$CHECK_DIR/project-checks"
"$CHECK_DIR/project-checks"
swiftc "$SOURCE_DIR/Sources/MobileProject.swift" "$SOURCE_DIR/Tests/AnimationChecks.swift" \
  -module-cache-path "$CHECK_DIR/ModuleCache" -o "$CHECK_DIR/animation-checks"
"$CHECK_DIR/animation-checks"
ffmpeg -hide_banner -loglevel error -f lavfi -i color=c=red:s=320x180:r=30:d=3 \
  -an -c:v libx264 -pix_fmt yuv420p "$CHECK_DIR/red.mov"
ffmpeg -hide_banner -loglevel error -f lavfi -i color=c=blue:s=128x240:r=30:d=3 \
  -f lavfi -i sine=frequency=440:duration=3 -c:v libx264 -pix_fmt yuv420p -c:a aac -shortest "$CHECK_DIR/blue-source.mov"
ffmpeg -hide_banner -loglevel error -i "$CHECK_DIR/blue-source.mov" -c copy -metadata:s:v:0 rotate=90 "$CHECK_DIR/blue.mov"
swiftc -swift-version 5 "$SOURCE_DIR/Sources/MobileProject.swift" "$SOURCE_DIR/Sources/VideoEngine.swift" "$SOURCE_DIR/Tests/SequenceChecks.swift" \
  -module-cache-path "$CHECK_DIR/ModuleCache" -o "$CHECK_DIR/sequence-checks"
"$CHECK_DIR/sequence-checks" "$CHECK_DIR"
# Check encoded audio energy, not merely presence of an empty audio track.
ffmpeg -hide_banner -i "$CHECK_DIR/out.mp4" -ss 1.3 -t 1.0 -vn -af volumedetect -f null - 2>&1 | tee "$CHECK_DIR/audio-check.txt"
if grep -q 'mean_volume: -inf' "$CHECK_DIR/audio-check.txt"; then
  printf 'Exported second-clip audio is silent\n' >&2; exit 1
fi
printf 'Verification fixtures retained at %s\n' "$CHECK_DIR"
