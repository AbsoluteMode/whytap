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
related: [2026-11-19-on-demand-build-queue-builder.md, 2026-11-22-builder-blocks-once.md, ../processes/shared-app-development.md]
---

# Watcher environment gate and watchdog

## Context

The queue was measured with `scripts/build-queue-metrics.py` from its own
journal. From 2026-11-20 to 2026-11-22 22:49 UTC: 215 tickets for 111 PRs,
98 returns to authors, 56 PRs returned at least once. A PR without returns
reached `done` in a median of 16 minutes, with returns 63 minutes (p90 186).
The queue waited 11 hours on one night while the screen was locked: sessions
started, the full suite failed on protected files, and each session exited
without progress. On 2026-11-22 ticket 461 sat `in_progress` for an hour
without a queue event and was then returned because three full suites failed
in unchanged timing tests while unrelated work held the load average at 317 on
14 CPUs. Nobody was told about either until someone looked. Events of tickets
submitted with `--source other` and a display name (ticket 476 among them)
never reached their author, because Harness Link addresses sessions by UUID.
The installed builder prompt dated from 2026-11-20 and lacked later rule
changes, including "block once with every finding".

From 2026-11-22 22:49 to 2026-11-23 12:37 UTC, after that rule: 22 tickets
for 13 PRs, 10 returns, 7 PRs returned; median builder time per attempt 12.6
minutes; PRs with returns took a median of 76 minutes; two installs waited for
the microphone; 17 author events were unacknowledged (11 of them `other`).

## Decision

- The watcher checks the environment before starting any session, including
  a deferred install: a locked screen, another user at the console or a
  five-minute load average above twice the CPU count makes it wait. A wait is
  logged, counts no backoff and blames no PR. Unknown values never block.
  `build-queue-watcher.py environment` exposes the same check; the builder runs
  it before the full suite and does not run the suite, or blame the PR, while
  it is not clear.
- Each session's prompt is read from `origin/main`, falling back to the
  installed copy offline. `activate` refuses scripts that differ from
  `origin/main` unless `--allow-local` is given.
- `enqueue` takes the author's address from `CODEX_THREAD_ID` or
  `CLAUDE_CODE_SESSION_ID`, refuses a Claude Code display name, and marks
  `--source other` tickets `inbox_only`.
- A watchdog without a model runs on idle ticks and every minute inside a
  running session. It appends `raised` and `cleared` episodes to an alerts
  JSONL file (and an optional mirror for the orchestrator) for: a ticket
  without a queue event for 60 minutes during a session, open work waiting
  for the environment for 60 minutes, repeated sessions without progress, a
  deferred install older than two hours, and author events unacknowledged
  after 20 minutes. It also keeps a heartbeat file. It never changes the
  queue, the lock or the session, and its own failures are only logged.
- `scripts/build-queue-metrics.py` measures a period read-only so the effect
  of each later step can be compared with this baseline.

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
