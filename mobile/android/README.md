# NetVista Studio — native Android first mobile beta

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
- Native ExoPlayer sequence preview with the same ordered clipped `MediaItem`s
  as export, playback controls and selectable timeline clip list.
- Set In/Out in seconds (millisecond precision), mark the current preview position,
  reorder clips, and remove clips from the edit without deleting original files.
- Private atomic draft autosave. Save/Open `.netvistamobile` files through Files.
  These are ZIP archives containing `project.json` and every referenced original
  video, so a saved project is self-contained and may move between Android devices.
- Real Media3 Transformer concatenation export: MP4, H.264 video/AAC audio,
  30 fps, 1920×1080 / 1280×720 / 1080×1920. Each clip is fitted with letterboxing
  to the selected canvas. Explicit audio/video sequence tracks generate silence
  where source audio is absent. HDR is tone-mapped to SDR when supported.
- Export progresses in a private staging file. Completion asks for a new Files
  destination. Cancellation/failure does not replace any source or old movie.
- Native About & licenses dialog contains dependency license notices.

## Honest limits

This is a cuts-only first mobile beta: no layered timeline, transitions, independent
audio import/mixing, titles, grade/effect controls, photo editor, 3D/Game Maker,
mods, AI tools, or desktop/iPad project compatibility. The timeline is a native
clip list, not a zoomable graphical multitrack editor. There is no cloud upload of
videos/projects. An account is required, but previously verified work remains
available during temporary network failures; an explicitly revoked account/session
locks editing without deleting its project.

Android's periodic background jobs are **best effort**, not exact clocks. While
foregrounded the app checks every 25 minutes (or shortly before token expiry),
and on every foreground return. Network failures retry after a minute without
erasing tokens. A native persisted 25-minute background job also checks when the
OS permits. Refresh and validation are serialized to prevent refresh-token races.

Exports must stay foreground; leaving the app cancels an active render. Device
codec capabilities can prevent particular formats or resolutions from exporting.
Long/high-resolution sources need ample free storage and processing time. The beta
limits one source to 4 GiB, a saved project to 12 GiB, and a cut list to 500 clips.
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
- AndroidX Media3 1.11.1 (ExoPlayer, UI, Transformer, effects)
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
trim bounds, durations, reordering/snapshot isolation, local path safety and auth
failure/retry policy. Instrumented tests cover archive portability/path rejection
and the actual Media3 export pipeline. Authentication acceptance testing requires
a user-owned account; no test account is created by this project or its CI.

## Device acceptance checks

1. Sign in, background/resume, and confirm a valid saved session refreshes without
   asking for a password. Disconnect network: work must remain available after a
   previously successful user validation. Explicit revocation must show login
   while preserving the draft.
2. Import one landscape clip with audio and one portrait/silent clip. Remove or
   relocate the external originals: private imported media must continue to work.
3. Trim both, reorder them, preview from the first item, and export. Confirm order,
   output duration (within encoding rounding), 30 fps/canvas, preserved sound and
   silence for the silent section, using a media inspector and actual playback.
4. Save a project, transfer it to another Android device with no original picker
   permissions, open it and export again. Desktop and iPad files must be rejected
   with a clear format error rather than silently misread.
5. Cancel an export; background during export; cancel the save picker; retry a
   completed render. No source or previous exported file may be removed/replaced.
6. Open malformed/traversal ZIPs, missing-media manifests and out-of-range trims:
   reject safely without replacing the current edit or writing outside app storage.

## Implementation references checked for this beta

- [Media3 releases](https://developer.android.com/jetpack/androidx/releases/media3)
- [Transformer compositions](https://developer.android.com/media/media3/transformer/composition)
- [Transformer trimming](https://developer.android.com/media/media3/transformer/transformations)
- [AGP 8.13 compatibility](https://developer.android.com/build/releases/agp-8-13-0-release-notes)
- [Android Keystore](https://developer.android.com/privacy-and-security/keystore)
- [Supabase user validation](https://supabase.com/docs/reference/javascript/auth-getuser)
- [Supabase sessions/refresh rotation](https://supabase.com/docs/guides/auth/sessions)

The local development Mac has no Android SDK/JDK. Compilation, APK installation,
device UI, video export and real account login are **not locally verified** until
the CI/device runs report success. Source tests are not a substitute for an APK build.
