---
id: developer-id-team-signing-2026-10-21
type: decision
title: Builds sign with the Developer ID certificate of Whytap's Apple team
summary: The committed team UVBKCN5PPV selects Developer ID signing without notarization, so the keychain partitions Whytap's items by team instead of by each build's cdhash and Keychain prompts stop after one last approval. The community certificate stays as the fallback without the team file.
status: confirmed
tags: [distribution, code-signing, keychain, tcc, sparkle, macos]
canonical_for: [release-code-signing-identity]
verified_at: 2026-10-21
sources:
  - type: user-confirmed
    reference: On 2026-10-21 the user reported dozens of Keychain password prompts after every build and chose signing with a Team ID certificate, using the existing team UVBKCN5PPV, for the working app and public releases.
    confirmed_at: 2026-10-21
  - type: repository
    reference: scripts/build-dmg.sh
    confirmed_at: 2026-10-21
  - type: repository
    reference: scripts/upload-release.sh
    confirmed_at: 2026-10-21
  - type: repository
    reference: scripts/user-release.sh
    confirmed_at: 2026-10-21
  - type: repository
    reference: scripts/release-provenance.py
    confirmed_at: 2026-10-21
  - type: repository
    reference: Tests/SidekeyTests/PackagingRebrandTests.swift
    confirmed_at: 2026-10-21
  - type: trace
    reference: Probe bundle com.rootwise.sidekey.signing-probe signed on 2026-10-21 with the team's Developer ID Application identity from the login keychain, hardened runtime and secure timestamp; designated requirement and controls recorded below.
    confirmed_at: 2026-10-21
related: [2026-10-19-community-signing-identity.md, 2026-10-17-community-updates.md, 2026-10-17-source-first-distribution.md, ../processes/shared-app-development.md, 2026-11-21-published-release-manifest.md]
---

# Developer ID team signing

> Update 2026-10-21: published team builds are now also notarized; see
> [notarized releases](../../docs/decisions/2026-10-21-notarized-releases.md).

## Context

Since the [community certificate](2026-10-19-community-signing-identity.md),
macOS privacy grants survive updates, but Keychain access does not. Whytap keeps
each secret as its own item in the login keychain: provider and BYOK keys, the
Case vault key, backup tokens. The keychain partitions an item by the Apple team
of the app that may read it. An app without a team ID gets a partition derived
from its cdhash, which changes with every build. The 2026-10-19 decision expected
this. In practice the maintainer's working app, rebuilt several times a day,
asked for the login password once per item after every build.

## Decision

- `Resources/developer-id-team.txt` commits the Apple team `UVBKCN5PPV`. With
  that file `build-dmg.sh` signs the app, its nested code and the DMG with the
  team's Developer ID Application certificate from the login keychain, with the
  hardened runtime and Apple's secure timestamp. Before compiling it requires
  exactly one valid identity of that team; while a renewed certificate and the
  old one are both valid, `EXODIA_DEVELOPER_ID_IDENTITY=<SHA-1>` chooses one.
- The build checks the app and the copy in the DMG against the exact requirement
  `identifier "<bundle ID>" and anchor apple generic and certificate 1[field.1.2.840.113635.100.6.2.6] /* exists */ and certificate leaf[field.1.2.840.113635.100.6.1.13] /* exists */ and certificate leaf[subject.OU] = UVBKCN5PPV`,
  and the nested code and the DMG against the team's Developer ID requirement.
- No notarization. The distribution stays `community` and the manifest seals
  `code_signing: team:UVBKCN5PPV`. The upload derives that value from the
  committed file, so community-certificate, test-certificate and ad-hoc archives
  cannot be published. The notarized `EXODIA_LEGACY_SIGNED_RELEASE=1` path is
  unchanged.
- Order of identities: test certificate override, team file, community
  certificate, ad hoc. `EXODIA_COMMUNITY_SIGNING=adhoc` still forces an
  unpublishable ad-hoc build. A fork deletes the team file and the certificate.
- The working app and public releases use the same team. Exactly one identity
  migration is approved: the builder installs the first team-signed candidate
  only while the maintainer is at the Mac, who then chooses **Always Allow** for
  each Keychain item and grants the permissions once more
  ([process](../processes/shared-app-development.md)).

## Why

- With a team ID the keychain partition is `teamid:UVBKCN5PPV` for every build,
  so one **Always Allow** per item lasts across updates and certificate renewals.
- The designated requirement names the team, not the certificate. TCC grants
  survive updates as with the community certificate, and also the renewal before
  the current certificate expires on 2027-02-01.
- The secure timestamp keeps signatures valid after a certificate expires.
- Sparkle accepts the switch the same way it accepted ad hoc to certificate
  (2026-10-19 analysis of 2.9.1): the archive passes EdDSA, and the new app only
  needs a valid signature. After the switch the host has a team ID, so Sparkle
  requires its XPC services to match it; the build signs them with the same team.
- `Resources/Sidekey.entitlements` has no restricted entitlement, so a Developer
  ID build needs no provisioning profile. Library validation stays disabled.
- Case accepts its bundled helper by cdhash and matches callers against
  registrations; no registration names this team, so the helper's new team ID
  changes nothing.
- Keeping one identity for the working app and releases avoids a public update
  on the maintainer's Mac switching the identity back.

## What we tested

- A universal probe bundle (`com.rootwise.sidekey.signing-probe`) signed with
  the team identity, `--options runtime --timestamp`: done in 2.5 s with no
  Keychain prompt. `TeamIdentifier=UVBKCN5PPV`, a secure timestamp is present,
  and the designated requirement equals the expected string exactly.
  `codesign --verify --strict --all-architectures` passes against it and against
  the team requirement. Controls fail: another team ID, the community
  certificate requirement, and the installed community-signed Whytap 2.2.17
  (1540) against the team requirement.
- The identity lookup on the maintainer's real listing finds exactly one
  identity of the team and none for another team.
- `FLAVOR=prod ./scripts/build-dmg.sh --preflight-only` reports
  `code_signing: team:UVBKCN5PPV`, `requires_apple_developer: true`,
  `requires_notarization: false`, without keychain access.
- `PackagingRebrandTests`: 23 tests, 0 failures. New fixtures: the identity is
  found before compiling; another team's identity, an ambiguous renewal and an
  unknown `EXODIA_DEVELOPER_ID_IDENTITY` stop the build; an explicit choice and
  the ad-hoc opt-out reach the compiler; the team takes precedence over the
  certificate in the preflight; an invalid team file stops it; the upload
  rejects a community-certificate archive when the team is committed and passes
  `team:` provenance; the committed team is pinned.
- Full `swift test` on the branch merged with main (`35fa0298`): 4,190 tests,
  20 skipped, 0 failures (142.6 s). An independent Codex review found no defects.
- Not tested here: packaging and installing a team-signed DMG (builder step),
  a Sparkle install from a certificate-signed to a team-signed build, and live
  Keychain/TCC behaviour after the migration (the acceptance check).

## Rejected

- Keep the community certificate: every build keeps asking for every item.
- Developer ID only for the working app: a public update installed on the same
  Mac switches the identity back and asks again.
- One keychain item for all secrets: still one prompt per build, and every
  store has to migrate.
- Data protection keychain with an access group: needs a provisioning profile
  and a migration of every item; the team partition already removes the prompts.
- Notarization now: separate from the prompts; the legacy path stays available.

2026-10-21, PR https://github.com/AbsoluteMode/whytap/pull/158.
