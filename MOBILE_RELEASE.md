# Standalone mobile video editors — first beta

Beta 7 introduces **separate native video editors**, not mobile versions of
every desktop workspace. They work on local clips without running a Mac.
The first scope is import, sequence preview, trim/reorder/delete, native project
save/load and movie export. Advanced colour/effects, multi-track compositing,
photo editing, 3D, Game Maker and mods are not included on mobile yet.

## iPad installation

Download `NetVista-Studio-iPadOS-1.4-Beta-7.ipa` from the release. Use **AltStore
Classic**, not AltStore PAL, to import and re-sign the IPA with your own account.
Keep AltServer/refreshing configured as described in the
[official AltStore guide](https://faq.altstore.io/altstore-classic/your-altstore).
Free-account sideloaded apps normally need refreshing every seven days.
The IPA is not Apple-notarized or a TestFlight/App Store distribution. Never
share an Apple ID password or a signing certificate with this repository.

The native source and build/test instructions are in [`mobile/ipad`](mobile/ipad).
The build uses Apple's iPhoneOS SDK and an arm64 iOS binary inside `Payload/`;
the Mac editor executable cannot be used in an IPA. AltStore supplies the
installation signature/profile. No paid Apple team is embedded in the package.

## Android / Samsung installation

Download `NetVista-Studio-Android-1.4-Beta-7.apk`. Android 8.0+ is required.
Open it using your device's normal package installer and review its permissions.
The application uses the system picker rather than unrestricted media-library
access. Device codec/encoder availability varies. This is not a Play Store app.

Source and build instructions are in [`mobile/android`](mobile/android).
CI pins the Android toolchain and Media3 version, runs unit checks/lint, builds
the release APK, aligns it and verifies its release signature before uploading.
The release certificate SHA-256 fingerprint is:

`0A:DD:E9:DB:67:D2:B5:29:56:3A:79:C7:B0:8D:7C:CD:DE:2B:87:3D:31:31:E2:46:7C:E7:89:D7:FA:D2:94:13`

Future APK updates must retain this key, package identifier and a higher version
code. The private key is never part of source or release downloads. A protected
local backup is under the ignored `.release-private/android/` directory; CI
holds encrypted `ANDROID_SIGNING_KEY_BASE64` and `ANDROID_SIGNING_CERT_BASE64`
repository secrets. Do not remove the backup or disclose it. These secrets grant
signing access only, not account/database access.

## Accounts, projects and limitations

Both editions use the existing Supabase service and only its public client key.
Passwords are not saved in project documents. Saved sessions use iOS Keychain or
Android Keystore-backed encrypted storage; account checks use the server, not
just local JWT parsing. Background timing depends on the operating system.
Network failures must not be mistaken for account deletion.

The iPad and Android project packages, and desktop `.netvistastudio` projects,
are currently different formats. Do not assume they are interchangeable,
even where the mobile filename extension matches. Large-media saves/exports
need free local storage; retain original files and project backups. Neither
edition promises 8K/16K export on a tablet or phone. Physical-device import,
export, installation and account tests remain important before production use.
