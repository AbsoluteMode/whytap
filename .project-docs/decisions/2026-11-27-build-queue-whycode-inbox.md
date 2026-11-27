---
id: whytap-build-queue-whycode-inbox-2026-11-27
type: decision
title: The queue watcher tells ticket authors through the Whycode session inbox
summary: Ticket state changes reach the author's Whycode session (or the Whytap orchestrator) as one inbox notice per ticket batch, written by the model-free watcher; events are acknowledged only on a delivered receipt, and the builder no longer messages authors through Harness Link.
status: confirmed
tags: [agents, queue, builder, watcher, watchdog, whycode, notifications]
canonical_for: [build-queue-author-notices]
verified_at: 2026-11-27
sources:
  - type: user-confirmed
    reference: On 2026-11-27 the owner asked that blocked, merged, installed, superseded and cancelled tickets reach their author session (or the Whytap orchestrator) without the owner passing them on, and that a blocked author start fixing by itself; the Whycode project shipped its session inbox (Whycode PR 84, build 1839f42) for this.
    confirmed_at: 2026-11-27
  - type: repository
    reference: scripts/build-queue-watcher.py
    confirmed_at: 2026-11-27
  - type: repository
    reference: scripts/build-queue.py
    confirmed_at: 2026-11-27
  - type: repository
    reference: scripts/build-queue-builder-prompt.md
    confirmed_at: 2026-11-27
related: [../processes/shared-app-development.md, 2026-11-23-builder-queue-watchdog.md]
---

# Build-queue notices through the Whycode inbox

## Context

Feature sessions run inside Whycode as task sessions: short Claude Code or
Codex runs that Whycode resumes only when someone continues them. The builder
told authors with Harness Link `link_send` and acknowledged each event after
the send. On 2026-11-27 the builder session log showed every send to
`claude:<session>` ending as `stored` (kept for a reader that never comes) and
the send to a `codex:` address as `failed`. Of 1,545 events of Claude Code
tickets since 2026-11-20, 1,289 were acknowledged and practically none were
read; the watchdog's `undelivered:<ticket>` alert fired only when the builder
had not even tried. Blocked PRs waited until the owner asked.

The ticket's `session` (`CLAUDE_CODE_SESSION_ID` or `CODEX_THREAD_ID`) is
already the `conversation` of the Whycode session that submitted it: 43 of 146
tickets submitted from 2026-11-25 matched one. Whycode had no external entry
point, so the Whycode project added the session inbox: a file per message,
a receipt per id, deduplication across restarts and rate caps.

## Decision

- The model-free watcher delivers, on the same tick as the watchdog (idle,
  and every minute inside a builder session). For each ticket with an
  unacknowledged state change (`blocked`, `pending_install`, `done`,
  `superseded`, `cancelled`) it writes one notice with all of the ticket's
  unacknowledged events: the builder's note verbatim, the earlier events, and
  what to do next. A block asks the session to start now: fix every finding by
  class, update onto `origin/main`, validate, push and resubmit, and to take a
  product question to its orchestrator instead of guessing.
- `queued` and `in_progress` events get no notice of their own; they ride
  along with the next state change. An open ticket's newest event settles for
  90 seconds first, so a burst of builder updates becomes one turn. Both keep
  Whycode's limit of four inbox turns per session per hour for real results.
- Events are acknowledged only when the receipt says `delivered` (session or
  orchestrator). `queued` waits; a file gone without a receipt is written again
  under the same id (Whycode's ledger keeps it single). `rejected` raises the
  undelivered alert at once and is retried under a new id (`.r2`, ...) after
  30 minutes, six attempts at most.
- Ids are `whytap-build-queue:<hash of the Git common directory>:event:<id of
  the batch's newest event>`, so another clone's queue, which also counts from
  1, can never collide in Whycode's ledger. `project` is the main checkout.
- Events the author's own `enqueue` writes (its receipt, the supersede of its
  older head, a resubmitted return) are acknowledged by that command: its
  response already told the author, and a notice would wake it for nothing.
- The undelivered alert stays as the backstop, now for state changes (and any
  event of a closed ticket) with the reason in its detail: rejected, Whycode
  unavailable, not answered yet, or outside the notice scope.
- The builder writes every note as the complete message. The watcher puts
  `author_notices: "whycode_inbox"` into each run's context; with it the builder
  sends no author messages and never runs `ack`. Without it, which is the case
  for a watcher installed before this change that reads the merged prompt from
  origin/main, the builder keeps the earlier Harness Link delivery, so merging
  never leaves authors without any delivery path before `activate`.
- A notice follows the ticket's newest event. If that event is acknowledged
  (the author's own command moved the ticket on: a new head, a resubmitted
  return), the earlier undelivered events are history and are acknowledged
  without a notice; if it is a start or requeue, they ride along with the next
  result. A return without review (the ticket's `auto_returned`) asks only to
  wait for the dependency and resubmit the same head, or to enqueue the newer
  head, never to change code.
- One notice's failure stops no other: an invalid receipt (wrong shape, id or
  status) is ignored for that notice, and each ticket's batch is handled on its
  own.
- A notice published while its record failed (a crash, a full disk) is
  recovered from its file or receipt: the id names the batch's newest event, so
  the batch is that ticket's unacknowledged events up to it. It is never sent
  again under another id.
- Title (200) and text (20,000) are counted in UTF-16 units like Whycode's
  JavaScript check, without cutting a character, and the file in bytes
  (128 KB).
- Notices cover events from the watcher's activation of this version on.
  Older unacknowledged events are not sent: days-old results would wake
  sessions that the orchestrator has already continued.

## Rejected

- Continuing sessions through Whycode's task bridge: a per-run, token-guarded
  door for the orchestrator's own MCP, which refuses working sessions.
- Messages to the orchestrator through `send_to_project`: it refuses a
  project's own orchestrator and would present the queue as another project.
- Fixing Harness Link delivery: nothing wakes a Whycode session between turns,
  so a stored message is never read.
- One notice per event: a block after a start would cost two turns of the
  hourly cap and repeat context.
- Forbidding Harness Link in the prompt outright: the installed watcher reads
  the prompt from origin/main before `activate`, so the first review (ticket
  694) found merging alone would leave authors with no delivery at all.
- Recording each notice before publishing it as the only guard: the record
  write is the step that can fail, so the published file or receipt is the
  evidence used instead.
