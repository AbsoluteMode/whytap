---
id: whytap-builder-queue-flaky-tests-2026-11-23
type: decision
title: Unrelated test failures are rerun alone, timing tests wait for conditions, protected-file tests skip on a locked screen
summary: The builder reruns only a failed test the candidate does not touch and records it instead of blocking; timing-sensitive tests poll for their condition with generous deadlines; the two protected-file migration tests skip while the screen is locked and run again before the merge.
status: confirmed
tags: [agents, queue, builder, tests, flaky, protected-data]
canonical_for: [builder-flaky-tests]
verified_at: 2026-11-23
sources:
  - type: user-confirmed
    reference: On 2026-11-23 the maintainer approved the reduced builder-queue order, whose second step is an exact list of tests that fail on a locked screen and fixes for flaky tests.
    confirmed_at: 2026-11-23
  - type: repository
    reference: scripts/build-queue-builder-prompt.md
    confirmed_at: 2026-11-23
  - type: repository
    reference: Tests/SidekeyTests/Planner/PlannerExternalChangesTests.swift
    confirmed_at: 2026-11-23
related: [2026-11-23-builder-queue-watchdog.md, 2026-11-22-builder-blocks-once.md, 2026-11-04-todo-locked-screen.md, ../processes/shared-app-development.md, 2026-11-23-builder-queue-cheap-fixes.md, 2026-11-26-builder-quick-wins.md, 2026-11-26-test-suite-speed.md, 2026-11-26-builder-test-shards.md]
---

# Flaky and locked-screen tests in the build queue

## Context

The builder's logs from 2026-11-22 and 2026-11-23 show full suites failing in
tests the candidate did not change, which then passed alone: the recorded
Subtitles session (four runs), the Notify hover expiry (two), the island search
field remount (two), and single failures in the Toolbox tile click, Subtitles
hour limit and handshake, Soniox deletion retries, the meeting level stream and
continuation refresh, onboarding steps, the calendar preview hide and the Shot
hover hint. Every message is a deadline or a fixed sleep running out: waits of
0.7 to 6 seconds, a 50 ms retry window, a 0.2 s SwiftUI settle. The host load
reached 317 on 14 cores on 2026-11-22. Each such failure cost a second full
suite or a return to the author (ticket 461). On a locked screen, after the
2026-11-20 move of Planner files to the first-unlock class, only two tests
still fail: the ones that deliberately save an archive in the stricter
CompleteUnlessOpen class and check that the first read migrates it. Such a
file cannot be opened while the screen is locked (Cocoa 257 / POSIX 1).

## Decision

- Timing tests wait for their condition, not for a fixed time: polling
  helpers return as soon as the condition holds and have 10 to 30 second
  deadlines; fixed sleeps before a positive check became polls; the Soniox
  deletion window is 500 ms instead of 50 ms; the Subtitles hour-limit test
  skips when the scheduler overslept past the second session's own limit,
  because that run cannot tell the two deadlines apart. Checks that something
  does not happen keep their windows.
- The two protected-file migration tests skip with "Protected data is
  unavailable: the screen is locked" when they cannot read their own file.
  The builder runs every test skipped with that message again once
  `environment` is clear, before the merge, and a failure there is a finding.
- A failed test whose file and code under test the candidate does not change
  is rerun alone. If it passes it is not a finding: the builder continues,
  appends it to `whytap-flaky-tests.txt` (one line per rerun: date, ticket, test) in the Git common directory and names
  it as a follow-up when it was already listed within seven days. If the rerun
  fails, it is a finding as before.

## Rationale

A long deadline costs nothing when a test passes, because the poll returns at
once; it only removes failures caused by a slow scheduler. A rerun of the
failed tests takes seconds where a second full suite takes about ten minutes,
and the list keeps a repeated flake visible instead of hidden by reruns. The
skip keeps the locked-screen case covered: the test still runs before the
merge, on an unlocked Mac, where its premise holds.

## Alternatives

- A second full suite after any failure: what the builder did; slow and it
  still blocks on the next random flake.
- Skipping every Planner and backup test while locked: they pass on a locked
  Mac since the first-unlock class; only the two migration tests need it.
- An injectable clock in each component: the real fix for a few of these, but
  a product-code change per feature; left for tests that stay on the flaky
  list.
- Reproducing the failures before fixing: 28 busy threads on 14 cores did not
  reproduce them here; the fixes follow the failure messages.

Update 2026-11-26: the skipped tests now run before the install instead of
before the merge, recorded on the ticket (see the
[builder quick wins decision](2026-11-26-builder-quick-wins.md)).

2026-11-23
