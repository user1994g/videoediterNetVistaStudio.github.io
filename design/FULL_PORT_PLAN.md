# Full native port — implementation contract

The requested product is the same NetVista creative suite on Mac, Windows,
Linux, iPad, iPhone and Android. A compact layout is acceptable; deleting
capabilities to make a mobile "light" edition is not the target. Current
development packages do **not** meet that target yet.

## Baseline audit (8 October 2026)

"Missing" below means missing real authoring/rendering functionality, not merely
a missing navigation button. Adding a decorative page does not close a gap.

| Capability | Mac | iPhone / iPad | Android | Windows / Linux |
| --- | --- | --- | --- | --- |
| Native source pool, import, save, preview, export, history | Implemented | Implemented | Implemented | Implemented |
| Arbitrary video/audio placement, layers and mixing | Implemented | Sequential linked clips only | Sequential linked clips only | Implemented |
| Animated effect controls and editable keyframe lanes | Implemented | In implementation | In implementation | Missing |
| Ordered effect stacks, chroma key and optional local AI matte | Implemented | Missing | Missing | Partial static effects |
| Wheels, curves, qualifiers, nodes, LUT authoring, scopes | Implemented | Missing UI/engine integration | Missing | Missing |
| Photo layers, masks, ABR brushes, selections and retouching | Implemented | Missing workspace | Missing | Missing |
| Mesh modelling, face editing, sculpting and physics | Implemented | Missing workspace | Missing | References only |
| Game authoring, node logic, play and source export | Implemented | Missing workspace | Missing | Missing |
| Mods and native extension/theme adapters | Implemented | Missing | Missing | Limited discovery |
| Desktop/mobile document interchange | Desktop formats | Mobile-specific format | Different mobile-specific format | Mac JSON preserved |

The Mac implementation is the feature baseline, not a claim that it has every
feature of Photoshop, Blender or Unreal. Existing Mac export limitations must
remain visible on every platform until they are actually resolved.

## Single-source components, native platform adapters

1. Keep Apple document/command/rendering engines separate from AppKit/UIKit
   controls. Compile existing `GameProject`, `GameGraph`, `GameRuntime`,
   `GameEditingSupport`, `GameExport`, `ModelingDocument`, `ModelingSculpt`,
   `ModelingGenerators` and `ModelingPhysics` directly for iOS. Do not copy/fork
   those implementations into the mobile folder.
2. `PhotoRaster.swift` now adapts only its native colour and PNG boundary for
   AppKit/UIKit. Brushes, erasing, masks, cloning, connected colour selection and
   ABR decoding are the same implementation. Photo document/layer/compositing
   state still needs extraction from `PhotoEditor.swift`; the workspace is not
   available just because the raster engine compiles.
3. `ColorWheelAdjustment` now lives with `AdvancedGrade.swift`, not the Mac
   application window. Compile it, `CubeLUT.swift` and `UltraKey.swift` unchanged
   for Apple devices. Native mobile controls, media integration and scopes remain
   required before claiming those grading/keying tools are usable in the app.
4. Android and Qt need processing adapters for these capabilities, not AppKit,
   SceneKit or Core Image calls. Define versioned document and command fixtures
   first, compare mathematical results and actual rendered/exported pixels, then
   build native interfaces. Reusing the model contract is not the same as having
   a renderer or a working workspace.

## Work order and acceptance gates

1. **Video animation (current work):** actual per-frame property evaluation in
   preview and export; visible seekable keyframes; all five Mac interpolation
   modes (hold, linear, ease-in, ease-out, ease-in/out);
   save/history/split/trim fidelity; migrations for existing projects. Verify
   encoded pixels at different times, not only saved settings.
2. **Timeline placement and mixing:** frame-accurate start/track/source ranges,
   independent sound/video, gaps, overlaps, compositing, audio gain/mute; arbitrary
   added lanes; linked edits, snapping, trim/slide/ripple policies. One placement
   model must drive monitor, export and drawing. Do not paint extra lanes while
   exporting a different sequential movie.
3. **Photo workspace:** share the Mac layer document/compositor, expose all
   existing commands, preserve native project data and imported ABR tips. Pixel
   tests for masks, blend modes, strokes, adjustments, transforms and exports;
   native phone/tablet layout/input tests for every tool.
4. **Modelling and game workspaces:** shared geometry/command/runtime models on
   Apple, equivalent contract implementations on Android/Qt. Real mesh hit tests,
   sculpt/deform/topology changes, save/export, undo, node execution and playback.
   Keep physics/playback non-destructive; do not substitute pre-rendered demos.
5. **Grading/effects suite:** shared Apple grade/key/LUT engines, validated
   equivalent other-platform adapters, effect/node ordering, curves, qualifiers,
   scopes and multi-clip commands. Optional model downloads require user action;
   missing models must not silently erase footage.
6. **Portable files, extensions, updates and release:** lossless interchange
   fixtures, asset packaging/relinking, permissions and secure native extension
   adapters. Device-specific filesystem limits need explicit errors, not dropped
   fields. Publish a new beta only after the affected engines and interfaces pass.

## Non-negotiable checks

- Same feature access on iPhone and iPad; panels may dock/scroll, but commands
  must not disappear because of screen size. Keep usable touch targets and allow
  keyboard/pointer workflows where supported.
- Preview and export execute the same saved operations at the same timestamps.
  Avoid stale decoding/render callbacks and unbounded per-gesture work.
- Capability checks for encoder/GPU/memory limits, including high resolutions;
  no universal 16K claim without actual hardware delivery checks.
- Core compile/unit tests, real image/video pixels, native interaction/layout
  tests, legacy save migration and physical device acceptance are distinct gates.
- Keep `NATIVE_WORKSPACE_STATUS.md`, release notes and download labels honest.
  A successful build or a shared-core test is not full feature parity.
