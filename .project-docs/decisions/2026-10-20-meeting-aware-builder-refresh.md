---
id: whytap-meeting-aware-builder-refresh-2026-10-20
type: decision
title: Check for meetings and refresh without repeated questions
summary: The maintainer authorizes automatic normal restarts outside meetings, accepting interruption of other work; suspected or unknown meetings defer silently.
status: confirmed
tags: [build, queue, restart, meetings, autonomy]
canonical_for: [builder-restart-authorization]
verified_at: 2026-10-20
sources:
  - type: user-confirmed
    reference: On 2026-10-20 in builder chat 01a1558a-7ee5-7c73-a6fb-9388189e362e, after installing1512, the user explicitly asked the builder to check for a meeting itself and restart without asking at all other times, accepting interruption outside meetings.
    confirmed_at: 2026-10-20
  - type: repository
    reference: scripts/build-queue-meeting-gate.py
    confirmed_at: 2026-10-20
  - type: repository
    reference: scripts/build-queue-meeting-gate.swift
    confirmed_at: 2026-10-20
related: [../processes/shared-app-development.md, 2026-10-19-shared-working-app.md, 2026-11-19-on-demand-build-queue-builder.md, 2026-11-23-builder-queue-group-install.md]
---

# Meeting-aware builder refresh

## Context

Repeated saved/idle questions delayed ready updates. After1512 the maintainer
said that interruption is unpleasant during a meeting and explicitly accepted
interruption at other times. This is standing permission for the queue builder,
not a claim that all other work has been saved.

## Alternatives

- Keep asking before every restart: rejects the user's new instruction.
- Restart whenever a candidate is ready: could interrupt a meeting.
- Check current meeting signals and refresh automatically outside meetings:
  follows the requested autonomy while retaining a conservative deferral path.

## Decision

Use the third option. The shared procedure owns the exact probe and quiet retry.
The builder records the fresh machine check and this standing authorization;
it must not fabricate a new human saved/idle answer. Existing approvals remain
historical evidence and are never relabeled as new confirmations.

## Rationale

The user's explicit willingness to interrupt other work supersedes the earlier
per-build saved/idle request. Normal quit, full exit, consistent migration
backups, signed whole-bundle replacement and runtime verification still apply.
App-managed Sparkle activity policy is unchanged; this decision is about the
local builder only and does not itself require an app rebuild.

## Sources

The direct human request in the builder chat is the authority. The scripts
implement a best-effort, read-only CoreAudio gate; their documented limits
must not be presented as complete meeting detection.

## Comments and objections

Muted/listening-only calls and media can be ambiguous. Unknown signals defer
without repeatedly asking the user. A call with no observable input/output
or a listening-only call in an unrecognized native app may be missed.

## Resolution

Persist this policy in the process, synchronized guidance and the existing
builder automation. Do not create another scheduler or reset OS permissions.

## Consequences

Ready updates no longer wait for a new saved/idle answer outside meetings.
The probe can postpone on media or brief microphone work. Normal quit can still
be declined; that defers installation rather than authorizing force termination.

## Supersedes / superseded by

Supersedes the per-build saved/idle handoff portion of the2026-10-19 shared-app
policy. Signature, provenance, exact-SHA review, queue, backup and acceptance
gates remain in force.
