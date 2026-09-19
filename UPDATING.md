# NetVista Studio in-place updates (macOS)

Studio Home's Update button, the Video Editor button, and the app menu share
AppUpdateCoordinator. It checks GitHub Releases once at startup and every six
hours. Startup failures and up-to-date results are quiet. A newer compatible
release offers Update / Not right now. Dismissal lasts for that release for the
current session; a manual check can offer it again.

## Install lifecycle

1. Download the GitHub release to a private Caches/NetVistaStudio/Updates job.
   The progress window permits cancelling during download.
2. Check the advertised byte count and SHA-256 digest, safe archive paths,
   bundle ID, exact release tag, minimum macOS, architecture and code signature.
   Developer ID installations require the same Team ID in subsequent updates.
   Existing ad-hoc betas rely on the official GitHub HTTPS feed and digest plus
   package signature integrity; ad-hoc signatures do not authenticate a developer.
3. Stage the candidate in a private folder beside the app (same volume).
4. Capture video, live Effects/Colour, editable 3D scene data and layered photo
   documents into Update Recovery using existing project serialization. Failure
   to save or an active export/render prevents the restart.
5. Run the bundled signed helper from the private job. It takes an exclusive
   installation lock and waits for the parent process to exit, without force-killing it.
6. Rename the old app into the private backup and the candidate into the exact
   old path. Restore the old app if the second rename fails.
7. Open the new app at that path and pass the session recovery manifest. Its
   startup acknowledgement permits deleting the previous app and staging data.
   If launch fails, the helper restores and reopens the previous application.
   If the new process refuses to quit, keep the backup and explain its location.

Recovery files live in Application Support/NetVista Studio/Update Recovery.
They are retained to protect unsaved work. Saved photo projects keep their
original save destination; recovery does not overwrite it. Undo history, open
floating panels, temporary selections and playback position are not preserved.
The existing Share session must be started again after restart.

## Release contract

- Keep CFBundleIdentifier = local.netvista.studio.
- Set NetVistaReleaseTag to the exact, increasing GitHub tag.
- Keep NetVistaInPlaceUpdaterVersion = 1 or higher in compatible builds.
- The ZIP must contain NetVista Studio.app, created with ditto --keepParent.
  Regular ZIP with UTF-8 names is supported; ZIP64, encryption, symlinks and
  path traversal are rejected before extraction.
- Name the macOS asset with -macOS- and .zip. Intel-only assets are not offered
  to Apple Silicon. Publish a SHA-256 digest through GitHub's asset metadata.
- Build with build_app.sh; it compiles/signs Contents/Helpers/NetVistaUpdateHelper
  before signing the outer bundle. Notarize the final complete app for distribution.
- Older downloaded apps cannot gain this behavior until this build is installed.
  After that, compatible newer releases use the in-place flow.

Protected/read-only locations and App Translocation are not writable update
targets. The updater does not elevate permissions, disable Gatekeeper or remove
quarantine attributes. Windows/Linux have not been ported to this helper.

## Verification

Run the file-only installer harness; it uses disposable signed fixture apps and
archives under /private/tmp, never the installed app:

```sh
xcrun swiftc -D UPDATER_CHECKS -module-cache-path /private/tmp/netvista-update-swift-cache AppUpdateService.swift UpdateInstaller.swift Tests/AppUpdateChecks.swift -o /private/tmp/netvista-update-checks
/private/tmp/netvista-update-checks
```

Before publishing, also do a two-version GUI update on a separate test Mac with
unsaved video/photo projects, cancellation, restart and receipt confirmation.
Installer transaction tests do not replace that real release smoke test.

## References

- [Apple: open an application at a specific URL](https://developer.apple.com/documentation/appkit/nsworkspace/openapplication(at:configuration:completionhandler:))
- [Apple: verify static code validity](https://developer.apple.com/documentation/security/secstaticcodecheckvalidity(_:_:_:))
- [Sparkle update behavior and background checks](https://sparkle-project.org/documentation/customization/) informed the user flow. Sparkle itself is not bundled; the existing GitHub release format is retained.
