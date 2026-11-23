---
id: whytap-builder-queue-cheap-fixes-2026-11-23
type: decision
title: Moved PR heads return without a session, dependencies wait in place, a ticket can go back without a block
summary: Before claiming, the queue helper reads every PR head with git ls-remote and returns tickets whose head moved; --depends-on keeps a ticket in place until its dependency is merged through the queue; in_progress -> queued returns a ticket without blame and keeps its place.
status: confirmed
tags: [agents, queue, builder, watcher, dependencies]
canonical_for: [builder-queue-cheap-fixes]
verified_at: 2026-11-23
sources:
  - type: user-confirmed
    reference: On 2026-11-23 the maintainer approved the reduced builder-queue order; its third step is the cheap fixes from the council review (head check before a session, waiting for a dependency, return to the queue without a block), with the place-keeping priority column deferred.
    confirmed_at: 2026-11-23
  - type: repository
    reference: scripts/build-queue.py
    confirmed_at: 2026-11-23
  - type: repository
    reference: scripts/build-queue-watcher.py
    confirmed_at: 2026-11-23
related: [2026-11-19-on-demand-build-queue-builder.md, 2026-11-23-builder-queue-watchdog.md, 2026-11-23-builder-queue-flaky-tests.md, ../processes/shared-app-development.md]
---

# Cheap queue fixes: moved heads, dependencies, returns without a block

## Context

Of 94 blocks from 2026-11-20 to 2026-11-23, about 20 said only that the PR
head moved after submission (the author pushed again) and about 10 that a
dependency or overlapping PR was not merged yet. Each cost a builder session:
a model read the queue, fetched the PR and wrote the block. A ticket stopped
by the environment (ticket 461 under load 317) had no way back except through
`blocked`, which blames the PR and resets its place to the end of the queue.

## Decision

- `claim` reads every PR's current head with one `git ls-remote <remote>
  'refs/pull/*/head'` before its transaction. A queued ticket whose PR head
  differs is `blocked` with the new SHA and a request to enqueue it; the next
  ticket is claimed. The watcher runs the same check (`check-heads`, as the
  builder) before it starts a session for queued work, so a moved head costs
  no session. An unreachable remote checks nothing. Only tickets queued
  before the read started are judged (a later one may be newer than the
  snapshot), and a pull ref that still shows an ancestor of the submitted
  commit is GitHub updating late, not a move. The return's event is marked
  for delivery, so `events --pending` lists it for Claude Code authors as
  well as Codex ones until the next builder delivers and acknowledges it.
- `enqueue --depends-on <PR URL>` (repeatable) records dependencies. The
  ticket keeps its place, `claim` skips it and the watcher starts no session
  for it until the latest ticket of every dependency PR is `done` or
  `pending_install`. Self-dependencies and direct cycles are refused.
- `set --status queued` is allowed from `in_progress` and keeps the ticket's
  `queued_at`; a requeue after `blocked` still goes to the end. The watcher's
  progress fingerprint takes a queued ticket's `queued_at`, not its update
  time: a returned ticket counts as a session without progress and its
  backoff applies, while a retry after a block has a new `queued_at` and
  resets it.

## Rationale

All three are decided by data the queue already has or a single unauthenticated
Git read, so they need no model and no new state. The new column has a default
and older helpers ignore it (checked: an older helper enqueues and claims on
the migrated database, and would claim a ticket regardless of its
dependencies, so the features start with `activate`); the new transition only
widens what the builder may do. Keeping the place of a returned ticket is fair because nothing was
wrong with it, while the backoff prevents a loop of sessions that return the
same ticket.

## Alternatives

- A `waiting_dependency` status: clearer in `status`, but every older helper
  and the watcher's index would need to know it; a skipped `queued` ticket
  needs no new state.
- Checking the head through the GitHub API (`gh`): needs credentials in the
  launchd process; `ls-remote` of the public pull refs does not.
- Listing every unacknowledged Claude Code event in `events --pending`: 314
  historical ones would reach their authors again; only model-free returns
  are marked for delivery.
- The `priority_at` column that keeps a resubmitted PR's place: deferred by
  the council review until the effect of these fixes is measured.

2026-11-23
