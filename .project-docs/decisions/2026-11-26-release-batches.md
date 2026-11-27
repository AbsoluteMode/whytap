---
id: whytap-release-batches-2026-11-26
type: decision
title: Approved features accumulate and go out together as one release batch
summary: The owner's approval does not start per-PR validation; approved features stay in his app and wait for a release batch, started by the orchestrator's "release" or an optional count trigger, which gets one review, one full suite with bisection of failures, merges in a persisted order with each merge as a checkpoint, and one install. Decisions come only from a token-bound orchestrator that is never the builder, for the exact head and the build the owner's app is now.
status: confirmed
tags: [agents, queue, builder, watcher, preview, release, approval]
canonical_for: [builder-release-batches]
verified_at: 2026-11-26
sources:
  - type: user-confirmed
    reference: On 2026-11-26 the owner asked for two explicit stages, a fast product preview so he sees whether a feature is what he asked for, and approved features accumulating to go out together as one release with one code review, one full suite, merge and one build instead of per-PR validation after each approval.
    confirmed_at: 2026-11-26
  - type: user-confirmed
    reference: On 2026-11-26 the orchestrator, within the owner's approval, bound approve and reject to the orchestrator actor and kept the conservative preview filter; after the builder's review of ticket 628 it asked for all findings to be fixed, preferring simplicity.
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
would still start a review, a full suite, a merge and an install for that one
PR. The owner wants one release for everything he approved. The builder's
review of ticket 628 found that the batch order was lost on restart, a merged
member had no checkpoint, a release could pass an install boundary, the count
trigger could start a batch while switched off, the builder could be
configured as the owner's relay, and activation changed files before refusing.

## Decision

- `approve` marks a preview `approved`; it stays in the owner's app (the
  train) and waits. `reject` blocks it; the next preview session rebuilds the
  app without it.
- Decisions (`approve`, `reject`, `release`) come only from the orchestrator
  configured by `activate --orchestrator <id> --orchestrator-token-file
  <path>` and proved with that token (the queue stores its SHA-256). The
  orchestrator can never be the builder, and the builder's actor is refused
  as a relay. `approve`/`reject` name the exact head and the build the
  installed app is now, which must carry that head. This protects against
  other local sessions, not against a process of the same user that reads the
  token.
- `release --by "<owner's words>"` from the orchestrator, or
  `release --auto` from the watcher when `release_after_approved` is a
  positive number already reached (checked inside the release transaction;
  off by default), moves every approved feature into one batch with a
  persisted merge order (FIFO; previews are never stacked, so no member needs
  another). One batch at a time.
- `claim` hands the batch over only when no install boundary or local install
  is pending; work that changes nothing in the app is claimed meanwhile. An
  open batch is returned in its persisted order after any restart. A member
  whose head moved goes back to its author; the others go on.
- The builder composes main plus the batch, runs the documentation checks
  and one full suite (no code review: since 2026-11-28 the only review is the
  orchestrator's inquisition on the release candidate), bisects a real failure over
  the ordered members with only the failing tests, blocks the culprit and
  tests the rest once more, then merges member by member. Each merge is set
  `pending_install --install-first` at once: that status is the checkpoint a
  recovered session continues from. Main's tree must equal the tested tree;
  one install follows, carrying the previews still awaiting the owner.
- Activation and deactivation refuse while a batch or a preview is unfinished
  or the app lock is held, and check every orchestrator prerequisite before
  changing any file.

## Rationale

Paying the code gates once per release instead of once per approval saves a
full suite and an install per feature; bisection keeps one faulty feature from
holding the others back. Persisting the order and using the existing merged
status as the checkpoint makes a batch survive interruption without new
recovery state.

## Alternatives

- Per-PR validation right after each approval: one full suite and one install
  per feature.
- A time window as the only trigger: releases would start while the owner is
  still checking.
- Bisecting with full suites: about ten minutes per step.
- Trusting an actor name alone for decisions: any session can type it.

2026-11-26
