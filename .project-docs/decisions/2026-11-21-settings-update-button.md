---
id: settings-update-button-2026-11-21
type: decision
title: The Settings footer keeps an Update button and ✕ no longer skips a version
summary: ✕ on the island Update pill only hides it until the next launch, records no Sparkle skip and keeps the held reply; the Settings footer shows Update, Updating… or Restart beside the version while an update is known this session.
status: confirmed
tags: [updates, sparkle, settings]
canonical_for: [settings-update-button]
verified_at: 2026-11-21
sources:
  - type: user-confirmed
    reference: On 2026-11-21 the user reported a user stuck on 2.2.24 and asked for an always available Update button beside the version in the Settings footer after ✕, and for the whytap.ai link to read Whytap.
    confirmed_at: 2026-11-21
  - type: repository
    reference: Sources/Sidekey/Updates/UpdateController.swift
    confirmed_at: 2026-11-21
  - type: repository
    reference: Sources/Sidekey/Settings/SettingsProjectFooter.swift
    confirmed_at: 2026-11-21
  - type: repository
    reference: Tests/SidekeyTests/Updates/UpdateControllerTests.swift
    confirmed_at: 2026-11-21
related: [2026-11-24-whats-new-window.md]
---

# Update button in the Settings footer; ✕ no longer skips a version

## Context

A user stayed on Whytap 2.2.24 while 2.2.25 was published. The island's
Update pill had ✕ "Skip this version", which replied `.skip` to Sparkle.
Sparkle stores that build (`SUSkippedVersion`) and its scheduled and probing
checks stop finding it or any older build; only a user-initiated check would
show it, and Whytap has no manual check. One stray click left the user without
any way to update until a newer build appeared.

The owner asked (2026-11-21) that after ✕ an Update button stays available
in Settings, beside the app version in the sidebar footer.

## Decision

- ✕ on the `.available` pill hides the pill until the next launch
  (`UpdateController.hidePendingUpdate`). It sends Sparkle no reply, so no
  skip is recorded and the driver keeps the held `updateFound` reply.
- `UpdateController.settingsOffer` drives a footer button beside
  "Whytap <version>": Update while the update is available (pill shown or
  hidden), a disabled Updating… while it downloads or installs, Restart when
  a downloaded update waits. The click performs the pill's own action
  (`updateFromSettings`). A hidden update first becomes the island pill again,
  already downloading, so the progress, Ready, deferral and auto-install rules
  stay the ones the pill uses.
- A rediscovery of a dismissed build in the same session (after Ready-stage
  Later) keeps the pill hidden but restores the footer offer.
- A cleared Sparkle session or failed download drops the hidden offer: there
  is no reply left to start it with.
- The website link in the same footer reads "Whytap" instead of "whytap.ai".

## Why

- A footer that only mirrors the pill would lose the update after a relaunch
  if ✕ still recorded a skip: Sparkle's background and probing checks never
  report skipped builds. Keeping the reply held is the only way to have the
  same build startable later without a user-initiated Sparkle check, which
  would add a "Check for Updates" path invariant 4 rules out.
- Holding the reply is the state an ignored pill already has; it only delays
  Sparkle's next background check until the user acts or relaunches.
- The footer is the place the user looks for the version, so the action sits
  next to it and is visible without hover.

## What we tested

- Sparkle 2 source: `.skip` from `showUpdateFound` calls
  `SPUSkippedUpdate skipUpdate:`; `SUAppcastDriver` filters items whose version
  is less than or equal to the skipped one for non-user-initiated checks;
  `checkForUpdateInformation` also ignores skipped builds. The Ready-stage
  reply comes from `showReadyToInstallAndRelaunch:` and records no skip, so
  Later is unchanged.
- `UpdateControllerTests`: ✕ sends no reply and keeps the offer; the footer
  starts the download through the held reply and still auto-installs when
  idle; Update / Updating… / Restart mirror the pill; rediscovery after Later;
  a cleared session drops the offer; a new discovery replaces it.

## Rejected

- Keep ✕ as skip and show the footer button only this session: lost on the
  next launch, the original problem.
- Clear `SUSkippedVersion` at launch: needs Sparkle's private key names and
  is unnecessary once ✕ stops writing it; a build skipped by an older Whytap
  only hides that build, newer releases still appear.
- A footer "Check for updates" that calls `checkForUpdates()`: a manual check
  path (invariant 4) with extra "no update" UI.
- Reply `.dismiss` on ✕: ends the Sparkle session, so the footer would have
  nothing to start until the next hourly check.

2026-11-21 · PR: see the pull request that adds this file.
