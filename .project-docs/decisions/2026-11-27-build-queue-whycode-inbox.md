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
- **The sender keeps no state it trusts.** Each pass derives everything from
  two sources of truth: the queue (events and their acknowledgements) and
  Whycode's inbox folder (our notice files it has not taken and its receipts).
  A notice id names its exact batch, so sending the same batch again gives the
  same id and Whycode's ledger keeps it single: re-sending is idempotent. The
  file `whytap-build-queue-inbox.json` keeps the notice scope's start (the only
  value read back; an unreadable one starts a new scope) and a journal of
  notices for people that nothing reads to decide.
- One more piece of evidence is the sender's own: the append-only
  `whytap-build-queue-inbox-published.log`, one `<id>\t<seconds>` line written
  and synced before each notice file. Whycode can take a file into its ledger
  and still fail to write the receipt (ticket 714 review), and it removes the
  file first; the log keeps that range held under its own id, so a newer state
  change goes out on its own and the older batch is sent again only under the
  same id, after 10 minutes without file or receipt. If recording fails,
  nothing is published. A line can only hold a range and resend that same id:
  it never acknowledges anything, a line that does not match the queue is
  skipped, and a time that is not a finite past number counts as now. Once the
  ticket's newest event has been told, a lost older batch is history.
- A delivered range stays held while any of its acknowledgements is pending;
  the next pass acknowledges again from the same receipt, also after a
  restart, and publishes nothing for those events.
- Events are acknowledged only when the receipt says `delivered` (session or
  orchestrator), and only the events of that id's range. `queued` waits; with
  neither the file nor a receipt the batch is sent again under the same id.
  `rejected` raises the undelivered alert at once and is retried under a new id
  (`.r2`, ...) once 30 minutes have passed since the receipt file was written
  (its file time, no number from the file), six attempts at most.
- Ids are `whytap-build-queue:<hash of the Git common directory>:events:<first>-<last>`
  (plus `.r<attempt>` for a retry). The hash keeps another clone's queue, which
  also counts from 1, out of Whycode's ledger; the range names the exact batch.
  An id is evidence only if the queue confirms it: its first and last events
  exist in scope and belong to one ticket; then the range is that ticket's
  events between them. Anything else (a range across tickets, unknown events,
  a backwards range, an invalid receipt) acknowledges nothing, holds its range
  and raises an `inbox_invalid` alert. A notice holds its events while Whycode
  has it or waits for its retry, and one rejected for the last time keeps them
  with the alert. A new batch is every unacknowledged event of its ticket newer
  than all held ones, so it is a contiguous range and a newer result never
  waits for an older retry.
  `project` is the main checkout.
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
  (a delivered notice told it, or the author's own command moved the ticket on:
  a new head, a resubmitted return), the earlier events not on their way are
  history and are acknowledged without a notice; if it is a start or requeue,
  they ride along with the next result. A return without review (the ticket's `auto_returned`) asks only to
  wait for the dependency and resubmit the same head, or to enqueue the newer
  head, never to change code.
- One notice's failure stops no other: each piece of evidence and each
  ticket's batch is handled on its own. A rejection stops counting for the
  alert once a later attempt is on its way.
- Why stateless: the reviews of tickets 694, 696, 703 and 708 each found
  another way a sender record could disagree with what was published (a lost
  write, a lost rejection beside a lost retry, a malformed or out-of-range
  value). Checking records harder only moved the boundary. Without records
  there is nothing to disagree: a crash at any point leaves either no file
  (the batch is sent again under the same id) or Whycode's file or receipt
  (the batch is read back from it).
- Accepted residual risk: if the publication log is lost or damaged at the same
  time as Whycode loses a receipt, a later state change can repeat that older
  batch under a wider id, so the author reads those events twice. Nothing is
  acknowledged wrongly. Closing it entirely needs Whycode to write the receipt
  before it removes the file.
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
- A sender record per notice, validated and recovered from evidence (rounds 2
  to 4): every interleaving of lost writes needed its own repair.
- One notice in flight per ticket: simpler ranges, but a newer result would
  wait behind an older notice's retry.
- Forbidding Harness Link in the prompt outright: the installed watcher reads
  the prompt from origin/main before `activate`, so the first review (ticket
  694) found merging alone would leave authors with no delivery at all.
- Recording each notice before publishing it as the only guard: the record
  write is the step that can fail, so the published file or receipt is the
  evidence used instead.
