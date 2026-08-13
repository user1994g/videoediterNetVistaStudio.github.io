# NetVista Studio

NetVista Studio is a native desktop video editor. The macOS edition is built with Swift, Cocoa, AVFoundation, SceneKit, SpriteKit, Core Image, and VideoToolbox. A native Qt/FFmpeg Windows and Linux beta lives in [`cross_platform`](cross_platform/README.md). Neither edition is a website or browser wrapper.

## Project website

The website is published at [video.netvistastudio.com](https://video.netvistastudio.com/). Its GitHub Pages source lives in [`docs/`](docs/), and the included workflow publishes changes after they reach `main` or `master`.

## Public beta download

Download **NetVista Studio 1.2 Beta 1** from the [GitHub Releases page](https://github.com/user1994g/videoediterNetVistaStudio.github.io/releases/tag/v1.2.0-beta.1). Downloads are available for macOS, Windows, and Linux. This is early beta software, so expect bugs or incomplete features and keep backups of important project files.

The current macOS beta is ad-hoc signed and therefore triggers a Gatekeeper warning. The repository includes a secure Developer ID signing and Apple notarization workflow; see [`MACOS_RELEASE.md`](MACOS_RELEASE.md). After the Apple credentials are configured and that workflow publishes a replacement ZIP, macOS users can open the download normally.

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
- The Export page supports 720p, 1080p, 1440p, 4K, 8K, 16K and custom frame sizes, MP4 or MOV, H.264 or HEVC, 24/25/30/60 fps, AAC audio, hardware capability checks, progress, and cancellation. The Windows/Linux beta also offers 6K/12K presets, AV1, ProRes and MKV through FFmpeg.
- Export includes timeline placement, trims, layered video, transforms, keyframes, per-clip colour grades and effects, and mixed audio.
- Exports and 3D renders use safe staging files so cancellation or encoder failure does not destroy an existing movie at the selected destination.
- Imported 3D assets are referenced in place; NetVista Studio does not copy, modify, or delete the original model. Keep OBJ material and texture files beside the OBJ when moving the set.

## Share on your local network

- Press **Share** to start a temporary server and pairing code. The Share window shows the Mac's private local IP address, such as `http://192.168.1.118:58045/`.
- Open that exact address on an iPad, phone, or computer connected to the same Wi-Fi or wired LAN, then enter the six-digit code.
- Sharing never publishes the project to the internet and does not advertise `localhost` as the device address. Connections outside the Mac's current private subnet are rejected.
- If the router uses guest/client isolation, devices on the same Wi-Fi name may still be blocked from one another; use the main trusted network instead.

## Build it again

Run `sh build_app.sh` from this folder. The native sources include `NetVistaStudio.swift`, `ProfessionalTimelineView.swift`, `CubeLUT.swift`, `EffectsStudio.swift`, `SceneEditor.swift`, `NativeTimelineExportEngine.swift`, `ExportWorkspace.swift`, `ShareServer.swift`, and `SharePanel.swift`.

For Windows and Linux source/build instructions, see [`cross_platform/README.md`](cross_platform/README.md). GitHub Actions builds downloadable native packages for both operating systems.
