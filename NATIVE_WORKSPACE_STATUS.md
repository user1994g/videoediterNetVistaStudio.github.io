# Native workspace alignment — development work

This work aligns the native Video Editor with the Mac design. It is not a claim
that the whole Mac creative suite has already been ported. Published Beta 7
downloads remain unchanged until a new, tested release is explicitly published.

## Desktop work implemented and checked

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
- 44 tests pass locally and on Windows/Linux CI. Windows headless runners with
  an empty font database load installed system fonts instead of unreadable boxes.
- Frozen Windows/Linux portable app builds pass native launch checks and actual
  bundled-FFmpeg H.264 encoding/decoded-pixel checks. Complete Windows ZIP and
  Linux TAR.GZ previews preserve all runtime files and Linux executable bits.

## Apple / Android native Video workspaces

The native mobile implementations now use the same design contract
in [`design/NATIVE_WORKSPACE.md`](design/NATIVE_WORKSPACE.md), including compact
touch controls, Media Pool, monitor, an interactive drawn timeline, inspector,
Studio Home and actual saved motion/colour effects. Apple device-family support
is universal iPhone/iPad (iOS 16+, arm64). This is development source, not an
announcement that the older public Beta 7 packages have changed.

Apple checks verify actual AVPlayer decoded frames, the second clip, opacity
0/50 and undo refreshing playback, 15 layout/page combinations, controls,
history, shared media pool and draft persistence on isolated phone/tablet
simulators. Separate engine checks verify actual encoded 720p MP4 pixels,
transforms, primary grading, silent export and audio across clip boundaries.
The universal device IPA compiles, passes signature/package inspection and
contains the correct IOS platform, both device families and original icons.
AltStore must re-sign it; physical installation is not yet established.
The same source also passes CI compilation with the stable iOS 18.5 SDK and
real playback on the runner's phone/tablet simulators, without the compatibility
fallback required on the locally installed iOS 27 beta simulator.

On an OS that rejects custom-compositor playback, Apple now falls back after a
real player error to a locally rendered 720p edited preview. This path is tested
on the installed iOS 27 simulator. It preserves effects and seek intent, cancels
stale work and never silently substitutes the unedited source. It requires
rendering after edits and is not equivalent to instant live grading.

Android phone and tablet CI pass nine instrumentation methods, including actual
edited export pixels, archives, empty-monitor pixels, and uncommitted numeric
input across duplicate/undo/redo. Source coalesces graph updates, preserves
paused seek intent and fixes the forward-drag insertion marker. Review of the
final tablet screenshots exposed a later effects-preview timeout beyond the
earlier ready check. Stronger final-grade checks, serialized preparations and
real error recovery are in progress; the APK is not claimed final until those
checks pass. Preview signing requires successful checks of the exact source and
uses the maintained update certificate, without replacing public beta assets.

## Remaining parity boundaries

The Mac Photo Editor, Game Maker and modelling/sculpting workspaces are not yet
implemented in the mobile or Qt edition. Mac advanced grading nodes/curves/LUTs,
full effect/keyframe systems and unrestricted multi-track mobile compositing
are not covered by this UI alignment. Mobile project packages are not yet a
universal interchangeable desktop project format. Device export limits depend
on encoder and memory support; this work does not claim 16K on phones/tablets.
Apple Core Image uses linear-light compositing; Qt/Android currently use encoded
SDR channels, so matching control values are not yet pixel-identical across all
platforms. Physical Samsung/iPhone/iPad codec, touch and real-account coverage
still requires device beta testing.

Unsupported tools must not be represented by decorative buttons that suggest
they work. Keep published release notes, feature descriptions and download
labels accurate while these ports develop.
