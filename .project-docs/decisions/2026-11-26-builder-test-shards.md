---
id: whytap-builder-test-shards-2026-11-26
type: decision
title: The builder's full suite runs as two class shards with a coverage check, solo reruns and a serial fallback
summary: scripts/test-shards.py builds the tests once, splits the classes deterministically by committed times into two xctest processes, refuses a split that does not equal swift test --list-tests, reruns each failed test alone before it counts and falls back to the serial swift test whenever sharding itself fails.
status: confirmed
tags: [agents, queue, builder, tests, speed]
canonical_for: [builder-test-shards]
verified_at: 2026-11-26
sources:
  - type: user-confirmed
    reference: On 2026-11-26 the orchestrator, within the owner's request for faster testing and review, decided to switch the builder's full-suite step to two class shards with a deterministic split, a check against swift test --list-tests, the load gate kept, solo reruns of failures and a serial fallback.
    confirmed_at: 2026-11-26
  - type: repository
    reference: scripts/test-shards.py
    confirmed_at: 2026-11-26
  - type: repository
    reference: scripts/test-test-shards.py
    confirmed_at: 2026-11-26
related: [2026-11-23-builder-queue-flaky-tests.md, ../processes/shared-app-development.md]
---

# Builder test shards

## Context

The full suite is the longest step of a builder ticket (about 320 seconds after
the test speedups). SwiftPM locks `.build`, so two `swift test` runs cannot
overlap, and `swift test --parallel` starts a process per test and measured
slower (351 seconds). Running the built test bundle as
`xcrun xctest -XCTest <classes>` in two processes, balanced by class time, was
green ten times out of ten at 164 to 166 seconds (three shards: about 105
seconds, three runs). Those runs were at a host load of 3.5 to 17, not near
the load gate's limit.

## Decision

- The builder's full suite is `python3 scripts/test-shards.py --shards 2`,
  after the unchanged `environment` load and screen gate.
- The split is deterministic: committed class times in
  `scripts/test-shard-times.json`, heaviest class first to the lightest shard,
  ties by name and index; a class without a recorded time weighs the median.
- Before anything runs, each listed class must be in exactly one shard and the
  shards' test count must equal `swift test --list-tests`. After the run, the
  shards' executed counts must add up to the same number.
- Every failed test is rerun alone with `swift test --filter`, serially. Only a
  test that fails again is reported in `failed`; the others are reported in
  `failed_then_passed_alone` and follow the flaky-test rules.
- No list, no single test bundle, a crashed shard or a count mismatch is a
  problem of sharding, not of the PR: the script runs the serial `swift test`
  instead and says why.
- Tests skipped because protected data is unavailable are listed so the
  builder reruns them once the screen is unlocked.

## Rationale

Two shards halve the suite with the margin the measurements showed; three
were faster but measured on fewer runs and load more cores while the owner
works. The coverage check makes a missed class impossible rather than
unlikely, and the serial fallback keeps a broken shard runner from blocking a
PR. Stale times only unbalance the shards; they never drop a test.

## Alternatives

- `swift test --parallel`: measured slower.
- Hashing class names into shards: deterministic but unbalanced; the largest
  classes take a minute each.
- Three shards: faster, kept for later after more runs under load.

2026-11-26
