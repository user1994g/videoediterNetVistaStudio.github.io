# NetVista Studio 1.4 Beta 7

Release tag: `v1.4.0-beta.7` · Public prerelease · 7 October 2026

## macOS changes since Beta 6

- Separate 3D Editor workspace with editable mesh documents, primitive tools,
  subdivision, direct sculpting, dense procedural model generation and undo.
- Physics preview controls and optional local modeling assistance. The small
  CPU runtime ships with the app; model weights are not bundled or downloaded
  automatically. Download/removal require explicit user action.
- More consistent floating Effects/Colour workspaces, scopes, and live-preview
  controls; multiple video tools can remain open together.
- Improved Ultra Key edges/spill processing and optional local AI person matte.
- Expanded Game Maker editing workflows and runtime/export consistency fixes.
- Safer declarative mod authoring and a native creator workflow.
- Local-network collaboration with paired devices, independent Colour/3D
  leases, revision conflicts, preview updates and companion controls.

## Platform support

macOS: Apple Silicon, macOS 11+. This download is ad-hoc signed, **not Apple
notarized**. Gatekeeper may block a downloaded build. It does not bypass Apple's
security checks. A Developer ID/notarized release requires the account holder's
Apple certificate and repository signing configuration.

Windows/Linux: the existing PySide desktop editor is rebuilt as Beta 7. It is
not feature-equivalent to the native macOS editor: advanced Mac-only modeling,
photo/game workspaces and LAN collaboration are not mobile/desktop ports merely
because the release version is shared. Unzip the complete application folder.

iPadOS/Android (including Samsung): **first standalone native video editors**.
Import local videos, preview an assembled sequence, trim/reorder/delete clips,
save projects and export a movie without a Mac or local sharing server. Sign in
with the existing NetVista account. These first mobile betas do not include the
desktop photo editor, 3D/game tools, advanced colour grading, effects or mods.
They are separate native implementations, not repackaged desktop ZIPs or old
film-website wrappers. See [mobile installation and limits](MOBILE_RELEASE.md).

The iPad IPA must be re-signed by **AltStore Classic** using the user's account;
it is not an App Store/TestFlight build and has no embedded Apple distribution
profile. Android is a release-signed APK, not a Play Store listing. Hardware
encoder capabilities limit mobile export resolution and codec support.

The LAN browser companion is not a standalone mobile editor and requires the
Mac to remain open on the same network. It is not presented as an IPA/APK.

## Installation and updating

Existing compatible macOS installations discover this increasing beta tag via
the in-app Update button. The package retains the bundle identifier and updater
helper. App update recovery protections remain intact; back up important work.
AI models are optional separate downloads, not a prerequisite for launching.

## Verification

Release preparation includes a full macOS app build/signature check, disposable
installer tests, modeling/sculpt/generator/physics tests, local-AI lifecycle and
keyer pixel checks, mod authoring, game/runtime exports, LAN host/companion tests,
and the portable editor's tests. Windows/Linux are built from the exact release
tag in GitHub Actions. Mobile builds include project/model checks, platform
compilation, IPA inspection and APK signature verification. Automated tests do
not replace physical iPad/Samsung device testing, real-model inference, or
two-version GUI update/recovery testing. Mobile device testing is still needed.
