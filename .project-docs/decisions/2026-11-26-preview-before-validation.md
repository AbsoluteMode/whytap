---
id: whytap-preview-before-validation-2026-11-26
type: decision
title: The owner checks a preview of the feature first; review, full suite and merge follow his approval
summary: A preview lane builds main plus the PRs awaiting the owner's check as a local arm64 app, runs only the safety checks and installs it under the usual gates beside validation work; approval moves a PR to validation, which keeps its place, reviews cheapest first and merges. Local installs drop the x86_64 slice and the DMG; public releases do not change.
status: confirmed
tags: [agents, queue, builder, watcher, preview, approval, packaging]
canonical_for: [builder-preview-lane, local-arm64-install]
verified_at: 2026-11-26
sources:
  - type: user-confirmed
    reference: On 2026-11-26 the owner approved, after the release-cycle council, review and cheap probes before the full suite, block without the suite, a reproducing check per finding, stacked PRs waiting for their parent, priority for resubmission after a block (at most twice), an open-only status, the return of tickets whose dependency stays blocked for over two hours, review, tests and merge behind a locked screen, and an arm64-only local install without a DMG (in his words: do all three, as long as testing and reviewing get faster).
    confirmed_at: 2026-11-26
  - type: user-confirmed
    reference: On 2026-11-26 the owner set the order preview first, tests after approval ("I have to review the FEATURE itself — that it satisfies user scenarios and nothing lags. For that I don't need tests. Tests can be done after I approve the feature"), and that the builder does no code review before his approval either; the target is minutes from a worker's push to the fix running in his app.
    confirmed_at: 2026-11-26
  - type: repository
    reference: scripts/build-queue.py
    confirmed_at: 2026-11-26
  - type: repository
    reference: scripts/build-queue-watcher.py
    confirmed_at: 2026-11-26
  - type: repository
    reference: scripts/build-dmg.sh
    confirmed_at: 2026-11-26
related: [../processes/shared-app-development.md, 2026-11-23-builder-queue-cheap-fixes.md]
---

# Preview before validation

## Context

The release-cycle council (2026-11-26) measured that the single builder spent
about half of its time on attempts that ended in a return to the author: in 13
of 15 checked blocks a green full suite (8 to 10 minutes) ran just before the
block. Resubmissions went to the end of FIFO, `status` printed about 600
tickets into every session, a ticket could wait days behind a blocked
dependency, a locked screen stopped everything although only two
protected-data tests, signing and the install need it, and every local
install compiled an x86_64 slice and a DMG nobody uses on this Mac (packaging
of ticket 622: about 7.8 minutes, two whole-module compiles of `Sidekey`).

The owner's own pain is the loop of small fixes ("this window lags", "this
should look different"): each one waited for review, the full suite, the merge
and an install, often hours. He checks the feature itself; tests and code
review can follow his approval.

## Decision

Two lanes share the queue.

