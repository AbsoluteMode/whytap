---
id: settings-models-recompute-while-hidden-2026-11-27
type: decision
title: The Settings Models model does not recompute while the Settings window is closed
summary: APIAndModelsViewModel, kept by SettingsWindowController for the app's whole life, used to reread every provider key from the Keychain on the main thread 100 ms after any UserDefaults write, which put a 30-40 ms stall into the island's Drop Mode switch animation. While the window is closed, defaults and Tavily key notifications do nothing; showing the window always recomputes once, synchronously, before the first frame and takes over any pending debounced pass.
status: confirmed
tags: [settings, models, keychain, island, animation, performance]
canonical_for: [settings-models-hidden-recompute]
verified_at: 2026-11-27
sources:
  - type: user-confirmed
    reference: On 2026-11-27 the owner reported that the island's Drop Mode tile, which used to animate its icon smoothly between Smart and Fast, now stutters; the orchestrator relayed it as task 96.
    confirmed_at: 2026-11-27
  - type: repository
    reference: Sources/Sidekey/Settings/APIAndModels/APIAndModelsViewModel.swift
    confirmed_at: 2026-11-27
  - type: repository
    reference: Sources/Sidekey/Settings/SettingsWindowController.swift
    confirmed_at: 2026-11-27
related: [2026-11-27-agent-harness-cli.md]
---

# The Settings Models model does not recompute while Settings is closed

> Superseded 2026-11-27: Tavily removed; a Tavily key change no longer refreshes Keys & models. See [the agent harness](2026-11-27-agent-harness-cli.md).

## Context

Clicking the island's Drop Mode tile writes the mode to UserDefaults
(`UserPreferencesCache.setMode`). The icon change (bolt to sparkles) has no
animation of its own: it crossfades inside the tile's press-release spring,
about 0.2 to 0.3 s. `SettingsWindowController` is created at launch and keeps
an `APIAndModelsViewModel`, which observes every `UserDefaults` change with a
100 ms debounce and then runs `recompute()` on the main thread. That pass
reads each provider key (plus Tavily) from the Keychain without a cache, so it
lands in the middle of the switch animation.

## Decision

The model has `setPresented(_:)`. `SettingsWindowController` sets it to false
at creation and when the window closes, and to true in `show` before the window
is ordered front. While not presented, `UserDefaults.didChangeNotification` and
`whytapTavilyKeyChanged` do nothing. Becoming presented always recomputes once,
synchronously, and cancels a pending debounced pass. While presented, a
defaults burst still collapses into one pass 100 ms after the last write (an
explicit `DispatchWorkItem` instead of a Combine debounce, so the pending pass
can be cancelled), and a Tavily key change applies immediately. Other owners
(onboarding, the app control plugin) never call `setPresented` and keep the
old behavior. Explicit actions that call `recompute()` themselves are
unchanged.

## Why

Nothing draws the model while the window is closed, so the work had no user
benefit, yet it blocked the main thread during island animations. A "stale"
flag set by notifications is not enough to know when to refresh: a Settings
Sync round with only credentials (provider keys or a user server's key) and
the app control plugin change keys without writing any preference, and the
first version of this change, which marked staleness only after the debounce,
showed an outdated first frame when Settings opened within 100 ms of a write
and could run a second pass after opening (builder review of ticket 688).
One unconditional pass per opening costs about as much as one island write
did before, at a moment with no animation in flight.

## What was tested

- An offscreen mount of the real island, clicking the Drop Mode tile through
  the window-level hit bridge, captured frame by frame: the tile's
  layout/render cost and the icon crossfade were identical at `fafaeaf0^`
  (before hover reorder) and at current main (layout about 7 ms per switch),
  so the island's own SwiftUI code did not regress.
- With a full set of provider keys, one defaults write caused 25 Keychain
  reads in `recompute()` on current main and 16 before the 2026-11-22 Models
  changes (shared rows, Search row, audio-translate slot). A real login
  Keychain read measured about 1.2 ms median (25 reads: about 40 ms, single
  reads up to 11 ms).
- `APIAndModelsPresentationTests`: no Keychain read while hidden, a synchronous
  up-to-date model on show (also within the debounce), one pass per opening
  with a pending burst taken over, credential-only Settings Sync additions and
  removals while closed, a route and key changed together, Tavily save/remove
  deferred while closed and immediate while open, live updates while open, and
  the unchanged default for other owners.

## Rejected

- Refreshing on open only when a notification marked the model stale:
  credential-only changes post no preference notification.
- Caching key lookups for the whole app: a key changed by Settings Sync or the
  plugin could show stale state; the reads are only wasted while hidden.
- Restricting the observer to some defaults keys: routes, catalogs, languages
  and key status live in many keys and stores; a missed key is a stale screen.
- Adding an explicit symbol animation to the tile instead: it would not remove
  the stall that interrupts the animation.

2026-11-27, PR: see fix/drop-mode-tile-animation.
