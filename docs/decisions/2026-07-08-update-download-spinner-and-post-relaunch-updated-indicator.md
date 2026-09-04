# Update UX: download spinner + post-relaunch "Updated" indicator

Date: 2026-07-08
Status: accepted

## Context

Founder feedback on the Dynamic Island update flow:

> "When you click Install (the arrow) — show a loader, a nice spinning wheel
> while the download runs; once it downloads and updates — a small
> checkmark/'Updated' that disappears after 5 s or on click."

The existing flow (invariant #5, download-on-action, one-button auto-install +
relaunch) had two gaps:

1. The `.downloading` stage showed a **static** `arrow.down.circle` icon in the
   ~70 pt right band — no motion, so it read as "stuck" rather than "working".
2. There was **no confirmation** after an update applied. The app just
   relaunched into the new version silently.

## Decision

### Part 1 — download spinner

Replace the static `.downloading` icon with a continuously-rotating spinner.

**A Core Animation (render-server) rotation, NOT a SwiftUI
`.animation(.repeatForever)`.** New file `IslandUpdateSpinner.swift`
(`NSViewRepresentable` + `UpdateSpinnerMarkView`) rotates an
`arrow.triangle.2.circlepath` glyph via `CABasicAnimation` on
`transform.rotation.z`, `repeatCount = .greatestFiniteMagnitude`.

Why render-server, not SwiftUI: this is the exact same constraint already
documented on `IslandProviderBreathingIcon`. SwiftUI animations advance
frame-by-frame on the main thread, and the spinner appears precisely while the
main thread is busy — Sparkle is downloading + extracting, and every progress
chunk mutates `AppState.updateAvailable` (`@Published`) and re-renders the
island. A SwiftUI `.repeatForever` visibly stutters through those stalls; a
CALayer animation keeps spinning on the render server. `ProgressView(.circular)`
is doubly wrong here (SwiftUI-driven AND a system indicator that does not scale
cleanly to a 13.5 pt white glyph in a non-key panel).

The spinner is indeterminate (a turning wheel), matching the founder's ask.
A determinate ring with a percentage does not fit the narrow band and was not
requested. `.downloading` stays icon-only, no hover actions — unchanged.

### Part 2 — post-relaunch "Updated" indicator (variant A)

The founder chose **variant A**: show the "updated" confirmation in the NEW
binary AFTER relaunch. This preserves the one-button auto-install + relaunch
(no second "Restart now" click is introduced).

Flow:

1. `UpdateController.applyDriverStage(.readyToInstall)` persists a marker
   (`sidekey.update.justInstalledBuild` = `CFBundleVersion`,
   `sidekey.update.justInstalledVersion` = display version) **before**
   `installAction()` — install may terminate the app immediately.
2. On the next launch, after the island panel is on screen,
   `UpdateController.showJustInstalledIndicatorIfNeeded()` →
   `JustUpdatedIndicator.checkAndShow()` reads the marker:
   - marker build **==** running `CFBundleVersion` → the update really applied →
     publish `AppState.justUpdatedVersion`; `IslandJustUpdatedPill` renders a
     ✓ + "Updated" in the right band; auto-hides after 5 s
     (`JustUpdatedIndicator.autoDismissDelay`) or on tap.
   - marker build **!=** current (rollback / stale / different build) → show
     nothing.
   - The marker is **always** consumed after the check (one-shot); it never
     re-fires on a later launch.

#### Why a separate `AppState.justUpdatedVersion` field, not a `PendingUpdate.Stage` case

`PendingUpdate` models an **in-flight Sparkle update** and carries
`download` / `skip` / `dismiss` closures plus a build identity used for
idempotency (`handleDiscovered` dedups on `buildVersion`). A `.justInstalled`
stage would be a closure-free, identity-less case bolted onto that type — it
would muddy `Stage`'s "closures live on the case" invariant and risk the
discovery/idempotency logic. The "Updated" indicator has a fundamentally
different lifecycle (post-relaunch, self-dismissing, no download/skip), so it
lives in its own `@Published` field + its own view (`IslandJustUpdatedPill`).

#### Why "Updated" (word) and not "Updated vX.Y"

The ~70 pt right band cannot fit a version alongside the checkmark (same reason
`.downloading` is icon-only and free-tier shows "Limit"). The visible pill is
✓ + "Updated"; the version rides in the accessibility label only.

#### Idle-hide blocker

`IslandJustUpdatedPill` is added as idle blocker **B13**
(`IslandIdleBlockers.justUpdatedVisible`, invariant #5). Its own 5 s timer
normally hides it well before the 20 s idle timeout, but holding the island
`.active` while it is up guarantees idle-hide can never race it away early.

## Invariant #5 — untouched

This is a cosmetic island indicator, **not** a Sparkle window and **not** a
modal. The update still installs + relaunches from the single ↓ click
(`automaticallyDownloadsUpdates = false`, download-on-action). Invariant #5's
text ("no Sparkle windows; no modal; download-on-action; one-button
auto-install") remains true; the post-relaunch confirmation is an additive
island surface, so the invariant wording was extended with a single clause
rather than changed.

## Alternatives rejected

- **SwiftUI `ProgressView(.circular)` / `.repeatForever` rotation** — stutters
  through download-time main-thread stalls (see Part 1).
- **Variant B (show "Updated" before restart, gated behind a manual "Restart
  now")** — would reintroduce a second click and break one-button install.
- **`.justInstalled` case on `PendingUpdate.Stage`** — pollutes the in-flight
  update model (see Part 2).
