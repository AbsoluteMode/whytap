---
id: whytap-release-batches-2026-11-26
type: decision
title: Approved features accumulate and go out together as one release batch
summary: The owner's approval no longer starts per-PR validation; approved features stay in his app and wait for a release batch, started by the orchestrator's "release" or an optional count trigger, which gets one review, one full suite with bisection of failures, ordered merges and one install. Decisions are relayed only by a token-bound orchestrator for the exact head and build he saw.
status: confirmed
tags: [agents, queue, builder, watcher, preview, release, approval]
canonical_for: [builder-release-batches]
verified_at: 2026-11-26
sources:
  - type: user-confirmed
    reference: On 2026-11-26 the owner asked for two explicit stages, a fast product preview so he sees whether a feature is what he asked for, and approved features accumulating to go out together as one release with one code review, one full suite, merge and one build instead of per-PR validation after each approval.
    confirmed_at: 2026-11-26
  - type: user-confirmed
    reference: On 2026-11-26 the orchestrator, within the owner's approval, bound approve and reject to the orchestrator actor, kept the conservative preview path filter, assigned the stale public-release tickets to the builder and asked for short builder notes.
    confirmed_at: 2026-11-26
  - type: repository
    reference: scripts/build-queue.py
    confirmed_at: 2026-11-26
  - type: repository
    reference: scripts/build-queue-watcher.py
    confirmed_at: 2026-11-26
related: [2026-11-26-preview-before-validation.md, ../processes/shared-app-development.md]
---

# Release batches

## Context

With previews first (see the
[preview decision](2026-11-26-preview-before-validation.md)), each approval
still started a review, a full suite of about ten minutes, a merge and an
install for that one PR. The owner wants two stages: a preview that answers
"is this what I asked for" within minutes, and then one release for everything
he approved. The builder's review of the first version (ticket 626) also found
gaps: a filename-only admission, decisions not bound to what the owner saw, a
boolean rebuild flag that could lose a later decision, stacked previews
surviving their rejected parent, a fix's priority place judged against an
older head snapshot, activation able to interrupt a live preview, previews
installing main while merged work waited for its own install, and stranded
submissions when the lane is off.

## Decision

- `approve` marks a preview `approved`. It stays in the owner's app (the
  preview train includes `approved` and release members) and waits.
- `release --by "<owner's words>"` from the orchestrator, or the watcher's
  optional `release_after_approved` count (off by default), moves every
  approved feature into one batch. `claim` hands the whole batch to the
  builder in merge order (a member after the members it depends on); a member
  that needs a PR outside the batch stays `approved` for the next one.
- The builder composes main plus the batch, runs one review and attributes
  each finding to the member that introduced the lines, runs one full suite,
  bisects a real failure over the ordered members with only the failing
  tests, blocks the culprit (its stacked members leave the train with it),
  reruns the suite once on the rest, merges the members one by one, checks
  that main's tree equals the tested tree and installs once, carrying the
  previews still awaiting the owner.
- Decisions (`approve`, `reject`, `release`) come only from the orchestrator
  configured by `activate --orchestrator <id> --orchestrator-token-file
  <path>`, proved with that token (the queue stores its SHA-256), and
  `approve`/`reject` name the exact head and preview build the owner saw.
  This protects against other local sessions, not against a process running
  as the same user that reads the token.
- Preview admission fails closed for the whole composition: only app
  sources, ordinary resources, tests and documentation are in scope; the path
  guard and a scan of the changed lines (defaults, Keychain, coding formats,
  SQLite, Application Support files, permissions, updates) send a PR to
  normal validation; unknown is never admissible.
- The installed composition is recorded (`installed_preview`); a rebuild is
  needed exactly when the app carries a member that left the train unmerged
  or lacks a current member. A recording that is no longer the current train
  is refused, and `preview-current` rechecks the composition right before the
  Quit.
- Previews wait while any merged work waits for its install. A declined Quit
  or a permission prompt blocks the preview for a person. A fix pushed while
  its preview builds supersedes that build whatever its outcome. Moved-head
  checks use the submission time, not the FIFO place; a ticket returned
  without a model keeps its place without spending its resubmission priority.
- Activation and deactivation refuse while either lane runs, the app lock is
  held or a preview was interrupted; switching the lane off (or a submission
  while it is off) sends previews to normal validation.
- The watchdog raises `ready_to_check:<ticket>` for each preview awaiting the
  owner. The watcher keeps the builder notes to their last 120 lines above
  32 KB and the builder reads only the last 80.

## Rationale

The owner's time goes into the preview loop; the code gates exist for what
reaches main. Paying them once per release instead of once per approval saves
a full suite and an install per feature, and bisection over the approved set
keeps one faulty feature from holding the others back. Deriving the rebuild
from the recorded composition makes concurrent decisions safe without locks
between the orchestrator and the preview session.

## Alternatives

- Per-PR validation right after each approval: the previous design; one full
  suite and one install per feature.
- A time window as the only trigger: releases would start while the owner is
  still checking; kept as an option for later, the explicit "release" and the
  count trigger cover it.
- Bisecting with full suites: about ten minutes per step; the failing tests
  alone decide the culprit, and one full suite confirms the rest.
- Trusting an actor name alone for decisions: any session can type it.

2026-11-26
