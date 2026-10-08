# NetVista Studio for iPhone and iPad — native workspace development preview

Native UIKit + AVFoundation editor. Runs on the device itself; it does not connect to a Mac or embed the website. This source now targets both iPhone and iPad; the previously published Beta 7 IPA remains the older iPad-only edition until a new release is published.

## Included

- Same NetVista account sign-in as the website, fresh user verification and 25-minute account checks. Only public Supabase client configuration is included. Session tokens use the iOS Keychain; passwords are never saved.
- Import multiple videos from Files. Imported media is copied into the app's documents so edits do not depend on an external connection.
- Full-sequence preview with a real-time playhead. Landscape/portrait source clips fit the frame without cropping.
- If the OS rejects live custom-compositor playback, automatically render a local 720p compatibility preview using the same effects engine. This recovery takes time to render; edits cancel stale renders and refresh after the gesture. It is not cloud processing or instant live grading on affected OS versions.
- Compact Mac-style Media Pool, Program Monitor, inspector and drawn video/linked-audio timeline. Narrow windows use collapsible panels; landscape phones use a side-by-side monitor/timeline.
- Pinch/zoom/fit, scrub the ruler, hold-and-drag to reorder or edge-trim, Select/Blade tools, split, duplicate, delete and 50-step undo/redo.
- Saved per-clip scale, position, rotation, opacity, brightness, contrast and saturation. Native sliders and exact numeric entry use the same Core Image processing in preview and export. Position uses half-canvas units, positive Y up and positive rotation counterclockwise.
- Source-time keyframes for all eight motion/colour properties, evaluated per frame in preview/export. Native diamond lanes, zoom/pan/seek, Add/Update/Remove, previous/next, Auto Key, and all five Mac interpolation modes (Hold, Linear, Ease In, Ease Out, Ease In/Out). Trim/split/move/duplicate retain animation; history and schema-3 saves retain all curves. Static schema-1/2 projects still load without adding animation.
- Studio Home remains accessible and uses the original Mac coast artwork and logo.
- Automatic local working-project recovery. Save/Open `.netvistamobile` project packages in Files containing `project.json`, effects, the source pool and deduplicated media. Deleting a timeline instance retains its source. Older version-1 projects migrate with neutral effects. This format is mobile-specific, **not** the desktop `.netvistastudio` format and is **not** interchangeable with Android projects.
- MP4 exports at 720p, 1080p or 4K, 16:9, 30fps, with a cancellable progress dialog and Files destination picker.
- Original NetVista logo and adaptive dark phone/tablet workspace with portrait, landscape and split-window layouts.

## Remaining full-port work

This is development toward the full app, not a permanent light-edition target. Desktop photo/3D/game workspaces, node grading, full ordered effect stacks/all Mac animated properties, arbitrary audio layers, 16K export, background export and Mac collaboration are not ported yet. Supported codecs depend on the device's AVFoundation decoder/encoder. 4K exports can use substantial memory and storage. Keep the app in the foreground during export. See [the full-port plan](../../design/FULL_PORT_PLAN.md).

The original Mac brush/ABR, grading/LUT/keyer, modelling and game engines are now compiled and exercised directly in isolated UIKit checks, without source copies. Those checks demonstrate reusable processing/document commands, **not** finished Photo/Game/3D interfaces. The Mac brush path retains its original colour and PNG adapters.

## Installation with AltStore

The new local preview requires **iOS/iPadOS 16 or later** on an arm64 iPhone/iPad. Build `NetVista-Studio-iOS-Workspace-Preview.ipa`, then import it using AltStore Classic's My Apps `+` button. AltStore supplies your own signing/provisioning. This IPA is an ad-hoc package for **re-signing**, not an Apple App Store/TestFlight build. AltStore PAL does not accept arbitrary IPAs. See the [official AltStore Classic guide](https://faq.altstore.io/altstore-classic/your-altstore). Do not mistake the older published iPad Beta 7 download for this universal development preview.

Install updates over the same app identity through the same AltStore Apple account to preserve local documents. Save portable project packages before any uninstall. Free Apple accounts have AltStore refresh/device/app limits; follow AltStore's instructions. No Apple ID is sent to NetVista.

## Reproducible build and checks

On a Mac with Xcode and the iOS SDK:

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer bash mobile/ipad/build_ipa.sh /private/tmp/netvista-ipad-output
swiftc mobile/ipad/Sources/MobileProject.swift mobile/ipad/Tests/ProjectChecks.swift -o /private/tmp/netvista-ipad-project-checks
/private/tmp/netvista-ipad-project-checks
swiftc mobile/ipad/Sources/MobileProject.swift mobile/ipad/Tests/AnimationChecks.swift -o /private/tmp/netvista-ipad-animation-checks
/private/tmp/netvista-ipad-animation-checks
bash mobile/ipad/Tests/check_effects.sh
bash mobile/ipad/check_core.sh
# Separate simulator-only UI checker; cannot be included in an IPA.
bash mobile/ipad/check_ui.sh /private/tmp/netvista-ios-ui-checks
# Build and run both disposable simulators, collect screenshots/results, clean up.
# This also runs the real shared Mac engines in a separate UIKit test bundle.
bash mobile/ipad/run_ui_checks.sh /private/tmp/netvista-ios-ui-run
```

The script uses no paid development certificate, does not change `xcode-select`, embeds no provisioning profile or private key, and checks the Mach-O build platform is **IOS**, not macOS. `Info.plist` and source are committed; app icons are resized from the repository's original logo. The shared `StudioAccount.swift` is compiled directly rather than maintaining a duplicate account backend.

Physical iPhone/iPad installation, codec coverage, touch interaction and real-account sign-in still need device beta testing. Local synthetic media checks exercise composed preview and encoded pixels without sending account emails or uploading media. The UI checker uses a separate simulator bundle and test-only subclass; production builds compile only `Sources/*.swift` and contain no test login bypass.