- **Preview lane** (owner's check first). A worker submits a reviewed head with
  `enqueue --preview` after its own branch build and targeted tests. A second
  LaunchAgent (`run-preview`, enabled by `activate --preview-lane`) starts a
  short preview session beside a running validation session, with its own
  lock, state and warm worktree (the `preview_worktree` beside the integration worktree). It never
  reviews, runs the full suite, merges or pushes. `preview-claim` gives the
  ticket and the **train**: every PR installed for the owner and still
  awaiting approval. The session composes a local commit of `origin/main` plus
  the train heads plus the ticket's head, builds a local arm64 app
  incrementally, runs the safety checks below, installs it under the meeting
  gate and `whytap-app.lock`, and records `awaiting_approval`.
- **Approval.** The orchestrator relays the owner's words: `approve --ticket
  <id> --by "<owner's words>" --actor <orchestrator>` moves the ticket to the
  validation lane (`lane: approved`) at its original place. `reject --ticket
  <id> --note "<what to change>"` returns it to its author and marks the
  train for a rebuild without it. The PR's own session and the builder cannot
  relay a decision. A fix to a preview (`enqueue --preview` with the new head)
  replaces it and keeps its place, also while the old preview is still being
  built.
- **Validation lane** (after approval, and for PRs submitted without
  `--preview`). Cheapest first: review, probes, documentation checks and
  `swift test --filter` of the touched classes; a blocking finding blocks
  without the full suite and comes with a reproducing check for its whole
  class that the author adds to the PR. A stacked PR waits for its parent.
  The full suite runs only for a merge candidate. Then the merge, and the
  regular install, which also carries the current train so the owner's
  previews do not vanish.
- **Safety checks that never skip**, also for a preview: the compile;
  strict signature, Developer ID team and the installed app's designated
  requirement; bundle ID; `arm64` app and helper; a higher `CFBundleVersion`
  and no lower display version; the native `--installation-check`; the
  meeting/activity gate before a normal Quit (never force-quit), from a
  pristine `origin/main` copy; one running instance with the new identity and
  a smoke check; a known-good main-based bundle kept for rollback in
  a `known-good` folder beside the builder's worktrees. A PR that touches stored data, migrations,
  permissions, Keychain, signing, entitlements, packaging, updates or the
  queue itself (path guard `PREVIEW_UNSAFE` in the helper, conservative on
  purpose: about 10% of source files) gets no preview: `preview-claim` moves
  it to the validation lane with the matched paths.
- **Receipt.** the local build/CURRENT_BUILD.md receipt gets a section **Preview, not
  merged**: build, source commit, main base, every PR of the train with its
  head and acceptance steps, the rollback path. A preview is never reported
  as merged or as verified running main.
- **Queue fixes from the council.** A resubmission after a block keeps the
  PR's earlier place at most twice (`resubmits`). `status --open` lists open
  work and the earlier tickets of the same PRs only, with long closed notes
  shortened. The watcher returns a queued ticket whose dependency has been
  blocked or cancelled for over two hours (`stale_dependency_minutes`),
  without a model. A locked screen no longer stops validation sessions
  (`validate_while_locked`); `environment --for suite` ignores the lock; the
  two protected-data tests, signing and every install wait for the unlock,
  and a merge made behind the lock records them as pending.
- **Local arm64 install.** `EXODIA_LOCAL_INSTALL=1 ./scripts/build-dmg.sh`
  builds and signs the arm64 app only, marks it `ExodiaLocalBuild`, runs the
  same signature and installation checks and writes a local manifest
  (`build/Whytap-<version>-build<n>-local-arm64.json`) instead of a DMG and
  a release manifest. It refuses notarization and the legacy mode, and
  `user-release.sh` refuses it for any upload. Public releases stay universal
  with a DMG and full provenance.

## Rationale

The owner judges scenarios, looks and lag in the running app; tests and code
review do not answer that, so putting them first made him wait hours per
fix. Running them after approval keeps every gate for what reaches main, and
the safety checks keep what reaches his app from harming data, permissions
or the signing identity. A separate lane with its own lock and worktree is
what lets a preview run while a validation session is inside an 8-minute
suite; one app lock keeps both lanes from replacing the app at once. The
train makes several previews coexist and is rebuilt from main whenever its
membership changes, so a rejected PR leaves the app at the next build.

Expected time per small fix, from the worker's enqueue to the fix running:
about 5 to 7 minutes with the preview session (watcher reaction up to a
minute, session start and composition 1 to 2, the incremental arm64 release
build about 2.5 to 3 because a release build recompiles the whole `Sidekey`
module, checks and the handoff about 1), assuming no meeting defers the
Quit. A model-free preview runner is the next step and would save the
session's 1 to 2 minutes. A validation install drops from about 7.8 minutes
of packaging to about 3.

## Alternatives

- Debug or non-WMO preview builds: faster compiles, but performance differs
  from the shipped app and the owner checks lag. Rejected.
- Previews without the path guard, relying on workers to declare data
  changes: a wrong declaration could corrupt the owner's data before any
  review. Rejected.
- Merging previews to main before approval (merge train): main would carry
  unaccepted work, and the council already rejected merge trains. Rejected.
- A second builder for previews sharing the integration lock: previews would
  again wait behind full suites. Rejected in favour of the app lock.
- Universal local installs: they carry an x86_64 slice and a DMG that this
  Mac never uses. Rejected for the local path only.

2026-11-26
