# Releasing Facet

Facet's normal local build stays lightweight and ad-hoc signed. Tagged GitHub releases use the dedicated release workflow to build a universal binary, sign it with Developer ID, enable the hardened runtime, notarize it with Apple, staple the ticket, and publish a ZIP plus SHA-256 checksum.

## Required GitHub secrets

Configure these repository Actions secrets before pushing a `v*` tag:

- `DEVELOPER_ID_CERT_BASE64` — base64-encoded Developer ID Application `.p12`
- `DEVELOPER_ID_CERT_PASSWORD` — password for that `.p12`
- `APPLE_ID` — Apple ID used for notarization
- `APPLE_TEAM_ID` — Apple Developer team ID
- `APPLE_APP_SPECIFIC_PASSWORD` — app-specific password for `notarytool`

The workflow intentionally fails before packaging if any release credential is missing. Secrets are imported into a temporary keychain on the GitHub runner and the keychain is deleted in an `always()` cleanup step.

## Release flow

1. Run the local regression and Chrome compatibility checks.
2. Commit the desired source state.
3. Create and push a version tag such as `v1.1.0`.
4. GitHub Actions runs `.github/workflows/release.yml`.
5. The workflow runs the WebKit/polish suite, blocker suite, and disposable current-Chrome compatibility test.
6. It builds `arm64 + x86_64` into one universal app, using the tag as `CFBundleShortVersionString`.
7. It signs with Developer ID + hardened runtime, verifies the signature, submits a temporary ZIP to `notarytool`, staples and validates the ticket, and runs Gatekeeper assessment.
8. It publishes `Facet-<version>-macOS-universal.zip` and a `.sha256` file to the GitHub Release.

## Local release-like build

A universal ad-hoc build can be checked without Apple credentials:

```sh
FACET_VERSION=1.1.0 FACET_BUILD_NUMBER=1 FACET_ARCHS="arm64 x86_64" ./build.sh
lipo -archs Facet.app/Contents/MacOS/Facet
codesign --verify --deep --strict --verbose=2 Facet.app
```

To test a real Developer ID identity locally, set `FACET_SIGN_IDENTITY` to the exact `Developer ID Application: ...` identity visible from `security find-identity -v -p codesigning`.

## Continuous compatibility

`.github/workflows/ci.yml` runs on pushes, pull requests, manual dispatch, and weekly. It installs/uses current Google Chrome and runs `tools/chrome-compat-smoke.sh` against a disposable `--user-data-dir`; it never opens the runner user's normal Chrome profile and never reads Chrome Safe Storage.

## Optional interactive Chrome crypto check

The normal CI smoke test deliberately avoids Keychain access. A developer can explicitly validate the current Chrome Safe Storage key against only the disposable fixture cookie with:

```sh
FACET_ALLOW_CHROME_KEYCHAIN_TEST=YES tools/chrome-compat-smoke.sh
```

This invokes the normal macOS authorization prompt. Do not enable this flag in CI.
