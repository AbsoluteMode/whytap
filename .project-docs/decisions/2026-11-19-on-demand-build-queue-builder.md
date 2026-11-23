---
id: whytap-on-demand-build-queue-builder-2026-11-19
type: decision
title: The queue builder is an on-demand session started by a model-free watcher
summary: A launchd watcher starts one headless builder session only while the build queue has open work; submissions are checked for documentation errors when queued, deferred installs retry by themselves and the builder resolves routine merge conflicts.
status: confirmed
tags: [agents, queue, builder, watcher, launchd, integration, automation]
canonical_for: [on-demand-builder]
verified_at: 2026-11-19
sources:
  - type: user-confirmed
    reference: On 2026-11-19 the user asked to rebuild the builder so that a Codex or Claude session runs only while builds are open, a submission arriving meanwhile is queued and the session resolves merge conflicts itself; a model-free script alone was discussed and rejected because of conflicts.
    confirmed_at: 2026-11-19
  - type: repository
    reference: scripts/build-queue-watcher.py
    confirmed_at: 2026-11-19
  - type: repository
    reference: scripts/build-queue-builder-prompt.md
    confirmed_at: 2026-11-19
  - type: repository
    reference: scripts/build-queue.py
    confirmed_at: 2026-11-19
  - type: repository
    reference: scripts/test-build-queue-watcher.py
    confirmed_at: 2026-11-19
related: [2026-10-19-build-queue.md, 2026-10-20-meeting-aware-builder-refresh.md, ../processes/shared-app-development.md, 2026-11-22-builder-blocks-once.md, 2026-11-23-builder-queue-watchdog.md]
---

# On-demand queue builder

## Context

The builder was one long-lived Codex chat. Its five-minute automation had been
paused on 2026-11-15 to stop spending the subscription on empty checks, so the
chat worked only when a message woke it and only while the Codex app was open.
On 2026-11-19 a request waited 27 minutes at the head of the queue until
someone messaged the builder. It was then blocked for purely mechanical
documentation errors (a non-English decision record, missing reciprocal
`related` links, guidance files out of sync), which cost another full round.
The builder's operating knowledge also lived in one chat's context and in
helper files under a temporary directory.

## Alternatives

- Resume the five-minute automation: reliable pickup, but a model turn every
  five minutes on an empty queue, and still tied to one open desktop app.
- A script without a model that merges, builds and installs: cheapest, but it
  cannot resolve merge conflicts or judge overlapping features. Rejected by
  the user for that reason.
- A model-free watcher that starts a builder session only while work is open:
  no idle cost, pickup within a minute, a model where judgment is needed.

## Decision

Use the third option. `scripts/build-queue-watcher.py`, loaded as the per-user
LaunchAgent `ai.whytap.build-queue-watcher`, reads the queue every minute and
on every change of the queue file. With open work it starts one headless
session with the checked-in builder prompt (`scripts/`, next to the watcher),
waits for it and looks again. The [process](../processes/shared-app-development.md) owns the exact
rules. The points that are new:

- **One session.** The watcher holds an exclusive file lock for its lifetime,
  which spans the session. launchd and manual runs start nothing meanwhile, so
  later submissions wait in FIFO for the same session.
- **Lease.** The watcher's process ID is the owner recorded in
  `exodia-integration.lock`. It satisfies the rule that acquisition, protected
  operations and cleanup belong to one live process, which separate shell
  calls of a headless agent cannot. When the session ends, the watcher ends
  the rest of its process group and removes a lock naming this lease.
- **Recovery.** Because a new session starts only after the previous one is
  provably gone, it adopts its own interrupted `in_progress` ticket and
  continues from the verified state instead of waiting for a person.
- **Submission checks.** `enqueue` runs the project-documentation validators
  on the reviewed commit and rejects the request immediately.
- **Deferred installs.** `set --status pending_install --retry-install` marks
  a candidate that waits only for the meeting gate. The watcher runs the gate
  itself every five minutes and starts a session when it is clear.
- **Conflicts.** The builder resolves routine merge conflicts and mechanical
  documentation repairs and blocks only for a real choice or a failing feature.
- **Engine.** Codex is the default; Claude Code or another harness is a
  configuration value.

## Rationale

The watcher costs a short Python process per minute. A session exists exactly
as long as there is something to do, so nothing depends on an open chat window
or on a wakeup message being sent. The queue, its states and events, the
integration lock, exact head/base merges, the full test suite, signing and
designated-requirement checks, the version rule, the meeting gate, normal
quit, one rollback bundle and the receipt are unchanged: the session follows
the same process a chat did.

Codex is the default engine because a headless Codex session had the Harness
Link `link_send` tool that queue messages use, while in the same check a
headless Claude Code session had not connected that plugin. Codex is also the
engine that has run this pipeline since 2026-10-19.

Submission-time checks run on a temporary checkout of the exact reviewed
commit, so a dirty working tree neither hides nor causes a failure. They are
skipped with an explicit `unavailable` result where the skill is not
installed, since the builder validates the integrated result anyway and an
older worktree must still be able to submit.

Only `--retry-install` tickets are retried. Existing `pending_install` tickets
that wait for a person, another Mac or a public release keep waiting.

## Sources and verification

Tests with a disposable repository, a fake session, a fake meeting gate and a
fake `launchctl` cover: an idle queue starts nothing; one ticket starts one
session that drains FIFO; a ticket arriving during a build starts no second
session and is handled next; a crashed session is replaced and its ticket and
lock recovered; a killed watcher leaves no session without a lease; sessions
without progress back off; a deferred install waits out a meeting and then
installs; a manual pending install is never retried; activation and return.

Checked once on the maintainer's Mac on 2026-11-19 from a temporary launchd
job in the graphical session: signing a throwaway file with the Developer ID
identity, `whytap case ls`, `gh`, and signed-in headless `claude` and `codex`
all worked without a prompt.

Not verified before activation: a real builder session started by the watcher,
replacing the installed application from a launchd-started process (macOS may
ask once for App Management or Automation permission for the new responsible
process) and `whytap case run` with values, which a local refresh does not
need.

## Comments and objections

The session runs with the engine's approval prompts disabled, started by a
change in a local file that any local session can write. Queue contents are
evidence only; the prompt and the process are the authority. This is the same
trust the builder chat had, now without a person watching each turn, so the
watcher bounds sessions in time, backs off when nothing changes and notifies
after three fruitless sessions.

A fresh session does not remember earlier builds. The process, the prompt and
a short local notes file the builder maintains carry that knowledge.

The LaunchAgent works only in a logged-in graphical session on an awake Mac
with an unlocked login keychain.

## Resolution and consequences

The maintainer activates the watcher with one command between builds and can
return to the previous builder chat with one command. Feature sessions keep
submitting exactly as before and no longer need to message a builder. A failed
documentation check costs seconds at submission instead of a build turn.

## Supersedes / superseded by

Supersedes the always-open builder chat and its five-minute automation from
the [build queue decision](2026-10-19-build-queue.md). The standing restart
authorization of the
[meeting-aware refresh](2026-10-20-meeting-aware-builder-refresh.md) is
unchanged and now also drives the automatic retry.
