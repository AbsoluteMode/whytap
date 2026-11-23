---
id: whytap-builder-queue-watchdog-2026-11-23
type: decision
title: The queue watcher waits for a usable Mac and a model-free watchdog reports stalls
summary: The watcher starts no builder session while the screen is locked or the Mac is overloaded, each session reads its rules from origin/main, activation installs only merged scripts, enqueue takes the author's address from the harness, and a watchdog appends stalls, waits and unreachable authors to an alerts file.
status: confirmed
tags: [agents, queue, builder, watcher, watchdog, environment, metrics]
canonical_for: [builder-queue-watchdog]
verified_at: 2026-11-23
sources:
  - type: user-confirmed
    reference: On 2026-11-23 the maintainer approved the reduced order from the council review of the builder-queue plan, starting with current builder rules, a baseline measurement, a model-free watchdog and a load and screen-lock gate, and deferring batch builds, a separate review stage and a documentation fast lane.
    confirmed_at: 2026-11-23
  - type: repository
    reference: scripts/build-queue-watcher.py
    confirmed_at: 2026-11-23
  - type: repository
    reference: scripts/build-queue-metrics.py
    confirmed_at: 2026-11-23
  - type: repository
    reference: scripts/build-queue.py
    confirmed_at: 2026-11-23
related: [2026-11-19-on-demand-build-queue-builder.md, 2026-11-22-builder-blocks-once.md, ../processes/shared-app-development.md, 2026-11-23-builder-queue-flaky-tests.md]
---

# Watcher environment gate and watchdog

## Context

The queue was measured with `scripts/build-queue-metrics.py` from its own
journal (events inside each period; carry-in work counts where it ends). From
2026-11-20 to 2026-11-22 22:49 UTC: 220 tickets for 113 PRs, 96 returns to
authors, 56 PRs returned at least once. A PR without returns reached `done` in
a median of 16 minutes, with returns 65 minutes (p75 125). The queue waited
11 hours on one night while the screen was locked: sessions started, the full
suite failed on protected files, and each session exited without progress. On
2026-11-22 ticket 461 sat `in_progress` for an hour without a queue event and
was then returned because three full suites failed in unchanged timing tests
while unrelated work held the load average at 317 on 14 CPUs. Nobody was told
about either until someone looked. Events of tickets submitted with
`--source other` and a display name (ticket 476 among them) never reached
their author, because Harness Link addresses sessions by UUID. The installed
builder prompt dated from 2026-11-20 and lacked later rule changes, including
"block once with every finding".

From 2026-11-22 22:49 to 2026-11-23 12:37 UTC, after that rule: 27 tickets
for 13 PRs, 14 returns, 10 PRs returned; median builder time per attempt 10.8
minutes; queue wait median 8 minutes but p90 385 (another locked night); PRs
with returns took a median of 480 minutes, PRs without 19; two installs waited
for the microphone; 16 author events were unacknowledged (11 of them `other`).

## Decision

- The watcher checks the environment before starting any session, including
  a deferred install: a locked screen, another user at the console or a
  five-minute load average above twice the CPU count makes it wait. A wait is
  logged, counts no backoff and blames no PR. Unknown values never block.
  `build-queue-watcher.py environment` exposes the same check; the builder runs
  it before the full suite and does not run the suite, or blame the PR, while
  it is not clear.
- Each session's prompt is read from `origin/main` only after a successful
  fetch, from that fetched commit and labelled with its SHA; a failed fetch
  uses the installed copy, never a cached `origin/main`. `activate` refuses
  scripts that differ from freshly fetched `origin/main`, and refuses when the
  fetch fails, unless `--allow-local` is given.
- `enqueue` takes the author's address from `CODEX_THREAD_ID` or
  `CLAUDE_CODE_SESSION_ID`, validates the whole field (a Claude Code address is
  a UUID stored in lower case, no whitespace anywhere), refuses a display name,
  and marks `--source other` tickets `inbox_only`.
- A watchdog without a model runs on idle ticks and every minute inside a
  running session. It appends `raised` and `cleared` episodes to an alerts
  JSONL file (and an optional mirror for the orchestrator) for: a ticket
  without a queue event for 60 minutes during a session, open work waiting
  for the environment for 60 minutes, two sessions in a row without progress
  (queued work or a deferred install), a deferred install older than two
  hours, and author events unacknowledged after 20 minutes. The scope for
  author events starts when the watcher is activated or first started, before
  its first session. An episode clears only when its condition is resolved;
  an event in scope never expires. A
  record a destination cannot take waits in an outbox and is written once the
  destination works. It keeps a heartbeat file, shows no notifications, never
  changes the queue, the lock or the session, and its own failures are only
  logged. A failed, malformed or oddly shaped environment probe (including a
  number too large for a float) is unknown and never blocks.
- `scripts/build-queue-metrics.py` measures a period read-only from the
  events inside it, with the status as of the cutoff, and clips waits that
  cross either end. Submission and requeue times come from `queued` events,
  because a requeue resets the ticket's `queued_at`. A meeting-gate wait starts
  only when the gate says "not clear", spans its rechecks and ends at the next
  other decision, idle included; a retry backoff after a clear gate and a
  failed install is not a meeting wait. So the effect of each later step can be compared with
  this baseline.

## Rationale

The cheapest losses were environmental, not review: a locked night, an
overloaded Mac and silent stalls. Waiting instead of starting a doomed
session removes the night of empty sessions and the false blame for load.
The watchdog lives in the watcher because launchd starts no second tick while
a session runs; a check inside the running watcher is the only model-free
place that sees a live stall. Its measure is the queue's own events, not a
pulse the builder could keep sending while stuck. Alerts are a file the
orchestrator reads, not a push from launchd, so delivery needs no model and
no Harness Link library in a launchd process.

## Alternatives

- A separate LaunchAgent for the watchdog: survives a watcher bug, but adds a
  second agent to install and supervise; deferred.
- A builder pulse (`progress` events): proves the session is alive, not that it
  advances, would message authors and would reset the backoff fingerprint.
- Pushing alerts through Harness Link from launchd: not verified outside a
  session; the file is enough for the orchestrator.
- Batch builds, a review stage before the queue and a documentation fast lane:
  deferred by the maintainer after the council review.

## Consequences

The new watcher and prompt take effect only after the maintainer's
`build-queue-watcher.py activate` between builds; until then the builder
reads this process from `origin/main` as before. Long full suites under load
now wait instead of failing. A deferred install may wait longer while the
screen is locked, which it already did at the install step.

2026-11-23
