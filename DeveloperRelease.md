# Developer Release Guide

This repo ships two apps from one xcodegen project: the **macOS** app (Developer ID + notarization, distributed via the GitHub Release page) and the **iPadOS** app (App Store Connect upload to **TestFlight**). The macOS app is Developer ID, *not* Mac App Store — it never touches App Store Connect. "In sync" means matching version/build numbers and a shared release trigger, not a shared App Store record.

GitHub Actions workflows:

- `Test`: runs unit tests on pull requests, pushes to `main`, and manual dispatch. It does not require signing secrets.
- `Build Developer ID App`: manually creates a Developer ID signed `.dmg` without notarization. Use this for release candidate validation.
- `Release Notarized App` (`release.yml`): runs when a GitHub Release is published, or when manually dispatched for an existing release tag. It has three jobs: `version` resolves the tag and computes one shared build number; `macos` builds, notarizes, and staples a `.dmg` (drag-to-Applications disk image — both the app *and* the disk image are stapled) and uploads it to the GitHub Release page; `ios` builds and uploads the iPad app to TestFlight. Both platform jobs build the same tag with the same build number, so a single release publishes both.

## Versioning

Marketing version and build number have a single source of truth in `project.yml` under `settings.base`:

- `MARKETING_VERSION` (e.g. `1.0.0`) — bump this one line to change the user-facing version of both apps.
- `CURRENT_PROJECT_VERSION` — the build number. The default (`1`) is a fallback; the release pipeline overrides it per run with a UTC timestamp formatted `YYYYMMDD.HHMMSS`. (The dotted form keeps every component under Apple's 2³²−1 per-component limit, while staying unique and monotonic.)

Both targets' Info.plist reference these via `$(MARKETING_VERSION)` / `$(CURRENT_PROJECT_VERSION)`, which Xcode expands at build time. After editing `project.yml`, run `xcodegen generate`.

## Required Apple Setup

Install a `Developer ID Application` certificate for team `9URLHJ84PY`. The certificate must include its private key.

In Keychain Access:

1. Select `login`.
2. Select `My Certificates`.
3. Find the `Developer ID Application` certificate for team `9URLHJ84PY`.
4. Expand it and confirm there is a private key underneath.
5. Export the certificate and private key as a `.p12` file.
6. Set an export password and keep it available for the GitHub secret.

Create an Apple ID app-specific password at `https://appleid.apple.com`. Use that for notarization, not your normal Apple ID password.

## GitHub Secrets

Add these repository or environment secrets.

Shared / macOS (Developer ID + notarization):

- `APPLE_TEAM_ID`: `9URLHJ84PY`
- `DEVELOPER_ID_APPLICATION_P12_BASE64`: base64-encoded exported `.p12`
- `DEVELOPER_ID_APPLICATION_P12_PASSWORD`: password used when exporting the `.p12`
- `NOTARY_APPLE_ID`: Apple ID email used for notarization
- `NOTARY_APP_PASSWORD`: Apple ID app-specific password

iOS (TestFlight, App Store Connect API key — see the iOS TestFlight section below):

- `APP_STORE_CONNECT_API_KEY_ID`: the Key ID of the App Store Connect API key
- `APP_STORE_CONNECT_API_ISSUER_ID`: the Issuer ID for that key
- `APP_STORE_CONNECT_API_KEY_BASE64`: base64 of the downloaded `.p8`

Create the macOS `.p12` base64 value with:

```sh
base64 -i DeveloperIDApplication.p12 | pbcopy
```

Paste the copied value into `DEVELOPER_ID_APPLICATION_P12_BASE64`. Create the iOS key base64 the same way: `base64 -i AuthKey_XXXXXXXXXX.p8 | pbcopy`.

## Local Commands

Run tests locally without signing:

```sh
xcodegen generate
xcodebuild test \
  -project KVMConsole.xcodeproj \
  -scheme KVMConsole \
  -destination 'platform=macOS' \
  CODE_SIGNING_ALLOWED=NO \
  CODE_SIGNING_REQUIRED=NO \
  CODE_SIGN_IDENTITY= \
  DEVELOPMENT_TEAM=
```

Build a signed but not notarized `.dmg`:

```sh
NOTARIZE=0 FINAL_DMG_PATH=build/developer-id/KVMConsole-signed.dmg Scripts/build-developer-id.sh
```

Build, notarize, staple, and package locally:

```sh
xcrun notarytool store-credentials KVMConsole-DeveloperID \
  --apple-id "you@example.com" \
  --team-id 9URLHJ84PY \
  --password "app-specific-password"

Scripts/build-developer-id.sh
```

## iOS TestFlight

The iPad app is uploaded to TestFlight via App Store Connect using an **App Store Connect API key** and **cloud signing** (`-allowProvisioningUpdates`). There is no manually managed distribution certificate or provisioning profile — xcodebuild creates and downloads the Apple Distribution cert and App Store provisioning profile on demand from the API key.

### One-time Apple setup

1. **Apple Developer portal → Identifiers**: ensure Bundle ID `io.lyx.KVMConsole` exists as an **iOS** App ID. No special capabilities are needed (local-network access is Info.plist-driven only).
2. **App Store Connect → Apps → New App**: platform **iOS**, bundle ID `io.lyx.KVMConsole`, name **"KVM Console"** (must be globally unique on the App Store — pick an alternate display name if taken), primary language, and an SKU.
3. **App Store Connect → Users and Access → Integrations → App Store Connect API**: create a key with role **Admin**. Admin is required — cloud-managed distribution signing (`-allowProvisioningUpdates`) needs access to cloud distribution certificates, which an App Manager key cannot create (it fails with "Cloud signing permission error"). Download the `.p8` (downloadable once only), and note the **Key ID** and the **Issuer ID**.
4. **App Store Connect → Agreements**: accept the (free-app) Paid/Free Apps agreement, or uploads are blocked.
5. Add the three `APP_STORE_CONNECT_API_*` GitHub secrets (see GitHub Secrets above).
6. After the first successful upload + processing, in the app's **TestFlight** tab: confirm export compliance (auto-satisfied by `ITSAppUsesNonExemptEncryption=false` in the iPad Info.plist), fill in **Beta App Information**, and add **internal testers** (an external group additionally needs Beta App Review).

### Local TestFlight upload

De-risk CI by running a local upload first with a personal API key (`.p8` downloaded from App Store Connect):

```sh
ASC_KEY_ID=XXXXXXXXXX \
ASC_ISSUER_ID=xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx \
ASC_KEY_PATH=/path/to/AuthKey_XXXXXXXXXX.p8 \
Scripts/build-testflight.sh
```

`BUILD_NUMBER` defaults to `date -u +%Y%m%d.%H%M%S` for local runs; CI injects the shared release build number. The build appears in the app's TestFlight tab once App Store Connect finishes processing.

## GitHub Release Flow

1. Merge the release commit to `main`.
2. Create and publish a GitHub Release for the desired tag.
3. The `version` job resolves the tag and computes one shared build number (`YYYYMMDD.HHMMSS`).
4. The `macos` job checks out the tag, imports the Developer ID certificate from GitHub Secrets, stores notarization credentials, runs `Scripts/build-developer-id.sh` (notarization enabled, carrying the shared build number), and uploads `KVMConsole-<tag>.dmg` to the release page.
5. The `ios` job checks out the same tag, decodes the App Store Connect API key, and runs `Scripts/build-testflight.sh` to upload the iPad build to TestFlight with the same build number.

The release page asset is the final user-downloadable macOS `.dmg`; the iPad build lands in TestFlight.

Note: the marketing version (`MARKETING_VERSION` in `project.yml`) should match the git tag you release. A `1.0.0` tag already exists at an older commit — when releasing, either move it to the commit that includes these pipeline/version changes (`git tag -f 1.0.0 && git push -f origin 1.0.0`) or cut a newer tag and set `MARKETING_VERSION` to match.

## Manual Release Retry

If a release workflow fails after the GitHub Release exists, rerun it from Actions with `workflow_dispatch` and the existing release tag. The upload step uses `--clobber`, so a successful retry replaces the previous release asset with the same name.
