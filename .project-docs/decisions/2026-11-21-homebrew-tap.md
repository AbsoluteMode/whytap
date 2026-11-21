---
id: homebrew-tap-2026-11-21
type: decision
title: Install Whytap with Homebrew from the project's own tap
summary: brew install absolutemode/tap/whytap installs the release DMG from the public tap AbsoluteMode/homebrew-tap, and the production release step moves the cask's version and sha256 after publishing.
status: confirmed
tags: [homebrew, cask, install, release, tap]
canonical_for: [homebrew-tap]
verified_at: 2026-11-21
sources:
  - type: user-confirmed
    reference: On 2026-11-21 an expert-council review of the GitHub page proposed one-command install with Homebrew. Because the official homebrew-cask needs at least 75 stars (225 when the author submits it), the maintainer approved a separate public tap and the creation of the AbsoluteMode/homebrew-tap repository.
    confirmed_at: 2026-11-21
  - type: repository
    reference: scripts/update-homebrew-cask.py
    confirmed_at: 2026-11-21
  - type: repository
    reference: scripts/upload-release.sh
    confirmed_at: 2026-11-21
  - type: repository
    reference: scripts/test-update-homebrew-cask.py
    confirmed_at: 2026-11-21
  - type: url
    reference: https://github.com/AbsoluteMode/homebrew-tap
    confirmed_at: 2026-11-21
related: []
---

# Install Whytap with Homebrew from the project's own tap

## Context

Whytap ships as a signed, notarized DMG on GitHub Releases and updates itself
through Sparkle. A review of the GitHub page asked for one-command installation.
The official `homebrew/cask` repository accepts a cask only for a project with
enough stars or notability (75 stars, 225 if the author submits it), which the
project does not have yet.

## Decision

- A separate public tap, `AbsoluteMode/homebrew-tap` (MIT), holds
  `Casks/whytap.rb`. The command is `brew install absolutemode/tap/whytap`.
- The cask url is `https://github.com/AbsoluteMode/whytap/releases/download/v#{version}/Whytap-latest.dmg`.
  Only `version` and `sha256` change per release. It declares `auto_updates true`
  (Sparkle), `depends_on macos: :sonoma`, `app "Whytap.app"`, a `livecheck` on the
  latest GitHub release and a `zap` list of the app's user Library locations.
- The last step of a prod `upload-release.sh` run calls
  `scripts/update-homebrew-cask.py update`. It hashes the staged archive, compares
  that with the digest GitHub reports for the published asset and commits the two
  lines to the tap through the contents API. A failure warns and never fails the
  already published release; `check` and a manual `update` catch the tap up.
- GitHub Actions stays disabled in the tap and in Whytap.

## Why

The tap needs no third-party approval and reaches the same bytes users already
download, so the signing identity, notarization and Sparkle feed are unchanged.
Pinning the tag and a SHA-256 makes Homebrew verify the archive. Updating through
the release process keeps the pin from drifting, and doing it after publication
means a cask problem cannot block or undo a release. Contents-API writes avoid a
clone and a credential beyond the `gh` login that publishing already needs.

`zap` removes data, so it is opt-in (`brew uninstall --zap`) and the tap README
and install guide warn that it deletes meeting notes, history and the Case vault.
Keychain items are never removed. `depends_on macos: :sonoma` is the closest
Homebrew symbol for macOS 14.2; the app itself refuses older systems.

## What was checked

- `brew style` reports no offenses (it required `homepage` with a trailing slash
  and `depends_on macos: :sonoma`).
- `brew audit --cask --strict --online absolutemode/tap/whytap` passes. It downloaded
  and extracted the 2.2.25 DMG, which confirms the sha256 and that `Whytap.app`
  sits at the image root. Homebrew 7 refuses to audit on this Mac because
  Xcode 26.4.1 is older than it requires, so the run stubbed that one check
  in-process and trusted the tap for that run only through an environment
  variable; no Homebrew setting was changed.
- The DMG's `CFBundleIdentifier` is `com.rootwise.sidekey` and its
  `LSMinimumSystemVersion` enforces 14.2 within the cask's Sonoma requirement.
- 15 unit tests cover the rewrite rules, downgrade refusal, hash mismatch,
  a missing asset, dry run, a concurrent edit and the stale check. A live
  `check` and `--dry-run` against the real tap behaved as expected.
- No app was installed or launched; the shared working app was not touched.

## Rejected alternatives

- Submitting to `homebrew/cask`: not eligible yet; revisit when the project has
  the stars.
- A GitHub Actions workflow in the tap to bump the cask: Actions is disabled for
  cost reasons.
- Pointing the cask at `releases/latest/download/Whytap-latest.dmg`: the bytes
  change with every release, so the pinned sha256 would break.
- Failing the release when the cask update fails: the release is already public
  and the cask is recoverable with one command.

2026-11-21 · tap repository https://github.com/AbsoluteMode/homebrew-tap
