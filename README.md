# NetVista Studio

NetVista Studio is a native desktop video editor. The macOS edition is built with Swift, Cocoa, AVFoundation, SceneKit, SpriteKit, Core Image, and VideoToolbox. A native Qt/FFmpeg Windows and Linux beta lives in [`cross_platform`](cross_platform/README.md). Neither edition is a website or browser wrapper.

## Project website

The website is published at [video.netvistastudio.com](https://video.netvistastudio.com/). Its GitHub Pages source lives in [`docs/`](docs/), and the included workflow publishes changes after they reach `main` or `master`.

## Public beta download

Download **NetVista Studio 1.4 Beta 4** from the [GitHub Releases page](https://github.com/user1994g/videoediterNetVistaStudio.github.io/releases/tag/v1.4.0-beta.4). Downloads are available for macOS, Windows, and Linux. This is early beta software, so expect bugs or incomplete features and keep backups of important project files.

The current macOS beta is ad-hoc signed and therefore triggers a Gatekeeper warning. The repository includes a secure Developer ID signing and Apple notarization workflow; see [`MACOS_RELEASE.md`](MACOS_RELEASE.md). After the Apple credentials are configured and that workflow publishes a replacement ZIP, macOS users can open the download normally.

## Open the app

Double-click `NetVista Studio.app` in Finder.

### Studio Home (macOS)

The native welcome screen has artwork-led Video Editor and Photo Editor launch
tiles, a persistent workspace sidebar, and real recent-project search with
All / Video / Photos filters. Editors keep their own windows and document state.
Use **Studio Home** to switch without closing a project. The main area scrolls
on smaller displays; artwork stays proportional and controls remain usable.
The [design specification, research and artwork prompts](design/STUDIO_HOME.md)
document the mockup-to-native implementation.

## Game Maker (macOS beta)

Studio Home → **Game Maker** opens an empty 2D or 3D scene. Import PNG/JPG
sprites or 3D models, place them from Assets, and connect draggable visual nodes
with wires. Add humanoid rigs and walking cycles, sprite-sheet animation,
conditions and variables. Each object has its own graph and scene-layer order. Preview with Play/Stop, save embedded assets and behaviours in
`.netvistagame`, or export a playable **Three.js** or **Python/Panda3D** source
project. This is a small beta game engine, not a complete Unity/Godot replacement.
Character/sprite-sheet animations currently play in the native preview; their
source export is not yet supported. See [Game Maker guide and limits](GAME_MAKER.md). These additions are included in the macOS beta and are not part of the Windows/Linux editor.

## App updates

- On macOS, the app checks at startup and every six hours while open. A new release offers **Update** and **Not right now**. Offline startup checks stay quiet.
- Press **Update** on Studio Home, in the Video Editor, or **Check for Updates…** in the app menu to check manually.
- Beta and full releases are compared using their complete release tag, so each newer beta correctly replaces the prior beta and a final release correctly replaces any beta.
- The macOS updater downloads to a private cache, verifies the published SHA-256 and size, checks the ZIP, bundle identity, version, processor and app signature, then stages the replacement next to the installed app.
- Open video/3D and layered photo work is captured before restart. The helper waits for the old process to quit, replaces that exact app path and reopens it. The previous app is retained until the new app confirms startup; failed installs can roll back. No ZIP unpacking or second app copy is needed.
- Recovery copies stay in `~/Library/Application Support/NetVista Studio/Update Recovery`. Original project files are not overwritten by recovery. Undo history and temporary selections are not restored.
- Active exports/renders must finish before updating. A read-only or translocated app must first be moved to a writable folder. Updates cannot bypass macOS permissions or Gatekeeper.
- This install-and-restart flow is macOS-only; the Windows/Linux beta retains its existing package download flow. See [updater implementation and release checks](UPDATING.md).

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
- The advanced Colour workspace also provides a reorderable node stack, editable Master/RGB and hue/luma curves, HSL qualifiers with softness/invert controls, waveform/parade/histogram/vectorscope scopes, and portable 17³/33³/65³ `.cube` export.
- Import 3D `.cube` LUT files, preview them live, adjust their mix from 0–100%, remove them non-destructively, and apply one grade to one or many selected video clips. Imported LUT data is embedded in the project save so the look survives if the original `.cube` file moves.
- The Effects page opens a separate resizable native Effects Studio for position, scale, rotation, opacity, blur, sharpen, vignette, monochrome, sepia, glow, vintage, and keyframes.
- Add transform, opacity, or volume keyframes at the playhead with smooth, linear, or hold interpolation.
- The macOS 3D Scene page provides a native workspace with objects, materials, lighting, shadows, reflections, camera controls, video planes, and live green-screen removal.
- The 3D inspector separates **Object**, **Rig**, and **World** tools. Choose **Move**, **Rotate**, or **Scale** above the viewport and drag to transform the selected object; Shift changes the movement/rotation axis. Choose **Orbit** to navigate again, or press **F** to frame the selection.
- Duplicate and delete scene objects from the outliner, with scene Undo/Redo. Delete/Backspace also removes the selected object while the viewport has focus. Object drags update existing animation tracks at the playhead; **Auto key** also starts a new track.
- The Rig tab offers **Key whole pose**, previous/next key navigation, and automatic bone-rotation keys. Click a visible rig joint to select it. Rig guides are editor-only and do not appear in exported scenes.
- Import your own OBJ, ABC, PLY, STL, USD, USDA, USDC, USDZ, DAE, or SCN models by button or drag-and-drop, then position, rotate, scale, tint, rename, or remove them like built-in objects.
- Build an editable map from native terrain/stage presets, choose an environment, and give scene objects Off, Static, Dynamic, or Kinematic physics with mass, gravity, friction, and bounce controls.
- Animate object transforms and the scene camera with a dedicated scene playhead and smooth, linear, or hold keyframes. The same evaluator drives the live viewport and offline scene render.
- For imported models, **Create / bind humanoid rig** builds a starter 17-joint skeleton with distance-weighted mesh binding. Select hands, arms, legs, head, or any other joint, pose it, and store bone-rotation keyframes; authored rigs are saved in the scene and restored for offline renders. Complex production skinning is still best prepared in a modelling tool.
- Add a video plane, click it in the scene, and enable Chroma Key to remove its green screen while it remains part of the 3D world.
- **Save 3D Work…** stores an editable `.netvistascene` without making a movie. Unrendered scenes also stay inside the main project and can be reopened from the saved-scene list.
- **Render Clip…** is optional. Use it only when you want a timeline-compatible ProRes movie of the 3D scene.

## Mods

- Open the **Mods** page to install a `.netvistamod` package by button or drag-and-drop, open the persistent Mods folder, and enable, disable, update, or remove installed mods.
- Mods are saved in the operating system's per-user app-data folder, not inside the signed application, so replacing NetVista Studio with an update does not erase them.
- Mods v1 are data-only and can apply bounded themes, provide declarative pages, and display checked catalog entries for future 3D props/maps and effect presets. Catalog assets are not inserted into scenes or clips automatically in this beta. Mods cannot silently run Python, JavaScript, Swift, native libraries, shell scripts, or executables inside the editor.
- Package paths, sizes, declared capabilities, app compatibility, dependencies, and SHA-256 file hashes are checked before installation. A new mod stays disabled until the user switches it on.
- See [`MODDING.md`](MODDING.md) for the creator format and a complete package example.

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

### Native photo editor

The macOS Photos workspace now includes blank documents and presets, pixel painting and retouching tools, selection-aware editing, masks, folders, adjustment layers, sampled ABR tip import, and self-contained `.netvistaphoto` projects. Its compact menu/toolbar layout keeps layer opacity and blending in the Layers dock. See [the photo editor guide](PHOTO_EDITOR.md) for workflows, compatibility boundaries and regression checks. These additions are not yet ported to the Windows/Linux editor.

Run `sh build_app.sh` from this folder. The native sources include `NetVistaStudio.swift`, `StudioHome.swift`, `PhotoEditor.swift`, `PhotoRaster.swift`, `ProfessionalTimelineView.swift`, `AdvancedGrade.swift`, `AdvancedColorStudio.swift`, `CubeLUT.swift`, `EffectsStudio.swift`, `SceneEditor.swift`, `SceneRigging.swift`, `NativeTimelineExportEngine.swift`, `ExportWorkspace.swift`, `ShareServer.swift`, `SharePanel.swift`, `AppUpdateService.swift`, and the `Mod*.swift`/`ModsStudio.swift`/`StudioTheme.swift` mod system.

For Windows and Linux source/build instructions, see [`cross_platform/README.md`](cross_platform/README.md). GitHub Actions builds downloadable native packages for both operating systems.
