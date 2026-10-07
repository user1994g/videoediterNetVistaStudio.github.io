# Procedural native-export fixtures

These two 3-second clips contain only generated solid colours and a sine tone.
No user media, accounts, remote footage or model downloads are used. They belong
only to the instrumentation APK; release APKs do not include `androidTest` assets.

- `red-silent-landscape.mp4`: 320×180, 30fps H.264 baseline, no audio; 4,044 bytes.
- `blue-audio-portrait.mp4`: 128×240, 30fps H.264 baseline, mono 48kHz AAC 440Hz tone; 30,624 bytes.

Generated using local FFmpeg 8.1.2. From this directory, regenerate with:

```sh
ffmpeg -hide_banner -loglevel error -f lavfi -i 'color=c=red:s=320x180:r=30:d=3' -an -c:v libx264 -preset veryfast -profile:v baseline -level 3.0 -pix_fmt yuv420p -g 15 -bf 0 -threads 1 -movflags +faststart red-silent-landscape.mp4
ffmpeg -hide_banner -loglevel error -f lavfi -i 'color=c=blue:s=128x240:r=30:d=3' -f lavfi -i 'sine=frequency=440:sample_rate=48000:duration=3' -c:v libx264 -preset veryfast -profile:v baseline -level 3.0 -pix_fmt yuv420p -g 15 -bf 0 -threads 1 -c:a aac -b:a 64k -ar 48000 -ac 1 -shortest -movflags +faststart blue-audio-portrait.mp4
```

SHA-256 of the checked-in fixtures:

```text
6b0899c7de0c71bbc4e0b66a30f4e88da2c405c74924e49f81d8c35023e5a327  red-silent-landscape.mp4
bd9e4039fcb774bfc903e67c1632f6519652d8b540fb45f090dd1277b9835ed3  blue-audio-portrait.mp4
```

`MobileExportIntegrationTest` imports both through `ProjectFiles`, reorders and
trims them, saves/reopens a self-contained project after removing the original
imports, and performs a real main-thread Media3 export. It checks encoded H.264
720p frames, 2.8-second duration, portrait side bars, red/blue sequence boundaries,
an AAC track, and decoded silent/audible PCM energy. Export and decoder waits are
bounded. Only uniquely created test files are removed, and no Activity/auth gate
is started or bypassed.

Run on a graphics/codec-enabled emulator or device:

```sh
gradle --no-daemon -p mobile/android :app:connectedDebugAndroidTest
```
