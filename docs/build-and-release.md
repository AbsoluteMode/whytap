# Local builds and community releases

Most users install a ready-made Whytap DMG and update through the island's
**Update** button. Source builds remain available for customization. The
development build works without an Apple Developer account. The community
release pipeline signs with the Developer ID certificate of Whytap's Apple team,
and a run that publishes also has Apple notarize and staple the build, with the
team's App Store Connect API key from Whytap Case. A checkout without
`Resources/developer-id-team.txt` signs with the community certificate or ad hoc
and cannot be notarized.

In [Releases](https://github.com/AbsoluteMode/whytap/releases), Whytap community
builds use Whytap-named assets. Existing Exodia packages remain downloadable
until the next public Whytap release; do not rename or relabel a sealed archive.
The repository rename preserves releases and redirects existing Exodia URLs.

## Build and run a customization

For the maintainer's parallel feature sessions, follow the
[shared application procedure](../.project-docs/processes/shared-app-development.md).
Feature worktrees use non-launching Swift builds/tests. The commands below
describe a standalone source customization; dev packaging can stop other beta
processes, so it is not the way to update the shared installed production app.
Finished feature agents automatically submit reviewed PRs to the persistent
FIFO build queue. Its designated builder owns integration and local promotion;
queue pickup does not bypass any release or safe-restart check.

Use macOS 14.2 or newer and Xcode 26 or newer with its command-line tools:

```bash
git clone https://github.com/AbsoluteMode/whytap.git
cd whytap
swift build
swift test
./scripts/dev-run.sh --run
```

The script builds `build/Whytap-Beta-dev.app` at a stable path with the beta
bundle identity. It uses an existing local `Sidekey Dev` signing identity or
falls back to ad-hoc signing. Do not launch the main app with `swift run`.
Ad-hoc rebuilds may require granting macOS permissions again.

Building leaves other running apps alone and does not register build-only
bundles in LaunchServices. If the usual development bundle is running, the
script assembles a separate candidate. New builds coordinate one running copy
across production, beta and worktrees before starting providers or permissions.
The second copy offers to activate the existing app; it never stops a recording.
Settings shows the app name and display version, plus website and GitHub links.
The compact footer omits channel, build number, source revision and bundle path;
those diagnostics remain available from bundle metadata and the maintainer's
current-build receipt.

Development version `0.0.0-dev` / build `9999` keeps published binary updates
from replacing the custom app. Update the checkout with your coding agent,
preserve local changes, validate and rerun the script. Production users receive
ready-made updates without rebuilding source.

## Validate locally

```bash
swift build
swift test
python3 scripts/customize.py doctor --json
FLAVOR=prod ./scripts/build-dmg.sh --preflight-only
```

The packaging preflight is offline: it checks resources, the selected toolchain
and distribution mode without building, downloading or publishing. Community
packaging requires the macOS 26 SDK, committed BlockNote assets and the Sparkle
public key. The MLX metallib and `scripts/build-metallib.sh` were removed with
the on-device models; see
[the decision](../.project-docs/decisions/2026-10-18-remove-local-models.md).

Build, test and package on the maintainer's Mac. Record local verification in the
PR. GitHub hosts source and finished release assets; GitHub Actions stays disabled.
Scripts support the Bash 3.2 shipped with macOS; avoid empty-array expansion under
`set -u`.

## Publish a community release

Bump `VERSION` and commit the release inputs before building. `Sources/`,
`Resources/`, `Package.swift`, `Package.resolved`, `VERSION` and `scripts/` must
be clean. The normal commands are:

```bash
FLAVOR=prod ./scripts/user-release.sh --dry-run
doppler run --project sidekey --config dev -- env FLAVOR=prod ./scripts/user-release.sh --build-only
doppler run --project sidekey --config dev -- env FLAVOR=prod ./scripts/user-release.sh
```

The build signs with the team's Developer ID certificate from the login keychain.
The full run also notarizes and staples it with the App Store Connect API key
from Whytap Case (see [Apple notarization](#apple-notarization)); `--build-only`
does not, unless `EXODIA_NOTARIZE=1` is set. Doppler supplies the Sparkle key
for publication, and the community code-signing key only for a build without
the team file; see below.

`--dry-run` reads the live feed and installed build to calculate versions, but
does not build or upload. It is not the offline preflight. `--build-only` creates
the universal arm64/x86_64 app and DMG without publishing. The default full command
builds and publishes to GitHub Releases, including Sparkle's appcast with
cryptographic signatures for the update archives. The XML feed itself is not
signed; HTTPS protects its transport and Sparkle verifies each archive before
extraction.
The script chooses a build number newer than the live feed and installed copy;
set `BUILD_VERSION` explicitly for a first release when neither exists.

### Release provenance contract

Every upload must be bound to the commit used for its build. The release helper
`scripts/release-provenance.py` must capture the build-time HEAD and clean input
state, then seal the completed DMG's SHA-256 and size together with its version,
build, flavor, distribution mode, code-signing identity, notarization, bundle ID
and architectures (manifest schema 3). Its subcommands are `capture`, `seal` and
`verify`; the build and upload scripts call them. The upload derives the
expected code-signing identity from the committed team or certificate (see
below), so a local ad-hoc or test-certificate build cannot be published, and
expects `notarization: notarized` for a team release unless `EXODIA_NOTARIZE=0`.
The provenance CLI defaults `--notarization` to `none` for existing local
build-only verifiers; publishing always passes its explicit expectation.
Keep the adjacent `<DMG>.manifest.json` with the archive;
`--upload-only` requires both files from the same build.

The publication gate must reject a missing or inconsistent manifest, changed
source commit or changed archive bytes before loading signing keys or uploading.
The GitHub release must target the verified manifest's build commit, rather
than whichever HEAD happens to be current during upload. Do not reuse a DMG
after changing HEAD, relabel an old archive or edit a manifest to make it pass;
commit the intended inputs and rebuild. These are pipeline requirements;
candidate-specific verification remains part of release acceptance.

Every DMG includes the committed drag-to-install background and a 660 × 440
Finder icon window, with Whytap on the left and Applications on the right.
`scripts/dmg-layout.py` writes `.DS_Store` directly on the writable HFS+ image;
no live Finder session or Automation permission is needed. The pinned MIT
Python dependencies are included under `scripts/_vendor/`, so packaging requires
no pip install or additional network access. `EXODIA_DMG_HEADLESS=0|1` remains
accepted for existing builders; both values produce the same required layout.

Before compiling, the preflight requires the source background and layout
modules. After compression, the build mounts the final archive read-only and
checks its window/view settings, both icon positions, exact background bytes
and alias to that image inside the volume. Missing or altered layout fails the
build before DMG signing, notarization or provenance sealing. To run focused
checks without building or launching the app:

```bash
/usr/bin/python3 -m unittest discover -s scripts/tests -p 'test_dmg_layout.py' -v
```

Publication requires authenticated GitHub release access and Whytap's Sparkle
Ed25519 private key through `SPARKLE_ED_PRIVATE_KEY` or
`SPARKLE_ED_PRIVATE_KEY_FILE`. Keep its matching public key in
`Resources/sparkle-public-ed-key.txt`. Never commit or print the private key.
`upload-release.sh` verifies the generated archive signature before upload.

Sparkle signatures authenticate update archives using Whytap's own key. They
are independent of Apple code signing and notarization. Gatekeeper's
first-download warning disappears only for notarized releases; releases up to
2.2.15 are not notarized, see [installation](install.md).

### Apple notarization

A team-signed release is notarized by Apple and stapled, so a downloaded Whytap
opens without **Open Anyway**. Notarization costs nothing beyond the Apple
Developer Program membership. `EXODIA_NOTARIZE=1` selects it. `user-release.sh`
sets it by default for every run that publishes a team build; `--build-only`,
which the builder uses for local refreshes, notarizes only when asked.
`EXODIA_NOTARIZE=0` explicitly publishes a team archive without notarization,
for example while Apple's notary queue is stalled; the upload warns about it.

The App Store Connect API key lives only in Whytap Case, project `whytap`, never
in Doppler, the repository or a shell profile:

| Case key | Value |
| --- | --- |
| `ASC_API_KEY_ID` | the key's Key ID |
| `ASC_API_KEY_ISSUER_ID` | the team's Issuer ID |
| `ASC_API_KEY_P8` | the contents of `AuthKey_<Key ID>.p8` |

The Account Holder or an Admin of team `UVBKCN5PPV` creates a team key with the
**Developer** role in App Store Connect → Users and Access → Integrations →
App Store Connect API → Team Keys, and downloads the `.p8` file (possible only
once). Paste the whole file into Case; a value whose line breaks were lost in
the single-line field is accepted.

Before compiling, `build-dmg.sh` checks `xcrun notarytool` and lists the key
names of the Case project (`whytap case ls -p whytap`, names only). A missing key
stops the build and names it. After signing, the build zips the app and submits
it with `whytap case run -p whytap --only ASC_API_KEY_ID,ASC_API_KEY_ISSUER_ID,ASC_API_KEY_P8`,
which runs `scripts/notarize-submit.sh` with the key in that one process's
environment. The script writes the private key to a 0600 file in a private
temporary directory, runs `xcrun notarytool submit --wait --timeout 1200` and
wipes the file on exit, also when interrupted. notarytool accepts the Key ID and
Issuer ID only as arguments; the private key is never an argument and nothing
prints it. A rejected submission's log is saved as
`build/notarization-<submission id>.json`.

The build then staples the ticket to the app, requires Gatekeeper to report
`source=Notarized Developer ID` for it and runs `syspolicy_check distribution`.
It packages and signs the DMG, checks that the app inside keeps its ticket,
notarizes and staples the DMG and requires the same Gatekeeper result for it.
Stapling both lets a copy of the app open without reaching Apple's servers. The
manifest seals `notarization: notarized` next to `code_signing: team:UVBKCN5PPV`.
For a team release the upload refuses an unnotarized manifest and also runs
`xcrun stapler validate` and the Gatekeeper assessment on the DMG itself, before
loading the Sparkle key or calling GitHub.

Case treats each `case run` like any other secret use: in Accept mode it asks
once per submission, so twice per build (the app and the DMG). The client that
runs the build must be registered in Case with access to project `whytap`.
A submission usually takes a few minutes. The wait ends after 20 minutes, and
the build then fails without an archive; the submission continues on Apple's
side, so rebuild later.

Build a notarized beta for testing, then check it:

```bash
FLAVOR=beta EXODIA_NOTARIZE=1 ./scripts/user-release.sh --build-only
xcrun stapler validate build/Whytap-Beta-<version>-build<build>.dmg
spctl -a -vv build/Whytap-Beta.app
spctl -a -t open --context context:primary-signature -vv build/Whytap-Beta-<version>-build<build>.dmg
```

`stapler` reports that the validate action worked, and both assessments report
`accepted` with `source=Notarized Developer ID`. WHY:
[notarized releases](decisions/2026-10-21-notarized-releases.md).

### Developer ID team identity

`Resources/developer-id-team.txt` commits Whytap's Apple team, `UVBKCN5PPV`.
With that file `build-dmg.sh` signs the app, its nested code and the DMG with the
team's Developer ID Application certificate from the login keychain, using the
hardened runtime and Apple's secure timestamp (the build needs network access
for it). The distribution stays `community`, and the manifest seals
`code_signing: team:UVBKCN5PPV`. Notarization is a separate step of the same
build; see [Apple notarization](#apple-notarization).

Before compiling, the build looks for exactly one valid Developer ID Application
identity of that team and stops if there is none. While a renewed certificate
and the old one are both valid, choose one with
`EXODIA_DEVELOPER_ID_IDENTITY=<SHA-1>`. The current certificate expires on
2027-02-01; the account holder renews it in the same team, which changes nothing
for installed apps.

Every build gets the team's designated requirement:
`identifier "com.rootwise.sidekey" and anchor apple generic and certificate 1[field.1.2.840.113635.100.6.2.6] /* exists */ and certificate leaf[field.1.2.840.113635.100.6.1.13] /* exists */ and certificate leaf[subject.OU] = UVBKCN5PPV`
(`com.rootwise.sidekey.beta` for beta). The build checks it on the app and the
copy in the DMG, and checks that the nested code and the DMG carry the team's
Developer ID certificate. macOS privacy grants follow that requirement, and the
keychain partitions items by the Apple team instead of the build's code hash, so
neither Keychain access nor permissions are requested again after an update.

The first team-signed build replaces the community certificate's requirement.
Every install then asks once more for Microphone, System Audio Recording and the
other granted permissions, and once for each Keychain item; choose **Always
Allow** there. After that, updates within the team ask for nothing.
`PackagingRebrandTests` pins the team, so another team fails the tests until the
pin is changed on purpose. WHY:
[Developer ID team signing](../.project-docs/decisions/2026-10-21-developer-id-team-signing.md).

### Community code-signing identity

Without the team file, `build-dmg.sh` signs the app, its nested code and the DMG
with Whytap's self-signed code-signing certificate, committed as
`Resources/community-signing-certificate.pem` (CN "Exodia Community Code
Signing", SHA-1 `39da363652f6df4b52ac950998e16c98fd39bc6b`, valid until
2056-10-11). Without either file, for example in a fork that removed them, the
build signs ad hoc.

The certificate gives every build the same designated requirement:
`identifier "com.rootwise.sidekey" and certificate leaf = H"<certificate SHA-1>"`
(`com.rootwise.sidekey.beta` for beta). macOS privacy grants such as Microphone
and System Audio Recording are stored against that requirement, so they survive
updates. An ad-hoc requirement is the build's code hash, which changes with
every build, so each ad-hoc update asked for those permissions again. The
certificate is not issued by Apple and changes nothing for Gatekeeper; users
never trust or install it.

The certificate is public. Its private key lives only in Doppler as
`EXODIA_COMMUNITY_SIGNING_KEY` in `sidekey/dev`, next to the Sparkle key. Never
commit or print it. Build with the key in the environment:

```bash
doppler run --project sidekey --config dev -- env FLAVOR=prod ./scripts/user-release.sh --build-only
```

`EXODIA_COMMUNITY_SIGNING_KEY_FILE` reads the key from a file instead. Before
compiling, the build checks that the key matches the certificate. For signing it
imports the identity into a temporary keychain that is not added to the keychain
search list and is deleted on exit. It checks the app against the expected
designated requirement, checks that each nested component and the DMG carry the
certificate, repeats the app check on the mounted DMG and seals
`code_signing: certificate:<SHA-1>` in the manifest.

`./scripts/community-signing-bootstrap.sh` creates the identity once. It refuses
to replace an existing certificate or Doppler secret. A new certificate is a new
identity: every install has to grant its permissions once more, so rotate only
if the key leaks. `PackagingRebrandTests` pins the certificate's SHA-1, so a
replaced certificate fails the tests until the pin is changed on purpose. Code
signed with the key inherits the users' grants, which is why the key stays as
private as the Sparkle key.

The first certificate-signed release changes the requirement of installs that
came from an ad-hoc build, so they grant Microphone and System Audio Recording
one last time. Sparkle accepts the change: it checks the archive's EdDSA
signature and the new app's code signature, not its identity. Keychain prompts
after an update stayed, because without an Apple team ID the keychain ties its
access to the code hash; the Developer ID team identity above removes them.

For local experiments, `EXODIA_COMMUNITY_SIGNING=adhoc` forces ad-hoc signing
and `EXODIA_COMMUNITY_SIGNING_CERTIFICATE_FILE` signs with another certificate.
Neither can be published: `user-release.sh` refuses them in a full run, and the
upload rejects any archive whose identity differs from the committed team or
certificate.

`EXODIA_LEGACY_SIGNED_RELEASE=1` explicitly selects the older Developer ID and
notarization path. That mode requires `TEAM_ID`, a Developer ID certificate and
`ASC_API_KEY_ID`, `ASC_API_KEY_ISSUER_ID`, `ASC_API_KEY_P8` in the environment,
does not check the team's designated requirement and records
`distribution: developer-id`. Team notarization above replaces it; it is not the
Whytap delivery path. It shares `notarize-submit.sh` with team notarization.

## Channels and updates

| Flavor | Bundle ID | App | Sparkle feed |
| --- | --- | --- | --- |
| `prod` | `com.rootwise.sidekey` | `Whytap.app` | `https://github.com/AbsoluteMode/whytap/releases/latest/download/appcast.xml` |
| `beta` | `com.rootwise.sidekey.beta` | `Whytap-Beta.app` | `https://github.com/AbsoluteMode/whytap/releases/download/beta/appcast.xml` |

Production tags are `v<version>` and include one DMG, `Whytap-latest.dmg`,
and the update feed `appcast.xml`. The public download link stays
`https://github.com/AbsoluteMode/whytap/releases/latest/download/Whytap-latest.dmg`.
The signed feed pins each archive to its immutable release tag, for example
`releases/download/v2.2.18/Whytap-latest.dmg`, so a later release cannot change
the bytes expected by an older feed. Existing release assets and feed URLs stay
available. Local build archives and their provenance manifests keep their
version/build names; the upload verifies the byte-identical latest copy and
publishes only that DMG. Beta releases are prereleases with a rolling
`beta` feed. Every update is a complete archive, verified by Sparkle before
installation.

Scheduled discovery shows **Update** in the island; downloading requires the
user's action. An idle app installs and relaunches after the requested download.
Busy meeting recording, dictation or agent activity defers app-initiated relaunch.
Returning to idle does not restart the app automatically. A prepared download may
apply on ordinary user quit; **Restart** applies it once work is finished, while
ready-stage **Later** cancels this installation with `.skip` without permanently
skipping the version. No installation guarantee applies to force quit, crashes,
process kills or power loss. The updater behavior is defined in
`Sources/Sidekey/Updates/UpdateController.swift` and `IslandUpdateUserDriver.swift`.

The package is named Whytap, while Swift targets, bundle IDs, Keychain services,
UserDefaults keys and data directories retain compatibility names. Keep these
stable to preserve user data. A separate fork must choose its own identities,
Sparkle key pair, code-signing certificate and update feed; see
[trademarks](../TRADEMARK.md). Whytap's team and certificate cannot sign without
Whytap's keys: delete `Resources/developer-id-team.txt` (or commit the fork's own
team) and `Resources/community-signing-certificate.pem`, then run
`community-signing-bootstrap.sh` with the fork's own Doppler project or
`--key-file`, or publish ad hoc.

### Planner native OAuth clients

`configure-calendar-clients.py` adds the owner's registered public native clients
to the unsigned app Info.plist before either packaging path signs it. The default
input is `whytap-calendar-clients.plist` in the Git common directory; the explicit
`WHYTAP_CALENDAR_CLIENTS_PLIST` override is also supported. Keep this local input
outside source commits and public logs. No account tokens or confidential web-app
secrets belong in it. Use `--require-all` on the helper for acceptance of a candidate
intended to offer Google, Outlook and Zoom sign-in without manual client setup.
A build with no such input retains advanced custom-client setup and Apple access.
