# Native workspace alignment — development work

This work aligns the native Video Editor with the Mac design. It is not a claim
that the whole Mac creative suite has already been ported. Published Beta 7
downloads remain unchanged until a new, tested release is explicitly published.

## Full-port work now in progress

The target is the full suite, not a permanent mobile "light" edition. The gap
audit, reuse architecture and acceptance gates are tracked in
[`design/FULL_PORT_PLAN.md`](design/FULL_PORT_PLAN.md). The saved packages in the
table below are the earlier static-effects previews; newer source adds real
effect animation and must pass its expanded platform checks before replacing
those local packages or being announced as a new public release.

Current Apple/Android source adds source-time keyframes for all eight existing
motion/colour controls, all five Mac interpolation modes, native seekable diamond
lanes and reversible Add/Update/Remove/previous/next edits. Curves survive
trim/split/move/duplicate and migrate old static projects to schema 3. Preview
and export evaluate frame timestamps, not a single inspector value.

Apple model/math, real composed/encoded animated pixels, and phone/tablet native
keyframe controls pass locally. The same Mac brush/ABR, grade/LUT/keyer, modelling
commands and game-logic implementations also execute in isolated UIKit checks.
That proves shared engines, not completed Photo/Game/3D mobile workspaces.
Full Mac product typechecking and its existing brush-pixel regressions pass after
the portability changes. New Android compilation/device checks are still required.

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

An earlier Android phone/tablet run passed nine instrumentation methods. Stronger
checks exposed a later effects-preview timeout that the first READY event alone
did not catch. While the current player is healthy and prepared, parameter-only
edits update live motion/colour matrices and redraw the native source-frame cache
without rebuilding the decoder. Continuous
slider updates retain a 50 ms deadline instead of waiting until a gesture stops.
Clip/source/trim/canvas changes still rebuild their composition; real engine errors
can be retried explicitly without restarting the requested seek or changing media.

The expanded suite passes all twelve instrumentation methods on both phone and
tablet in run 37772381515 at source 1a00ca8. It verifies actual combined-grade
pixels, opacity zero/undo, live-player identity, matrix agreement with export,
independent shared-source instances, archives, draft input/history and the
SDK-stop transition used by export. This is not a full Files-picker/export UI
acceptance test. A system Pixel Launcher ANR obstructed an earlier Google-image
check; CI now uses a clean API 35 AOSP image without suppressing app/system errors.
Final evidence contains only the intentionally injected recovery-test timeout,
with successful recovery afterward, not an unhandled preview failure.

The signed development APK is saved locally after both exact-source device jobs
pass. CI verifies APK v2/v3 signatures, the package identifier and the maintained
update certificate; its recorded package hash matches the local download.
Public beta assets remain unchanged. Physical-device acceptance remains separate.

## Verified development packages — 8 October 2026

These local `dist/` files are previews, not new public release assets. Apple and
Qt runtime sources are unchanged since their successful build commits (only the
Qt README changed); Android is built from the final checked commit below.

| Native edition | Saved package | Verified source | Successful CI run |
| --- | --- | --- | --- |
| iPhone / iPad | `NetVista-Studio-iOS-Workspace-Preview.ipa` | `04c7cf1` | [37715025084](https://github.com/user1994g/videoediterNetVistaStudio.github.io/actions/runs/37715025084) |
| Android phone / tablet | `NetVista-Studio-Android-Workspace-Preview.apk` | `1a00ca8` | [37772381515](https://github.com/user1994g/videoediterNetVistaStudio.github.io/actions/runs/37772381515) |
| Windows | `NetVista-Studio-Windows-Workspace-Preview.zip` | `74b3cc7` | [37759238246](https://github.com/user1994g/videoediterNetVistaStudio.github.io/actions/runs/37759238246) |
| Linux | `NetVista-Studio-Linux-Workspace-Preview.tar.gz` | `74b3cc7` | [37759238246](https://github.com/user1994g/videoediterNetVistaStudio.github.io/actions/runs/37759238246) |

- Apple: use AltStore Classic to re-sign the universal IPA. The ad-hoc signature
  alone is not an App Store/TestFlight or directly distributable Apple signature.
- Android: the APK has the existing package/update signing identity. Back up
  projects before trying development builds; no production account is bundled.
- Windows: extract the complete ZIP and keep the executable with its bundled
  runtime folder. Do not move only the executable.
- Linux: extract the complete TAR.GZ, retaining its executable permissions and
  runtime folder. Built on Ubuntu 24.04; older Linux compatibility is not certified.

SHA-256 of each saved file, in the same order as the table:

```text
4ad1af736db3607fec89bbe6e0fd59189d29e7a7f78c266512c6b6fa9ee640bc  NetVista-Studio-iOS-Workspace-Preview.ipa
2951ca1c907ee12bcf92d5b8b40a8b96092171ccc673f971e0458285e313ed09  NetVista-Studio-Android-Workspace-Preview.apk
8f1ffec6412eb98f60a125db71abf6a8dc1ef9e6bd851c95e1a9705ebcb2139e  NetVista-Studio-Windows-Workspace-Preview.zip
e68043a0997f24130bd8e29dc587433b1db76698f2055f672d1ee20352143682  NetVista-Studio-Linux-Workspace-Preview.tar.gz
```

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
