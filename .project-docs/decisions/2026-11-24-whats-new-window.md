---
id: whats-new-window-2026-11-24
type: decision
title: After an update, a window lists what changed for the person
summary: Each public release ships a hand-written list in Resources/WhatsNew.json, bundled in the app. The first launch of a newer version opens one window with the releases since the version the person had; a release with nothing for them opens nothing, a new Mac gets the onboarding instead, and the version in Settings reopens the list. The release script refuses a version without its entry.
status: confirmed
tags: [updates, release-notes, whats-new, release, onboarding]
canonical_for: [whats-new-window, release-user-notes]
verified_at: 2026-11-24
sources:
  - type: user-confirmed
    reference: On 2026-11-24 the first outside tester of 2.2.27 said on a call that the update arrived, he pressed it, the app updated, and he could not tell what happened or why it updated. The maintainer asked for release notes shown in a nicely made window after an update, when something changed for the person.
    confirmed_at: 2026-11-24
  - type: user-confirmed
    reference: On 2026-11-24 the maintainer looked at the offscreen pictures of the 2.2.27 list, with and without the clip, and answered "yes, with the clip".
    confirmed_at: 2026-11-24
  - type: repository
    reference: Sources/Sidekey/WhatsNew/WhatsNewCatalog.swift
    confirmed_at: 2026-11-24
  - type: repository
    reference: Tests/SidekeyTests/WhatsNew/WhatsNewTests.swift
    confirmed_at: 2026-11-24
  - type: repository
    reference: scripts/whats-new.py
    confirmed_at: 2026-11-24
related: [2026-11-21-settings-update-button.md]
---

# What's New window

The maintainer asked for the window and on 2026-11-24 accepted its look
from the offscreen pictures (`WHYTAP_WHATSNEW_RENDER_DIR`), choosing the
variant with the clip over the one without.

## Context

After an update the island showed "Updated" for five seconds and nothing
else. The release text existed only as the GitHub release body: twenty
paragraphs for people who read release pages, never shown in the app. The
first outside tester updated and did not learn what changed.

## Decision

- **The text is a file in the build.** `Resources/WhatsNew.json` holds one
  entry per public version: up to five items, each a title (36 characters), a
  body (120), an SF Symbol, optionally a bundled feature clip and a button
  that opens a Settings tab. It is written by hand for people, in English,
  and names only what a person who already uses Whytap will notice. A release
  with nothing of that kind has its entry with `"items": []`.
- **The release cannot start without it.** `scripts/user-release.sh` runs
  `scripts/whats-new.py check <version>` for the prod flavor, also on
  `--dry-run`, and stops when the version has no entry or the text breaks the
  limits. The entry lands through an ordinary pull request before the
  VERSION change, because the VERSION pull request changes that file only.
- **When the window opens.** `WhatsNewLaunch` remembers the last launched
  display version. A newer version opens the window once with every release
  after the remembered one, newest first, each under its version when there
  are several; releases without items are left out, and if none has items no
  window opens. A new Mac (the onboarding opens) only remembers the version.
  A Mac that ran Whytap before this window existed has nothing remembered:
  it sees the running version's list only. A rollback shows nothing. The
  version is remembered when the decision is made, not when the window is
  closed, so the window never returns by itself.
- **How it opens.** After an update the window comes forward without taking
  the keyboard from the app the person is in (`orderFrontRegardless`, no
  activation): an update can also apply on quit and the next launch may be a
  login. From Settings it activates like any window the person asked for.
- **Settings.** The version in the sidebar footer is a button that opens the
  same list with the earlier releases under it. It is plain text when the
  build has no list. Nothing else in Settings changed (its redesign is a
  separate task).
- **Look.** The Settings tokens, following the system appearance, with the
  onboarding's serif for the headline ("Whytap *2.2.27*"). The first item of
  the newest release shows its clip at 368 × 207 pt (still frame first, the
  silent loop over it; Reduce Motion keeps the still frame); the rest are
  rows in one card. One button, Got it; Escape and the close button do the
  same. Taller than 740 pt (or than a small screen), the middle scrolls.

## Why

- A bundled file matches the binary exactly, needs no network (invariant 1
  stays trivially true, and there is no "notes failed to load" state), and
  holds earlier versions, which is what makes a jump over several releases
  work without any feed history.
- The appcast was the other candidate. Sparkle hands release notes to the
  old binary before the install (`showUpdateReleaseNotes`), while the window
  is wanted in the new binary after the relaunch; the feed keeps what
  `generate_appcast` wrote for each archive and has no notes today; and an
  update applied outside Sparkle (a DMG, Homebrew) would show nothing.
- The GitHub release body stays the complete list. It is too long for a
  window and is addressed to readers of the release page; the window is a
  short selection of it.
- Remembering the version at decision time: a window buried under other
  windows must not come back on every launch. The list stays one click away
  in Settings.

## What was tested

`WhatsNewTests` runs the scenarios with the presenter's `display` replaced,
so no window opens: an update with changes (once, no activation), an update
with internal changes only, a first install and the update after it, a jump
over several versions, a Mac from before this window, a rollback and a
developer build, a build without the file or with a damaged one, the list
from Settings. It also checks the shipped file (limits, symbols, clips and
Settings tabs exist), that both packaging scripts copy it, that the release
script calls the check, and that one release fits the window without
scrolling. `scripts/tests/test_whats_new.py` covers the release check.
Offscreen pictures of the real 2.2.27 list and of a jump from 2.2.25 to
2.2.28, light and dark, were drawn for the maintainer.

Not checked in a running app: the playing clip, hover and focus, the window
coming forward after a real Sparkle relaunch.

## Rejected

- Release notes in the appcast, shown from Sparkle's callback: before the
  install, in the old binary, and absent for non-Sparkle updates.
- Fetching the GitHub release body at launch: a network request at every
  update, markdown written for another reader, and nothing offline.
- Generating the list from pull request titles: they describe code, not what
  a person notices.
- Keeping the window back until it is closed (remember on close): it would
  return on every launch while buried.
- A clip on every row: only some features have one, and several playing at
  once is noise.

2026-11-24 · ORCH-TASK 98
