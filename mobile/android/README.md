# NetVista Studio — native Android mobile workspace

This is a standalone native Android editor, **not** the film website wrapper,
the Mac LAN companion, or the full desktop editor. Package identifier:
`com.netvistastudio.editor.android`. Android 8.0/API 26 or newer is required.

## Working scope

- Sign in with the existing NetVista account service. A fresh `/auth/v1/user`
  response validates sign-in. Encrypted saved sessions use Android Keystore
  AES-256-GCM; passwords are never saved. The client contains only the existing
  publishable API key, not a service-role key.
- Import one or several local videos through Android's native document picker.
  Each selected video is copied into app-private storage; editing does not depend
  on a persistent external file-picker permission.
- Native Studio Home uses the original shared coast artwork. The Video workspace
  uses the Mac-family palette/brand, compact toolbar, Media Pool, Program Monitor,
  Inspector and graphical timeline. Wide tablets keep three panels; phones and
  smaller windows use compact panel navigation/native dialogs, not a shrunk desktop.
- Native Media3 `CompositionPlayer` monitor and Transformer export use the same
  full composition, including clip order, trim bounds, fit, motion and colour.
- Media Pool sources are separate from timeline instances. Add one/all, trim with
  millisecond precision, mark source In/Out at the sequence playhead, split,
  duplicate, delete, reorder, and undo/redo. These operations share private source
  bytes rather than duplicating large videos.
- Native canvas timeline has a seconds ruler, red playhead, linked blue video /
  green source-audio lanes, selection, ruler scrubbing, horizontal pan, pinch/button
  zoom, fit and hold/drag reorder. All actions edit or navigate the real sequence.
- Per-clip Motion/Effects controls: fitted scale, rotation, half-canvas X/Y offsets
  (+Y up) and opacity. Primary Colour: brightness, contrast and saturation. Sliders
  and numeric entry update actual monitor/export effects; values survive portable
  save/load, split, duplicate and undo/redo. Numeric values commit on Done or blur.
  Contrast is a true 0–400% factor control with 100% neutral, matching the other
  editions. Older Android projects keep their existing rendered appearance;
  out-of-display-range legacy values are retained until contrast is edited.
  While the current player is healthy and prepared, parameter-only edits redraw
  the native cached source frame using live matrices, including while a slider
  gesture continues, without rebuilding its decoder.
  Clip order, source, trim or canvas changes still prepare a new composition.
- Saved source-time animation for all eight motion/colour properties. The native
  Animation inspector provides editable values, seekable diamonds, Add/Update,
  Remove/Clear, previous/next and the same five Mac interpolation choices (Hold,
  Linear, Ease In, Ease Out, Ease In/Out). Preview/export evaluate frame timestamps
  through one processing adapter, and trim/split/duplicate/history retain curves.
- Private atomic draft autosave. Save/Open `.netvistamobile` files through Files.
  These are ZIP archives containing `project.json` and each original source once,
  including unused Media Pool sources. Schema 3 preserves animation as well as
  per-instance effects; old schema 1/2 projects retain their static appearance
  with no added animation. Saved projects are
  self-contained and may move between Android devices.
- Real Media3 Transformer concatenation export: MP4, H.264 video/AAC audio,
  30 fps, 1920×1080 / 1280×720 / 1080×1920. Each clip is fitted with letterboxing
  to the selected canvas. Explicit audio/video sequence tracks generate silence
  where source audio is absent. HDR is tone-mapped to SDR when supported.
- Export progresses in a private staging file. Completion asks for a new Files
  destination. Cancellation/failure does not replace any source or old movie.
- Native About & licenses dialog contains dependency license notices.

## Honest limits

This is a sequential/ripple native mobile video editor, not full Mac feature
parity: no layered/independent multitrack placement, independent audio import/mixing,
transitions, titles, full ordered effect stacks/all Mac animated properties,
LUTs/advanced grading, photo editor, 3D/Game Maker,
mods, AI tools, or desktop/iPad project compatibility. The A1 lane represents linked
source audio; it is not a separate editable track or a decoded waveform. Opacity
flattens the single picture over the black canvas rather than revealing another
video layer. There is no cloud upload of videos/projects. An account is required,
but previously verified work remains
available during temporary network failures; an explicitly revoked account/session
locks editing without deleting its project.

The target is a full native port, not a permanently reduced mobile product. The
missing capabilities are tracked in [the full-port plan](../../design/FULL_PORT_PLAN.md).
The newly added keyframe source requires expanded Android compilation/device
checks before replacing the earlier verified static-effects development APK.

Android's periodic background jobs are **best effort**, not exact clocks. While
foregrounded the app checks every 25 minutes (or shortly before token expiry),
and on every foreground return. Network failures retry after a minute without
erasing tokens. A native persisted 25-minute background job also checks when the
OS permits. Refresh and validation are serialized to prevent refresh-token races.

Exports must stay foreground; leaving the app cancels an active render. Device
codec capabilities can prevent particular formats or resolutions from exporting.
Long/high-resolution sources need ample free storage and processing time. The beta
limits one source to 4 GiB, a saved project to 12 GiB, and a timeline/source pool
to 500 clips/500 sources.
Project saving embeds full original sources (not only trimmed sections). Imported
copies stay in private storage when clips are removed or a new edit starts; save
portable backups before uninstalling or clearing app data, which removes those copies.

## Reproducible build

Pinned dependencies are declared in Gradle; no native compiler/NDK is required:

