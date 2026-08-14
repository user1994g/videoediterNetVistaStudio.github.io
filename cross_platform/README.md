# NetVista Studio for Windows and Linux (Beta)

This is the native desktop Windows/Linux edition of NetVista Studio. It uses Qt for the operating-system window, controls, drag and drop, media playback, and native file dialogs. It is **not a website or browser wrapper**. FFmpeg provides portable timeline preview and final delivery.

## What works

- Open and save the same `.netvistastudio` JSON project format used by the Mac edition. Unknown/new project fields are preserved when saving.
- Import video or audio with the button or by dropping files into the application.
- Put any number of clips side by side on one lane or move clips between unlimited video/audio lanes.
- Linked picture and sound placement, clip selection, deletion, cutting at the playhead, timeline zoom, and playback of an automatically rendered timeline preview.
- Edit scale, opacity, colour, effects and volume values from the same workspace pages and keep those values in the shared project.
- Preserve editable 3D scene data and add portable OBJ, DAE, GLTF, GLB or USDZ model references.
- Export MP4, MOV or MKV at 24–120 fps using H.264, HEVC, AV1 or ProRes when the bundled FFmpeg build supports the encoder.
- Output presets from 720p through **16K (15360 × 8640)** plus an even-sized custom width/height option.
- Press **Update** in the top bar to check public GitHub releases, download the correct Windows or Linux beta to Downloads, and verify its published size and SHA-256 digest before installation.
- Open **Mods** to install portable `.netvistamod` creator packs by button or drag-and-drop, switch them on or off, remove them, and open the persistent per-user Mods folder. Mods v1 use checked declarative data for themes, pages, and viewable creator catalogs; catalog maps, props, and presets are not applied automatically in this beta. Mods never run creator scripts or native code.

16K delivery is real, but it requires an encoder that accepts the raster and a computer with substantial memory, storage and render time. NetVista Studio selects HEVC rather than H.264 for 16K by default.

## Run from source

Install Python 3.10 or newer, then:

### Windows

```powershell
py -m venv .venv
.\.venv\Scripts\python -m pip install -r requirements.txt
.\.venv\Scripts\python app.py
```

### Linux

```sh
python3 -m venv .venv
. .venv/bin/activate
python -m pip install -r requirements.txt
python app.py
```

The `imageio-ffmpeg` package supplies a portable FFmpeg executable. Set `NETVISTA_FFMPEG` to use another build.

## Build a distributable app

- Windows: `powershell -ExecutionPolicy Bypass -File build_windows.ps1`
- Linux: `sh build_linux.sh`

The packaged app is written to `dist/NetVistaStudio`. GitHub Actions runs the same builds and publishes downloadable Windows and Linux ZIP artifacts for every tagged release.

## Current beta difference

The portable edition uses an FFmpeg preview proxy for a complete layered sequence, so a complex timeline can take a moment to refresh after an edit. The Mac edition continues to use its AVFoundation live compositor. Animated SceneKit 3D editing, maps, physics, and rig posing remain Mac-specific in this beta; the Windows/Linux edition preserves those scenes and portable model references without deleting them. The `.netvistamod` manifest format is shared by all three systems; see [`../MODDING.md`](../MODDING.md).
