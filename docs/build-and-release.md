# Build and release

Whytap ships as a signed, notarized universal DMG published on GitHub
Releases. The same release carries the EdDSA-signed Sparkle `appcast.xml`,
so installed copies update in-app. Everything is built on a Mac with
`scripts/user-release.sh`; there is no CI release pipeline. Official updates
are built and tested on the maintainer's Mac. GitHub only hosts the source
and finished release assets; GitHub Actions is disabled to avoid runner costs.
See the [local build policy](../.project-docs/decisions/2026-09-10-byok-and-local-builds.md).

## Local validation

Run these on the Mac before merging or packaging an update:

```bash
swift build
swift test
```

Record the result in the pull request. Do not dispatch GitHub workflows for
validation or release builds.

## Prerequisites

- Xcode 26 or newer (the app compiles against the macOS 26 SDK;
  `scripts/build-dmg.sh` refuses older SDKs). Deployment floor stays
  macOS 14.2.
- A Developer ID Application certificate in the login keychain, and its
  Team ID exported as `TEAM_ID`.
- An App Store Connect API key for `notarytool`: `ASC_API_KEY_ID`,
  `ASC_API_KEY_ISSUER_ID`, `ASC_API_KEY_P8` (the `.p8` contents).
- A Sparkle Ed25519 key pair. The public key lives in
  `Resources/sparkle-public-ed-key.txt` and is baked into `Info.plist`; the
  private key is provided as `SPARKLE_ED_PRIVATE_KEY` (base64 seed) or
  `SPARKLE_ED_PRIVATE_KEY_FILE`. `scripts/sparkle-keys-bootstrap.sh`
  creates a pair for a fork.
- An authenticated GitHub CLI (`gh auth login`) with write access to the
  release repository (`GITHUB_REPO`, default `AbsoluteMode/whytap`).

The official releases get these values from Doppler:

```bash
doppler run --project sidekey --config dev -- env FLAVOR=prod ./scripts/user-release.sh
```

A fork exports them in the shell instead. No value is ever committed.

The release scripts support the Bash 3.2 shipped with macOS. Optional command
arguments are appended to nonempty arrays: expanding an empty array with
`set -u` fails in Bash 3.2 even when that array was explicitly initialized.

## Flavors

| Flavor | Bundle id | Bundle name | Feed |
|---|---|---|---|
| `prod` | `com.rootwise.sidekey` | `Whytap.app` | `https://github.com/<repo>/releases/latest/download/appcast.xml` |
| `beta` | `com.rootwise.sidekey.beta` | `Whytap-Beta.app` | `https://github.com/<repo>/releases/download/beta/appcast.xml` |

Both flavors install side by side (different bundle ids, keychain services
and feeds). Beta is built with `-Xswiftc -DBETA`; the feed URLs are the
`appcastURL` constants in `Sources/Sidekey/BuildConfig.swift` and the
`APPCAST_URL` variables in `scripts/build-dmg.sh`.

## Versions

- `VERSION` at the repository root is the marketing version
  (`CFBundleShortVersionString`). Bump it by hand before a release.
- The build number (`CFBundleVersion`) is what Sparkle compares. The release
  script infers it as `max(live appcast build, installed build) + 1`, so it
  stays monotonic across machines. Override with `BUILD_VERSION=` when the
  feed is unreachable.

## Releasing

```bash
FLAVOR=prod ./scripts/user-release.sh              # build, sign, notarize, publish
FLAVOR=beta ./scripts/user-release.sh              # same for the beta channel
FLAVOR=prod ./scripts/user-release.sh --dry-run    # show the versions, do nothing
FLAVOR=prod ./scripts/user-release.sh --build-only # DMG in build/, no publish
FLAVOR=prod SHORT_VERSION=2.0.1 BUILD_VERSION=1450 ./scripts/user-release.sh --upload-only
```

`user-release.sh` runs two scripts:

1. `scripts/build-dmg.sh` builds the release binary for arm64 and x86_64,
   merges them with `lipo`, assembles the `.app` (Info.plist from
   `Resources/Info.plist.template`, fonts, `mlx.metallib` as a sealed
   resource with the `Contents/MacOS` symlink), signs with the Developer ID,
   notarizes with `notarytool`, staples the ticket, requires Gatekeeper
   acceptance and a successful `--installation-check`, and produces
   `build/<Bundle>-<version>-build<build>.dmg`.
2. `scripts/upload-release.sh` downloads the current `appcast.xml` from the
   feed, adds the new DMG with Sparkle's `generate_appcast` (signed with the
   private key, no deltas), normalizes `sparkle:minimumSystemVersion` to the
   deployment floor, and creates the GitHub Release `v<version>` with three
   assets: the versioned DMG, a `<Bundle>-latest.dmg` copy for a stable
   download link, and `appcast.xml`. For `beta` the release is a prerelease
   tagged `beta-v<version>-b<build>`, and a rolling prerelease tagged `beta`
   receives the fresh `appcast.xml` and latest alias.

Sparkle enclosure URLs point at each release's own tag, so older releases
keep working after new ones are published. Re-running the upload for an
existing tag replaces the assets.

## Update behaviour in the app

Scheduled checks run hourly and never show Sparkle windows: the custom
`IslandUpdateUserDriver` shows an "Update" pill in the Dynamic Island,
downloads only when the user clicks, then installs and relaunches. See
`docs/decisions/2026-06-17-update-download-on-action.md`.

## Forks

To publish your own builds, change all of the following together:

1. `TEAM_ID`, your Developer ID certificate and notarization key.
2. `Resources/sparkle-public-ed-key.txt` and the matching private key
   (`scripts/sparkle-keys-bootstrap.sh`).
3. `GITHUB_REPO` and the `appcastURL` / `APPCAST_URL` constants.
4. The bundle identifier (`BuildConfig.bundleID`, `scripts/build-dmg.sh`,
   `scripts/dev-run.sh`), the app name and icon (see `TRADEMARK.md`).

Without step 2 and 3 a fork would verify and install the official Whytap
releases over itself.

## Development builds

```bash
./scripts/dev-run.sh --run
```

Builds a `Whytap-Beta-dev.app` with a stable ad-hoc signing identity so the
Accessibility, Microphone and System Audio grants survive rebuilds. Do not
use `swift run` for the app: each rebuild would get a new identity and macOS
would silently revoke the grants.

`Resources/mlx.metallib` is version-locked to the resolved `mlx-swift`
revision (`Resources/mlx.metallib.revision`). When bumping MLX, rebuild it
with `scripts/build-metallib.sh` in the same change; see
`docs/decisions/2026-06-30-metallib-sealed-resource-sequoia-gatekeeper.md`
for why it must stay a sealed resource.