- JDK 17
- Gradle 8.13
- Android Gradle Plugin 8.13.2
- Android compile/target SDK 36 (SDK platform `platforms;android-36`)
- Android SDK Build Tools 35.0.0 (AGP default)
- AndroidX Media3 1.11.1 (CompositionPlayer, ExoPlayer engine, UI, Transformer, effects)
- Version name 1.4.0, version code 10, native Beta 7 label
- `app/src/main/assets/release-tag.txt`: `v1.4.0-beta.7`

Use a trusted Gradle 8.13 installation (or `gradle/actions/setup-gradle` in CI)
and an Android SDK. This source intentionally does not pretend to contain a
Gradle wrapper JAR when one has not been generated/verified.

```sh
gradle --no-daemon -p mobile/android :app:testDebugUnitTest :app:lintDebug :app:assembleRelease
```

Unsigned output: `mobile/android/app/build/outputs/apk/release/app-release-unsigned.apk`.
It **cannot install unsigned**. The repository release workflow aligns and signs
it using the maintained Android release key/certificate and checks the APK identity
and release-tag asset. Signing credentials never belong in source or ordinary logs.
For a local test APK, use `:app:assembleDebug`; Android build tools sign that APK
with a debug certificate, which is not the release/update identity.

```sh
gradle --no-daemon -p mobile/android :app:connectedDebugAndroidTest
```

Run instrumentation on an Android emulator or physical device. Unit tests cover
trim bounds, durations, shared sources/split/duplicate, properties/transform math,
snapshot isolation, local path safety and auth failure/retry policy. Instrumented
tests cover archive portability/path rejection (including unused pool and shared
sources), actual mixed-aspect/audio export and decoded pixels for motion/colour/
opacity. The native UI harness uses an in-memory local account snapshot, not
credentials, a test server account or a production bypass. It exercises actual
controls on phone/tablet layouts and writes screenshots to the test app's external
files directory under `ui-screenshots`. Authentication acceptance testing requires
a user-owned account; no test account is created by this project or its CI.

## Device acceptance checks

1. Sign in, background/resume, and confirm a valid saved session refreshes without
   asking for a password. Disconnect network: work must remain available after a
   previously successful user validation. Explicit revocation must show login
   while preserving the draft.
2. Import one landscape clip with audio and one portrait/silent clip. Remove or
   relocate the external originals: private imported media must continue to work.
3. Add sources to the timeline, trim both, reorder/split/duplicate, undo/redo, scrub
   the ruler across the clip boundary, pan/zoom/fit, then preview and export. Confirm order,
   output duration (within encoding rounding), 30 fps/canvas, preserved sound and
   silence for the silent section, using a media inspector and actual playback.
4. Adjust scale/rotation/X/Y/opacity and brightness/contrast/saturation on one
   instance; another instance of the source must remain independent. Verify pixels
   in monitor and exported movie, including opacity zero showing black. Save a project,
   transfer it to another Android device with no original picker
   permissions, open it and export again. Desktop and iPad files must be rejected
   with a clear format error rather than silently misread.
5. Cancel an export; background during export; cancel the save picker; retry a
   completed render. No source or previous exported file may be removed/replaced.
6. Open malformed/traversal ZIPs, missing-media manifests and out-of-range trims:
   reject safely without replacing the current edit or writing outside app storage.
7. Check tablet landscape, portrait/split width and phone portrait/landscape.
   Monitor and timeline must remain usable; compact panel dialogs must not stack
   when changing Inspector tabs. Also check Android accessibility font scaling.

## Implementation references checked for this beta

- [Media3 releases](https://developer.android.com/jetpack/androidx/releases/media3)
- [Transformer compositions](https://developer.android.com/media/media3/transformer/composition)
- [Transformer trimming](https://developer.android.com/media/media3/transformer/transformations)
- [AGP 8.13 compatibility](https://developer.android.com/build/releases/agp-8-13-0-release-notes)
- [Android Keystore](https://developer.android.com/privacy-and-security/keystore)
- [Supabase user validation](https://supabase.com/docs/reference/javascript/auth-getuser)
- [Supabase sessions/refresh rotation](https://supabase.com/docs/guides/auth/sessions)

The local development Mac has no Android SDK/JDK. The new native workspace passes
remote compilation/unit/lint checks and all twelve device methods on both phone
and tablet in [run 37772381515](https://github.com/user1994g/videoediterNetVistaStudio.github.io/actions/runs/37772381515)
at source `1a00ca8`. An earlier nine-method suite missed a late effects-preview
failure; stricter actual monitor/export pixel checks found and corrected it.
The final suite also verifies live matrices, archives, instance isolation,
uncommitted input/history, stopped-player recovery and actual system touch routing.
The stopped-player test exercises the SDK transition used by export, not a full
Files-picker/export UI flow. CI uses clean API 35 AOSP devices; it does not suppress
application errors or substitute painted mock previews for native playback.

The signed development package is saved locally at
`dist/NetVista-Studio-Android-Workspace-Preview.apk`. Signing runs only after both
exact-source device jobs pass, and verifies the existing update certificate and
APK v2/v3 signatures. Its SHA-256 is
`2951ca1c907ee12bcf92d5b8b40a8b96092171ccc673f971e0458285e313ed09`.
This does not replace the public Beta 7 APK. Real account login, Samsung hardware
and physical codec/touch coverage require separate user-owned acceptance testing.
Source tests alone are not an APK, and simulator timings are not a physical-device
responsiveness benchmark. See `NATIVE_WORKSPACE_STATUS.md` for package provenance
and remaining feature-parity boundaries.
