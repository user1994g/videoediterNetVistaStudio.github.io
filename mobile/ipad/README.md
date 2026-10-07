# NetVista Studio for iPad — first standalone mobile beta

Native UIKit + AVFoundation editor. Runs on the iPad itself; it does not connect to a Mac or embed the website.

## Included

- Same NetVista account sign-in as the website, fresh user verification and 25-minute account checks. Only public Supabase client configuration is included. Session tokens use the iOS Keychain; passwords are never saved.
- Import multiple videos from Files. Imported media is copied into the app's documents so edits do not depend on an external connection.
- Full-sequence preview with a real-time playhead. Landscape/portrait source clips fit the frame without cropping.
- Drag clip handles to reorder; duplicate, remove, trim by sliders or exact source seconds; 50-step undo/redo.
- Automatic local working-project recovery. Save/Open `.netvistamobile` project packages in Files containing `project.json` and the media. This format is mobile-specific, **not** the desktop `.netvistastudio` format and is **not** interchangeable with the Android JSON project.
- MP4 exports at 720p, 1080p or 4K, 16:9, 30fps, with a cancellable progress dialog and Files destination picker.
- Original NetVista logo and adaptive dark iPad workspace. Narrow split-screen opens trim settings as a dialog.

## Not included in this first mobile edition

Desktop photo/3D/game tools, node grading, effect/keyframe stacks, arbitrary audio layers, 16K export, background export and Mac collaboration are not ported yet. Supported codecs depend on the iPad's AVFoundation decoder/encoder. 4K exports can use substantial memory and storage. Keep the app in the foreground during export.

## Installation with AltStore

Requires **iPadOS 16 or later** on an arm64 iPad. Download `NetVista-Studio-iPadOS-1.4-Beta-7.ipa`, then import it using AltStore Classic's My Apps `+` button. AltStore supplies your own signing/provisioning. This IPA is an ad-hoc package for **re-signing**, not an Apple App Store/TestFlight build. AltStore PAL does not accept arbitrary IPAs. See the [official AltStore Classic guide](https://faq.altstore.io/altstore-classic/your-altstore).

Install updates over the same app identity through the same AltStore Apple account to preserve local documents. Save portable project packages before any uninstall. Free Apple accounts have AltStore refresh/device/app limits; follow AltStore's instructions. No Apple ID is sent to NetVista.

## Reproducible build and checks

On a Mac with Xcode and the iOS SDK:

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer bash mobile/ipad/build_ipa.sh /private/tmp/netvista-ipad-output
swiftc mobile/ipad/Sources/MobileProject.swift mobile/ipad/Tests/ProjectChecks.swift -o /private/tmp/netvista-ipad-project-checks
/private/tmp/netvista-ipad-project-checks
```

The script uses no paid development certificate, does not change `xcode-select`, embeds no provisioning profile or private key, and checks the Mach-O build platform is **IOS**, not macOS. `Info.plist` and source are committed; app icons are resized from the repository's original logo. The shared `StudioAccount.swift` is compiled directly rather than maintaining a duplicate account backend.

Physical iPad installation, codec coverage, touch interaction and real-account sign-in still need device beta testing. Local synthetic media checks exercise composition/export without sending account emails or uploading media.
