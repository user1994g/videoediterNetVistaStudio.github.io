# NetVista Studio

NetVista Studio is a native macOS desktop video editor built with Swift, Cocoa, AVFoundation, SceneKit, SpriteKit, Core Image, and VideoToolbox. It does not use a website, browser view, HTML interface, or WebKit.

## Project website

The website is published at [video.netvistastudio.com](https://video.netvistastudio.com/). Its GitHub Pages source lives in [`docs/`](docs/), and the included workflow publishes changes after they reach `main` or `master`.

## Public beta download

Download **NetVista Studio 1.1 Beta 1** from the [GitHub Releases page](https://github.com/user1994g/videoediterNetVistaStudio.github.io/releases/tag/v1.1.0-beta.1). This early beta requires an Apple-silicon Mac running macOS 11 or newer. It is ad-hoc signed and not Apple-notarized yet, so Control-click the app and choose **Open** on first launch. Expect bugs or incomplete features and keep backups of important project files.

## Open the app

Double-click `NetVista Studio.app` in Finder.

## Editing

- Import one or many video and audio files through the native file picker, or drag files from Finder directly onto the timeline.
- Drag Media Pool items onto the timeline as many times as needed.
- Move clips smoothly to any time or onto as many video and audio layers as the edit needs. A fresh empty layer appears automatically above the current highest layer.
- The timeline has a pinned time ruler and pinned track names, frame-accurate edge trimming, marquee and Command-click multi-selection, an 8-point magnetic snap guide, edge auto-scroll, and linked video/audio movement.
- Zoom with the **− / + / Fit** controls, pinch on a trackpad, or Option-scroll beneath the pointer. Track height can be changed separately with **H− / H+**.
- Use **Selection: Linked** to select video and sound together. Use **Selection: Single**, or Option-click, to select only the video or sound.
- Delete the visible selection with **Delete Selected**, Delete, or Backspace. Linked, single, and Command-click multi-selections are supported, and Undo restores clips, links, selection, and playhead position.
- **Remove selected media** removes an unused item from the Media Pool without deleting the original file. Media used by a timeline or 3D scene is protected until those uses are removed.
- Detach selected audio and move it independently to any audio layer.
- Use the Select Tool to move clips and the Blade Tool or **Cut at playhead** to split them.
- The monitor plays the assembled timeline, fits the full video inside the viewer, and updates the red playhead during playback.

## Creative tools

- The Color page opens a separate resizable native Color Studio with interactive Lift, Gamma/Midtones, and Gain wheels, master/luma controls, exact RGB values, primary sliders, and preset looks.
- Import 3D `.cube` LUT files, preview them live, adjust their mix from 0–100%, remove them non-destructively, and apply one grade to one or many selected video clips. Imported LUT data is embedded in the project save so the look survives if the original `.cube` file moves.
- The Effects page opens a separate resizable native Effects Studio for position, scale, rotation, opacity, blur, sharpen, vignette, monochrome, sepia, glow, vintage, and keyframes.
- Add transform, opacity, or volume keyframes at the playhead with smooth, linear, or hold interpolation.
- The 3D Scene page provides a native workspace with objects, materials, lighting, shadows, reflections, camera controls, video planes, and manual green-screen removal.
- Import your own OBJ, ABC, PLY, STL, USD, USDA, USDC, USDZ, DAE, or SCN models by button or drag-and-drop, then position, rotate, scale, tint, rename, or remove them like built-in objects.
- **Save 3D Work…** stores an editable `.netvistascene` without making a movie. Unrendered scenes also stay inside the main project and can be reopened from the saved-scene list.
- **Render Clip…** is optional. Use it only when you want a timeline-compatible ProRes movie of the 3D scene.

## Save and export

- Save complete projects as `.netvistastudio` files and standalone editable 3D scenes as `.netvistascene` files. Save and export dialogs open in Downloads by default while still allowing any other folder.
- Existing `.swiftediter` projects and `.swiftscene` scenes remain openable for backwards compatibility; new saves use the NetVista Studio formats.
- The Export page supports 1080p, 4K, and 8K, MP4 or MOV, H.264 or HEVC, 24/25/30/60 fps, AAC audio, hardware capability checks, progress, and cancellation.
- Export includes timeline placement, trims, layered video, transforms, keyframes, per-clip colour grades and effects, and mixed audio.
- Exports and 3D renders use safe staging files so cancellation or encoder failure does not destroy an existing movie at the selected destination.
- Imported 3D assets are referenced in place; NetVista Studio does not copy, modify, or delete the original model. Keep OBJ material and texture files beside the OBJ when moving the set.

## Build it again

Run `sh build_app.sh` from this folder. The native sources include `NetVistaStudio.swift`, `ProfessionalTimelineView.swift`, `CubeLUT.swift`, `EffectsStudio.swift`, `SceneEditor.swift`, `NativeTimelineExportEngine.swift`, `ExportWorkspace.swift`, `ShareServer.swift`, and `SharePanel.swift`.
