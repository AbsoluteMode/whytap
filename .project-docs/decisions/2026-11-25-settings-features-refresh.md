---
id: settings-features-refresh-2026-11-25
type: decision
title: Settings -> Features rebuilds its snapshot only when what it shows changes
summary: The Features snapshot reads every provider key on the main thread. A Notify registry reread every 2 s republished an unchanged list and rebuilt it, so Whytap's main thread, and the island's live dictation wing with it, froze about 0.6-0.75 s every few seconds. The view now reacts only to changed Notify and Monitor counts, and the supervisor publishes only changed values.
status: confirmed
tags: [settings, features, performance, main-thread, notify, monitor, island, dictation]
canonical_for: [settings-features-snapshot-refresh]
verified_at: 2026-11-25
sources:
  - type: repository
    reference: Sources/Sidekey/Settings/Features/SettingsFeaturesView.swift
    confirmed_at: 2026-11-25
  - type: repository
    reference: Sources/Sidekey/Settings/Features/FeaturesEnvironment.swift
    confirmed_at: 2026-11-25
  - type: repository
    reference: Sources/Sidekey/Notifications/NotifyScriptSupervisor.swift
    confirmed_at: 2026-11-25
  - type: repository
    reference: Sources/Sidekey/Monitor/MonitorStore.swift
    confirmed_at: 2026-11-25
  - type: repository
    reference: Tests/SidekeyTests/Settings/SettingsFeaturesRefreshTests.swift
    confirmed_at: 2026-11-25
related: [2026-11-24-settings-around-features.md]
---

# Settings -> Features rebuilds its snapshot only when what it shows changes

## Context

The user reported in build 2.2.27 (1752) that the island's right wing (the live dictation
text) stuttered while the rest of the Mac stayed smooth. Restarting Whytap did not help.

## Decision

- `SettingsFeaturesView` listens to `FeaturesEnvironment.snapshotCountChanges` instead of the
  raw `NotifyScriptSupervisor.$sources` and `MonitorStore.$dashboards` publishers. The snapshot
  reads only their counts, so only a changed count bumps `externalChange`.
- `MonitorStore` publishes its available-dashboard count after completing a local reload.
  It includes saved dashboards and Server status when configured and readable. The Features
  snapshot uses this same count.
- `NotifyScriptSupervisor.reconcile` and its loop publish `sources` and `error` only when the
  value differs.

## Why

`FeatureSetupSnapshot.live` runs in the view's `body` on the main thread. It resolves the
model picker for every feature, which reads each provider key from the Keychain (the legacy
file keychain decrypts every item) and formats catalog prices through ICU. One pass took
roughly 0.4–0.75 s on the user's Mac.

whytap#461 subscribed the view to `$sources` and `$dashboards`. The Notify supervisor
rereads its folder every 2 s and assigned `sources` each time, even when nothing changed.
Each `@Published` assignment emitted, so the snapshot was rebuilt each time. The Settings
window keeps its SwiftUI graph alive after it is closed, so the stall did not need the window
on screen. The whole app's main thread, including the island, stopped for ~0.6–0.75 s every
~4 s. Dictation is where this is visible, because the wing animates every frame.

## What we tested

Measured in the running build 1752 with `sample` (read-only; the app was not restarted):

- While dictating, 7 s at 1 ms: the main thread was busy for ~2,000 of 4,147 samples, and
  1,723 of those were in `SettingsFeaturesView.body` → `FeatureSetupSnapshot.live` →
  `ModelStatusResolver.sections`. The busiest leaves were 920 samples in `KeychainStore.read`
  and 455 in `catalogPriceLabel`.
- Without dictation, 5 s: 1,475 of 3,506 main-thread samples were in the same `body`. Twelve
  consecutive 1 s windows showed 456/296/0, 460/246/0, 471/131/0 and 414/3/0 samples, a burst
  every ~4 s.
- Hypotheses ruled out:
  - **Network.** The recorded ElevenLabs take has a median partial gap of 0.31 s (p90 0.40 s,
    max 1.19 s), within the ticker's 1.4 s pacing reserve.
  - **The ticker.** Its frame costs 0.50 ms at the median and 0.79 ms at p99 over the
    recorded take at 120 fps, with 260 wing-width publishes over 44 s.
  - **whytap#454's `drop_live`.** With no client opted in it is a single nil check per
    partial, with no timer.
- The original three `SettingsFeaturesRefreshTests` failed with eight assertions on the previous
  implementation. They pass with this change, including a running supervisor with an installed
  source that stays quiet for 2.6 s.
- In an isolated Monitor store, adding, breaking, repairing and removing the only Server
  status board updates the snapshot once per change. Repeated valid and invalid configurations
  with the same available count stay quiet.

## Rejected

- **Caching key lookups in `ModelStatusResolver`.** This would make every pass cheap, but it
  needs a correct invalidation for keys saved, deleted or refused elsewhere. It is a separate
  change.
- **Tearing down the Settings content when the window closes.** This would hide the cost only
  while the window is closed. An open window would still stall the app.
- **Debouncing `externalChange`.** This would still rebuild the snapshot every few seconds for
  nothing.

2026-11-25 · branch `fix/settings-features-refresh-pulse`
