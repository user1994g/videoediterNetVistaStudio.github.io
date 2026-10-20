# Native mobile development previews — 20 October 2026

These are standalone native development builds, not website wrappers and not a
new public beta. They do not replace the published Beta 7 downloads. Full Mac
feature parity and physical-device acceptance are still open work.

## iPhone and iPad

Local package: `dist/NetVista-Studio-iOS-2026-10-20-Preview.ipa`.

- SHA-256: `245efb202e92aea39c49dd0fd7abc3b23b1c3a1622325b0c487780d966ff170f`.
- Exact stable-SDK CI artifact from `62dff49093b2a9607d180e89ed5fb2b0082418ac`.
  Production inputs are unchanged since `5fd34c2`; the later Apple changes
  strengthen QA/docs. The separately retained local beta-SDK build is not the
  recommended install file.
- arm64, actual **IOS** binary built with stable SDK 18.5, minimum iOS/iPadOS 16,
  device families 1 and 2.
  Ad-hoc signature/package integrity passes; AltStore must re-sign for installation.
- Original NetVista logo/icon is bundled. An independent archive/binary review
  found no QA classes, test flags or test bundle identifiers in the package.
- Independent native Video, Photos, Game Maker and 3D Editor workspaces retain
  their own documents. Photos, Game Maker and modeling reuse the Mac engines.
- Export resolution and frame rate are chosen together before rendering. Actual
  mesh-side sculpt picking and orbit camera orientation are corrected.

Complete integrated local simulator checks pass on both phone and tablet,
including sequential Home/workspace transitions, actual playback, animation
controls, Photos authoring, game runtime and mesh editing/physics. The new export
test presses the production Render button, checks an actual 1280×720 / 25fps MP4
(6 seconds, 42,018 bytes, visible decoded source pixels), then cancels the real
Files picker and checks owned temporary cleanup, unchanged project/history and
retained original media. The test does not substitute an export session or picker.

Evidence: `/private/tmp/netvista-all-real-export-20oct-qa/{phone,tablet}/`, with
`workspace-result.txt`, `movie-export-result.txt`, `photo-workspace-result.txt`,
`game-workspace-result.txt`, `model-workspace-result.txt` and real UI PNGs.
This local run uses the installed iOS 27 beta simulator. The complete stable-SDK
build, encoded-effect tests and phone/tablet UI run also pass at `62dff49` in
[run 39468824408](https://github.com/user1994g/videoediterNetVistaStudio.github.io/actions/runs/39468824408).
Both CI device artifacts also contain passing Video, Photos, Game Maker, modeling
and actual movie-delivery result files, with the same encoded movie measurements.
Installation, real-account sign-in, iOS 16 runtime behaviour and physical-device
codec/memory coverage remain separate gates.

## Android phones and tablets

Source `c25c70c` passed 44 instrumentation methods on both phone and tablet in
[run 39315946584](https://github.com/user1994g/videoediterNetVistaStudio.github.io/actions/runs/39315946584),
and produced a maintained-signature APK. This includes a new independent native
Photos workspace, Mac-reference compositing comparisons, all eight EXIF import
orientations, immutable Files captures and real video preview/export.

Follow-up source `62dff49093b2a9607d180e89ed5fb2b0082418ac` makes Brush settings
scroll in short landscape windows and adds actual-window/frame presentation and
last-control reachability checks. Its
[device and signing run](https://github.com/user1994g/videoediterNetVistaStudio.github.io/actions/runs/39468824566)
passes all 44 instrumentation methods on each profile, as well as compilation,
unit tests, lint and maintained-identity APK signing. Actual Photo portrait and
landscape canvas PNGs and the scrolled brush colour control were visually reviewed.

Local package: `dist/NetVista-Studio-Android-2026-10-20-Preview.apk`.

- SHA-256: `12f6ae5135384f8c343b5029fdfbd9942929efee8ffd0b8306931afdf2c74ad6`.
- CI verifies APK v2/v3 signing and maintained certificate SHA-256
  `0adde9db67d2b529563a79c7b08d7ccdde2b873d3131e2467ce789d7fad29413`.
- The package is the exact signed artifact from the passing `62dff49` run, not
  the older static-effects or pre-Photos APK with a new filename.

Some immediate panel screenshots still captured the preceding window/tab despite
the live control assertions passing. A separate QA-only follow-up, `d552fa9`,
waits for the actual focused dialog's committed frame plus display boundaries
before taking every screenshot. It does not change the packaged production code
or relax the pixel/control assertions; its renewed
[visual-evidence run](https://github.com/user1994g/videoediterNetVistaStudio.github.io/actions/runs/39470476971)
is separate.

## Remaining parity work

Apple video still lacks full multitrack/audio placement, ordered advanced effect
stacks, node grading and 8K/16K delivery. Photos/Game/3D need remaining desktop
commands and interaction polish. Android Game Maker/3D authoring and several
advanced Photo tools are not yet ported. These previews do not establish that
every Mac capability is present on every mobile device.

See [the full-port plan](../design/FULL_PORT_PLAN.md) and the native
[Apple](ipad/README.md) / [Android](android/README.md) capability lists.
