---
id: settings-models-recompute-while-hidden-2026-11-27
type: decision
title: The Settings Models model does not recompute while the Settings window is closed
summary: APIAndModelsViewModel, kept by SettingsWindowController for the app's whole life, used to reread every provider key from the Keychain on the main thread 100 ms after any UserDefaults write, which put a 30-40 ms stall into the island's Drop Mode switch animation. While the window is closed a defaults change now only marks the model stale; showing the window recomputes it once before the first frame.
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
related: []
---

# The Settings Models model does not recompute while Settings is closed

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
is ordered front. While not presented, a defaults change only marks the model
stale; `setPresented(true)` recomputes once, synchronously, if anything changed.
Other owners (onboarding, the app control plugin) never call it and keep the
old behavior. Explicit actions in the model that call `recompute()` themselves
are unchanged.

## Why

Nothing draws the model while the window is closed, so the work had no user
benefit, yet it blocked the main thread during island animations. Recomputing
on show keeps the first frame of Settings current, including keys or routes
that changed meanwhile (Settings Sync, the app control plugin).

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
  up-to-date model on show, no recompute on show without changes, live updates
  while open, and the unchanged default for other owners.

## Rejected

- Caching key lookups for the whole app: a key changed by Settings Sync or the
  plugin could show stale state; the reads are only wasted while hidden.
- Restricting the observer to some defaults keys: routes, catalogs, languages
  and key status live in many keys and stores; a missed key is a stale screen.
- Adding an explicit symbol animation to the tile instead: it would not remove
  the stall that interrupts the animation.

2026-11-27, PR: see fix/drop-mode-tile-animation.
