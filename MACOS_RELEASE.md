# Signed macOS releases

The public macOS download must be signed with a **Developer ID Application** certificate and notarized by Apple. Ad-hoc signing is useful for local development, but Gatekeeper will show an “Apple could not verify” warning for downloaded ad-hoc builds.

The manual GitHub Actions workflow in `.github/workflows/release-macos.yml` builds the app, enables hardened runtime, submits it to Apple, staples the notarization ticket, verifies it with Gatekeeper, and replaces the macOS ZIP on the selected GitHub release.

## One-time Apple setup

1. Join the Apple Developer Program.
2. As the Apple Developer account holder, create a **Developer ID Application** certificate and export it from Keychain Access as a password-protected `.p12` file.
3. Create an App Store Connect team API key with access to the Apple notary service and download its `.p8` private key.
4. Add these encrypted repository secrets in **GitHub → Settings → Secrets and variables → Actions**:

   - `MACOS_DEVELOPER_ID_P12`: base64 text of the `.p12` file (`base64 -i DeveloperID.p12 | pbcopy` on macOS).
   - `MACOS_DEVELOPER_ID_P12_PASSWORD`: the export password for the `.p12` file.
   - `APP_STORE_CONNECT_KEY_ID`: the API key ID.
   - `APP_STORE_CONNECT_ISSUER_ID`: the App Store Connect issuer ID.
   - `APP_STORE_CONNECT_PRIVATE_KEY`: the complete contents of the downloaded `.p8` file, including its BEGIN and END lines.

Treat the certificate, password, and API key as private credentials. Never commit them to the repository.

## Publish a notarized beta

1. Open **Actions → Release signed and notarized macOS app**.
2. Choose **Run workflow**.
3. Enter the existing release tag and macOS asset filename.
4. Wait for every signing, notarization, stapling, and Gatekeeper check to pass.

The workflow only replaces the public download after Apple accepts the submission and `spctl` accepts the stapled app.

## Local development

`sh build_app.sh` continues to create an ad-hoc signed local build when `CODESIGN_IDENTITY` is not set. To create a Developer ID build locally after installing the certificate:

```sh
CODESIGN_IDENTITY='Developer ID Application: Your Name (TEAMID)' sh build_app.sh
```

Notarization is still required before distributing that build to other people.
