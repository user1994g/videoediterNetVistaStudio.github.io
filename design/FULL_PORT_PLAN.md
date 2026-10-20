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
| Animated effect controls and editable keyframe lanes | Implemented | 8 motion/primary controls; remaining Mac properties missing | 8 motion/primary controls; remaining Mac properties missing | Missing |
| Ordered effect stacks, chroma key and optional local AI matte | Implemented | Missing | Missing | Partial static effects |
| Wheels, curves, qualifiers, nodes, LUT authoring, scopes | Implemented | Missing UI/engine integration | Missing | Missing |
| Photo layers, masks, ABR brushes, selections and retouching | Implemented | Native workspace in development; shared Mac compositor, session and brush engine | Native layer/canvas/mask/round-brush workspace in development; ABR/selections/retouching missing | Missing |
| Mesh modelling, face editing, sculpting and physics | Implemented | Native shared-engine workspace in development; touch sculpt/topology/physics checks | Missing | References only |
| Game authoring, node logic, play and source export | Implemented | Native shared-engine workspace in development; empty 2D/3D scenes, connected logic and play | Missing | Missing |
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
2. `PhotoRaster.swift` adapts only its native colour and PNG boundary for
   AppKit/UIKit. Brushes, erasing, masks, cloning, connected colour selection and
   ABR decoding remain single-source. `PhotoDocumentCore.swift`,
   `PhotoRenderEngine.swift` and `PhotoProjectCodec.swift` now extract the exact
   Mac layer state, full compositor/filters/transforms and v1/v2 saved schema.
   The existing Mac controller calls that same renderer. UIKit pixel checks run
   it directly; there is no separate simplified mobile layer model. Shared
   `PhotoEditingSession.swift` now supplies immutable commands, bounded history,
   stroke transactions, group motion and atomic text updates. UIKit has a native
   Photo workspace launched from Studio Home, with separate video/photo state,
   blank documents, layers, masks, adjustments, selections, painting/retouching,
   text/shapes, canvas navigation and native layered save plus image export.
   `PhotoBrushLibraryView` uses reusable cells, searchable tips and bounded
   thumbnails. Native UI and real displayed pixels are checked separately from
   core tests. Complete Mac command coverage and physical-device acceptance remain.
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
   - Shared engine boundary implemented as `PhotoEditingSession`; complete the
     remaining desktop command/UI coverage and physical-device acceptance.
     Selection lifting, selection masks/inversion, native brush-file import/export,
     keyboard tools/history, swatches, curve graph, folder navigation and thumbnails
     now have native implementations and dedicated checks. Multi-layer selection,
     font-browser polish and larger-document responsiveness still need work.
     The Mac controller already shares the renderer
     and document schema; its command adapter has not yet moved to the new session.
   - Keep immutable image snapshots and memory-aware history; one stroke is one
     Undo step, with transient mask previews committed only at stroke end.
   - Convert UIKit's top-down touch coordinates to positive-Y-up document space
     once, then use the existing inverse layer transform. Retain brush diameter
     scaling and explicit clone-source sampling.
   - iOS file permissions, unavailable fonts, thumbnails and ImageIO export are
     platform adapters. Linked-source v1 files need explicit relinking errors;
     embedded v2 pixels/masks/text metadata must not be dropped.
   - Android now has isolated `PhotoDocument`, `PhotoEditingSession` and
     `PhotoBitmapEngine` foundations preserving the v2 JSON and embedded pixels.
     Unsupported saved processing must be explicitly rejected by rendering,
     never silently dropped. A native authoring workspace now exposes blank
     canvases, layers/folders, masks, transforms, round brushes and primary
     adjustments with an independent draft and history. Native Files operations
     retain the shared layered schema. Phone/tablet authoring checks and full
     renderer/tool coverage are still required. Passing codec checks alone is
     not a Photo port; Android ABR, selections, retouching and several tools remain.
4. **Modelling and game workspaces:** shared geometry/command/runtime models on
   Apple, equivalent contract implementations on Android/Qt. Real mesh hit tests,
   sculpt/deform/topology changes, save/export, undo, node execution and playback.
   Keep physics/playback non-destructive; do not substitute pre-rendered demos.
   - Apple now has independent `ModelingWorkspaceViewController` and
     `GameWorkspaceViewController` source adapters, with retained documents and
     Home launch artwork on both phone and tablet. They directly compile the Mac
     geometry/sculpt/physics and game graph/runtime/export implementations.
     Native tests exercise actual side picking/sculpting, editable topology,
     runtime collisions/branches, rig deformation and saved desktop documents.
     The optional model-assistance runtime, detailed modeling gizmo/proportional
     editing, physics baking and full keyboard polish are still gaps. Android
     and Qt do not yet have these authoring workspaces.
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
