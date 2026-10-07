# Native workspace alignment — development work

This work aligns the native Video Editor with the Mac design. It is not a claim
that the whole Mac creative suite has already been ported. Published Beta 7
downloads remain unchanged until a new, tested release is explicitly published.

## Desktop work implemented locally

- Mac palette, logo/wordmark, coast Home artwork, persistent Studio Home access.
- Media Pool / aspect-fit monitor / inspector / ruler-and-track timeline layout.
- Native source drag/drop, continuous scrubbing, linked/unlinked edits, snapping,
  split, duplicate, delete, fit/zoom and bounded 50-step undo/redo.
- Position, rotation, scale, opacity, blur/sharpen and primary colour settings;
  changing one property preserves other settings loaded from a Mac project.
- Fast paused-frame processing instead of encoding a movie on every slider
  movement. Playback requests a layered proxy. Stale callbacks cannot replace
  newer edits; cancelled encoders are terminated/reaped before worker completion.
- All export settings before the save picker; progress in a separate window.
- Compact desktop layout verified at 960×640 and 1500×930; inspector numbers
  remain on-screen. Native widget tests and actual decoded export/frame pixels.

## Apple / Android development scope

The native mobile implementations are being updated to the same design contract
in [`design/NATIVE_WORKSPACE.md`](design/NATIVE_WORKSPACE.md), including compact
touch controls, Media Pool, monitor, an interactive drawn timeline, inspector,
Studio Home and actual saved motion/colour effects. Apple device-family support
is being expanded from iPad-only to universal iPhone/iPad.

Build and device-layout verification is required before treating those changes
as an installable update. Installation cannot be established from source review
alone, particularly for iOS signing and Android device encoders.

## Remaining parity boundaries

The Mac Photo Editor, Game Maker and modelling/sculpting workspaces are not yet
implemented in the mobile or Qt edition. Mac advanced grading nodes/curves/LUTs,
full effect/keyframe systems and unrestricted multi-track mobile compositing
are not covered by this UI alignment. Mobile project packages are not yet a
universal interchangeable desktop project format. Device export limits depend
on encoder and memory support; this work does not claim 16K on phones/tablets.

Unsupported tools must not be represented by decorative buttons that suggest
they work. Keep published release notes, feature descriptions and download
labels accurate while these ports develop.
