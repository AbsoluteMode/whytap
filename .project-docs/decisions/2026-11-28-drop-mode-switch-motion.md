---
id: drop-mode-switch-motion-2026-11-28
type: decision
title: The Smart/Fast switch has its own scoped animation, and settings capture reads keys off the main thread
summary: The Drop Mode tile symbol and the island's ON Smart/Fast status animate explicitly (symbol replace, status transition, 0.3 s smooth, none with Reduce Motion), scoped to those two views. The settings-history capture that follows every preference write reads provider keys in a detached task. With Settings -> Features open, each redraw (also from a Drop Mode switch) reads each provider key once per pass instead of about 150 times, which removed the owner's one-second delay.
status: confirmed
tags: [island, hover, drop-mode, animation, backup, keychain, performance]
canonical_for: [drop-mode-switch-motion]
verified_at: 2026-11-28
sources:
  - type: user-confirmed
    reference: On 2026-11-27, with PR #519 installed (build 1787), the owner reported that switching between Smart and Fast still lags; the orchestrator asked for a measured cause and fix (task 96, second round).
    confirmed_at: 2026-11-28
  - type: repository
    reference: Sources/Sidekey/DynamicIsland/IslandView.swift
    confirmed_at: 2026-11-28
  - type: repository
    reference: Sources/Sidekey/Backup/BackupViewModel.swift
    confirmed_at: 2026-11-28
  - type: user-confirmed
    reference: On 2026-11-28 the owner tested preview build 1794 with this change and reported that the mode changes about a second after the click; the orchestrator asked for the cause in the real app path.
    confirmed_at: 2026-11-28
  - type: repository
    reference: Sources/Sidekey/AIRouting/ProviderKeyStore.swift
    confirmed_at: 2026-11-28
  - type: repository
    reference: Sources/Sidekey/Settings/Features/FeaturesEnvironment.swift
    confirmed_at: 2026-11-28
related: []
---

# The Smart/Fast switch has its own scoped animation

## Context

After the hidden Settings model stopped rereading keys
(2026-11-27-settings-models-recompute-while-hidden.md), the owner still saw a
laggy Smart/Fast switch. Measurements on origin/main with the real island
mounted offscreen (never shown), clicked through the window-level hit bridge
and captured frame by frame, plus the real settings capture:

- Click path on the main thread: mouse-up handler 0.5 ms; first layout after
  the switch 7.1-7.6 ms median (a plain tile: 3.5-3.7 ms). Small; not a
  visible delay on its own.
- The visible switch was not an animation of its own. The ON Smart/Fast status
  in the island's right band appeared with zero intermediate frames in every
  round (a hard cut, while the hint orbs vanished the same way). The symbol
  only crossfaded when the tile's press-release spring carried it: a hotkey
  switch cut it, and in one 8-tool layout the third click cut it in both quiet
  runs.
- 600 ms after every preference write, `BackupViewModel` captures settings
  history on the main actor, reading every provider key (about 10 accounts)
  from the Keychain: 15.6-17.6 ms main-thread blocks (12-26 ms in noisier runs)
  after each switch, which lands in the next switch when toggling back and
  forth.

## Decision

- `IslandView.switchDropMode` sets the mode and status for clicks and the
  hotkey alike. The motion is scoped: the tile symbol uses
  `.contentTransition(.symbolEffect(.replace))` with
  `.animation(_, value: systemImage)`, and the right band animates on
  `dropModeStatus` with its existing opacity and scale transition. Both use
  `IslandDropModeControl.switchAnimation`: 0.3 s smooth, `nil` with Reduce
  Motion.
- `BackupViewModel.readCredentials` reads the capture's provider keys in a
  detached task. Capture timing, contents and the "unreadable key fails the
  capture" rule are unchanged.

## Why

The perceived lag is a switch that partly cuts and partly animates, and a
main-thread stall that hits repeated switching. A transaction around the
whole island (`withAnimation` over `dropMode`) was measured too: it animates
correctly but raised the first layout to 10.1 ms median (13.2 ms max); the
scoped version stays at 8.0-8.3 ms. Settings history must still save changes
immediately (2026-10-21-backup-capture-pacing.md), so the capture was moved
off the main thread rather than delayed.

## What was tested

- After the change, frame captures show the symbol changing through 7-17
  intermediate frames and the status through 7-9 (about 0.4 s) in every round;
  the capture left no main-thread gap over 6 ms (before: 15.6-17.6 ms) and
  still saved one settings version per switch.
- `IslandDropModeSwitchMotionTests` (click rounds and the hotkey) and
  `BackupCaptureMainThreadTests` fail on origin/main (status 0 intermediate
  frames in 3 of 3 rounds, hotkey symbol cut, 30 Keychain reads on the main
  thread) and pass with the change.

## Rejected

- One `withAnimation` over the whole island: more layout work on the first
  frame for no visible gain.
- A longer capture debounce: settings history saves changes immediately.
- Leaving the symbol to the press spring: the hotkey and some clicks cut it.

## Round 3: the one-second delay was Settings -> Features

In preview build 1794 the owner saw the switch "about a second after the
click". The offscreen island did not reproduce it; the running app did, read
only:

- The unified log of the running process showed 8,942 `SecItemCopyMatching`
  calls in 6.5 minutes, 8,682 of them on the main thread, in bursts of 250-350
  per second lasting 2-15 s, one read every 2-3 ms, while the owner used the
  island.
- macOS's spin report from the owner's test (`Sidekey_2026-11-28-021708.spin`,
  0.5 s) put the main thread in `SettingsFeaturesView.body` ->
  `snapshot` -> `FeatureSetupSnapshot.live` -> `APIAndModelsViewModel.sections(for:)`
  -> `ModelStatusResolver.sections` -> `KeychainStore.read` (38 of 51 samples),
  plus `APIAndModelsViewModel.recompute` key reads.

The Settings window was open on Features. That view rebuilds its snapshot in
`body`, on `sidekeyDropModeChanged` among others, and the snapshot asked every
feature's sections twice, each reading every provider key again. Mounted
offscreen with six keys at a measured 1.2 ms per read, one Drop Mode switch
cost 150 main-thread Keychain reads and a 243 ms block; the live app, with
loaded catalogs and repeated redraws, took about a second.

`ProviderKeyStore.withLookupPass` now remembers each account's answer for the
duration of one synchronous pass (shared by the copies the view model and its
resolver hold, forgotten on save/delete and when the pass ends). The Features
snapshot builds each feature's sections once inside one pass, and
`sections(for:)` and `recompute()` run in a pass. The same switch now reads 6
keys with a 20 ms block. `SettingsFeaturesKeychainTests` keeps a budget of 20
main-thread reads and a block under 100 ms; `ProviderKeyStoreLookupPassTests`
covers the pass rules.

Rejected: a cache of key answers that outlives one pass (a key changed by
Settings Sync or the plugin would show stale), and moving the snapshot off the
main thread (it reads main-actor view models).

2026-11-28, PR: see fix/drop-mode-toggle-lag.
