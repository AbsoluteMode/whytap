---
id: exodia-build-queue-2026-10-19
type: decision
title: A persistent FIFO queue feeds one designated builder chat
summary: Feature agents automatically submit reviewed work and receive start/result messages, while a scheduled builder owns checked integration and app promotion.
status: confirmed
tags: [agents, queue, builder, integration, notifications, automation]
canonical_for: [build-queue-policy]
verified_at: 2026-10-19
sources:
  - type: user-confirmed
    reference: On 2026-10-19 the user requested a queue instead of every session pushing production, automatic requests from finished agents, and a builder message asking the source agent to follow its build when work starts; the user described forgetting which of many sessions still needed a build.
    confirmed_at: 2026-10-19
  - type: repository
    reference: scripts/build-queue.py
    confirmed_at: 2026-10-19
  - type: repository
    reference: scripts/test-build-queue.py
    confirmed_at: 2026-10-19
related: [2026-10-19-shared-working-app.md, ../processes/shared-app-development.md, 2026-11-19-on-demand-build-queue-builder.md]
---

# Persistent build queue

## Context

The shared-app procedure serialized writers with a directory lock, but every
feature session could become integrator. There was no durable FIFO or automatic
dispatcher. The user had to remember which sessions still needed promotion.

## Alternatives

- Keep only the lock: protects one writer but does not remember requests.
- Treat chat messages as the queue: immediate communication, but weak recovery
  and duplicate handling across sessions and harnesses.
- Store requests locally and designate one scheduled builder: durable ordering,
  one integration owner and explicit callbacks while preserving existing gates.

## Decision

Use a local SQLite FIFO in the shared Git common directory, a copied helper for
older worktrees, and one Codex builder chat. Feature agents enqueue automatically
after readiness checks and may wake the builder by chat message. A five-minute
thread automation provides fallback pickup. This setup uses the current queue
chat as builder; the actual ID and automation metadata stay local.

The user authorizes queue requests, start notices and result/acceptance messages
between that builder and the originating feature sessions. This authorization
does not extend to unrelated chats, human recipients or public publishing.
The [process](../processes/shared-app-development.md) owns exact commands.

## Rationale

A transaction deduplicates PR/head requests, preserves FIFO and permits one
active ticket. Immutable reviewed heads prevent a later push from silently
changing the request. Persistent events retain callbacks across interrupted
turns. The integration lock remains necessary for shared refs, packaging and
app promotion, including sessions still using older instructions.

## Sources and verification

The dated request establishes the desired workflow. Disposable-repository tests
exercise concurrent enqueue/claim, separate worktrees, retries, callbacks and
head replacement. Neither the helper nor queue membership performs or verifies
the actual merge/build/install. Builder automation and live delivery are local
activation steps, distinct from repository implementation checks.

## Comments and objections

Updating main cannot change an already running agent's context. Relevant live
sessions need a short adoption message; older worktrees use the copied helper.
Codex messaging cannot wake a stopped Claude Code process. CLI agents use the
durable inbox on their next active turn. Local scheduled work also requires an
awake computer and running desktop app. Do not describe these limits as a
guarantee of immediate delivery to every harness.

## Resolution and consequences

Workers implement and follow acceptance; the builder owns integration and
promotion. A failed ticket is blocked with evidence and does not stall later
work. Waiting for safe app replacement is distinct from source/build failure;
prepared candidates remain pending while later queued work may proceed. Newer
candidates must prove inclusion before superseding older pending work.
Empty or unchanged queue checks remain silent. Explicit recovery avoids a
timeout starting a second build while the original process still runs.

## Supersedes / superseded by

The designated always-open builder chat and its five-minute automation are
superseded by the [on-demand builder](2026-11-19-on-demand-build-queue-builder.md);
the queue, its states and callbacks remain.

Supersedes the permission for any feature session to integrate its own work in
the earlier shared-app policy. All review, exact-head/base, local validation,
signing, identity, version, activity, rollback and public-release gates remain.
