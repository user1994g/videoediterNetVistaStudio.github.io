# NetVista Studio for Windows and Linux (Beta)

This is the native desktop Windows/Linux edition of NetVista Studio. It uses Qt for the operating-system window, controls, drag and drop, media playback, and native file dialogs. It is **not a website or browser wrapper**. FFmpeg provides portable timeline preview and final delivery.

## What works

- Open and save the same `.netvistastudio` JSON project format used by the Mac edition. Unknown/new project fields are preserved when saving.
- Import video or audio with the button or by dropping files into the application.
- Put any number of clips side by side on one lane or move clips between unlimited video/audio lanes.
- Linked picture and sound placement, clip selection, deletion, cutting at the playhead, timeline zoom, and playback of an automatically rendered timeline preview.
- Studio Home stays accessible while editing. The native media pool, monitor,
  timeline and inspector use the Mac palette and compact typography, including
  the same coast artwork on Home. Inspector readouts stay visible at 960×640.
- Drag sources from the Media Pool directly onto timeline tracks. Split linked
  video/audio together, duplicate, toggle linking/snapping, scrub, fit the
  timeline, and undo/redo up to 50 edits without copying media files.
- Edit scale, opacity, colour, effects and volume values from the same workspace pages and keep those values in the shared project.
- Motion includes position, rotation and zoom above 100%; zero opacity really
  becomes transparent. Blur/sharpen and colour use the same processing path in
  single-frame previews and movie export. Editing one property leaves other Mac
  values and unknown project fields intact.
- Preserve editable 3D scene data and add portable OBJ, DAE, GLTF, GLB or USDZ model references.
- Export MP4, MOV or MKV at 24–120 fps using H.264, HEVC, AV1 or ProRes when the bundled FFmpeg build supports the encoder.
- Output presets from 720p through **16K (15360 × 8640)** plus an even-sized custom width/height option.
- Press **Update** in the top bar to check public GitHub releases, download the correct Windows or Linux beta to Downloads, and verify its published size and SHA-256 digest before installation.
- Open **Mods** to install portable `.netvistamod` creator packs by button or drag-and-drop, switch them on or off, remove them, and open the persistent per-user Mods folder. Mods v1 use checked declarative data for themes, pages, and viewable creator catalogs; catalog maps, props, and presets are not applied automatically in this beta. Mods never run creator scripts or native code.

16K controls are available, but selecting a preset does not establish that a
particular encoder/device can deliver that raster. It needs substantial memory,
storage and render time. NetVista selects HEVC rather than H.264 for 16K by
default; the workspace preview checks below verify small decoded exports, not a
certification of every 16K codec or high-resolution delivery.

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

The packaged app is written to `dist/NetVistaStudio`. The artifact-only
`build-cross-platform.yml` workflow can be dispatched on a development branch.
It verifies the frozen app enters its native event loop, then executes the
bundled FFmpeg to encode H.264 and decode expected pixels. It uploads a Windows
ZIP or Linux TAR.GZ containing the complete folder; Linux executable bits remain
intact. Extract the whole archive, not just the executable. These are portable
development previews, not installers, signatures or public-release updates.

The separate release workflow publishes exact, approved release tags. Ordinary
preview builds do not replace public downloads or change GitHub tags.

## Current beta difference

The portable edition seeks and renders only active source frames for paused
slider edits and scrubbing. It renders a full FFmpeg movie proxy when playback
is requested, so a complex timeline can take a moment before playing. The Mac
edition uses its AVFoundation live compositor. Animated SceneKit 3D editing,
maps, physics, rig posing and the photo/game/model editors remain Mac-specific;
this edition preserves scenes and model references without rendering them. The
`.netvistamod` manifest format is shared; see [`../MODDING.md`](../MODDING.md).
