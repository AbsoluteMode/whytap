---
id: whytap-builder-quick-wins-2026-11-26
type: decision
title: Builder quick wins - cheap checks first, kept places, stale dependencies, locked-screen validation, arm64 local installs, short notes
summary: The builder blocks on review and cheap checks before the full suite; a fixed PR keeps its place twice; tickets behind a long-blocked dependency go back to their authors; review, tests and merges run behind a locked screen while protected-data tests, packaging and installs wait for the unlock with the skipped test names stored on the ticket; local refreshes build arm64 only without a DMG; builder notes keep their tail.
status: confirmed
tags: [agents, queue, builder, watcher, tests, packaging, locked-screen]
canonical_for: [builder-quick-wins]
verified_at: 2026-11-26
sources:
  - type: user-confirmed
    reference: On 2026-11-26 the owner approved the council's three builder speedups ("all three, as long as testing and review get faster"), relayed by the orchestrator as five items, and on the same day the orchestrator split them from the preview lane into their own change, including the one-time retirement of the stale public-release tickets 188 and 204.
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
related: [2026-11-23-builder-queue-flaky-tests.md, 2026-11-23-builder-queue-cheap-fixes.md, ../processes/shared-app-development.md]
---

# Builder quick wins

## Context

Builder logs from 2026-11-22 to 2026-11-26 show where a ticket's time goes: a
full suite of about ten minutes run before a review finding that blocked
anyway, fixed PRs queued behind newer work, tickets waiting for days behind a
dependency that stayed blocked, nothing done while the screen was locked, and
about eight minutes of packaging for two architectures plus a DMG that a local
refresh never uses. The builder notes had grown to the point that reading them
cost a noticeable part of each session.

## Decision

- Order of a ticket: review, probes, documentation checks and `swift test
  --filter` of the touched classes first. A blocking finding blocks without
  the full suite, with a reproducing check for its whole class. A stacked PR
  waits for its parent. The full suite is the acceptance gate of a merge
  candidate.
- A resubmission after a block keeps the PR's earlier FIFO place at most twice
  (`resubmits`); a return made without a model (moved head, blocked
  dependency, `auto_returned`) keeps it without spending that priority.
  Moved-head checks compare the submission time (`submitted_at`), because a
  kept place reuses an older `queued_at`.
- The watcher returns a queued ticket whose `--depends-on` PR has been
  blocked or cancelled for over two hours (`stale_dependency_minutes`).
- `status --open` lists open work and the earlier tickets of the same PRs, with
  long closed notes shortened.
- Locked screen (`validate_while_locked`, default on): the watcher starts
  sessions for queued work behind a locked screen when the load allows it;
  `environment --for suite` ignores the lock. A test skipped because protected
  data is unavailable is recorded on the ticket with `protected-pending`
  before the merge. A runtime ticket merged behind a lock or with pending
  tests waits as `pending_install --retry-install`; install sessions start
  only with an unlocked screen, run the recorded tests on main before
  packaging, and a failure holds the install. `done` is refused while tests
  are pending.
- Local refresh: `EXODIA_LOCAL_INSTALL=1` builds an arm64-only app without a
  DMG, with a local manifest of its source commit, refuses notarization,
  legacy mode and uploads, and refuses a build number not higher (or a display
  version lower) than the installed app's before compiling. Public releases
  are unchanged.
- The watcher keeps `whytap-builder-notes` at most 120 lines and half of
  `notes_max_bytes` (32 KB) once it is over that size, appending older lines to
  `whytap-builder-notes.old` (its newest megabyte). It trims only under the
  session lock and writes the archive first. The builder reads the last 80
  lines.
- Tickets 188 and 204, public releases left `pending_install` for a dropped
  second-Mac check, are retired once by the builder as its own recorded action,
  on the orchestrator's authorization, after checking the release and the
  installed build. Nothing depends on it.

## Rationale

Every item removes waiting without removing a gate. Review findings are found
in minutes; the suite still guards every merge. Only two tests and signing
depend on an unlocked screen, so the lock now defers exactly those, and the
skipped test names live in the queue rather than in a session's memory. The
x86_64 slice and the DMG exist for distribution; the installed app runs one
architecture and the same signature, identity and installation checks apply.

## Alternatives

- Merge only after the protected tests ran: keeps a locked Mac from merging,
  which the owner wanted to avoid.
- Unlimited place-keeping for fixes: a PR that keeps failing would hold the
  queue's head.
- A universal local build: two whole-module compiles for a slice that never
  runs here.
- Rotating notes by moving everything to the archive at each run: the next
  session would lose recent operational facts.

2026-11-26
