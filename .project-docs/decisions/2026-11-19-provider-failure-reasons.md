---
id: provider-failure-reasons-2026-11-19
type: decision
title: Name the reason when a provider refuses a dictation
summary: A provider's refusal of a Drop take is shown as its cause (refused key, out of credit, busy, not responding, no connection) instead of "offline", marks the key in API & Models, and an ElevenLabs key without the speech permission is caught when it is saved.
status: confirmed
tags: [drop, errors, keys, settings, elevenlabs]
canonical_for: [provider-failure-reasons]
verified_at: 2026-11-19
sources:
  - type: user-confirmed
    reference: On 2026-11-19 the user reported a person whose ElevenLabs key had Speech to Text set to No Access; every dictation failed with an authorization error while Whytap showed only a generic failure. The user asked how such errors can be caught and shown, and approved doing it for dictation first.
    confirmed_at: 2026-11-19
  - type: repository
    reference: Sources/Sidekey/Streaming/ProviderFailure.swift
    confirmed_at: 2026-11-19
  - type: repository
    reference: Sources/Sidekey/AIRouting/ProviderKeyChecker.swift
    confirmed_at: 2026-11-19
  - type: repository
    reference: Tests/SidekeyTests/Streaming/ProviderFailureTests.swift
    confirmed_at: 2026-11-19
related: [2026-10-18-provider-batch-transcription.md, 2026-10-21-provider-key-tiles.md, 2026-10-19-api-and-models.md, 2026-11-28-on-device-model-preparation.md]
---

## Context

An ElevenLabs key can be created with Speech to Text set to No Access. The
account endpoint answers such a key with `missing_permissions`, the same as
any scoped key, so the key check saved it as a working "limited" key. Every
dictation then failed: the stream was refused, the batch attempt got 401, and
the island showed "Couldn't deliver - offline" with a Retry that could not
succeed. The key's tile kept saying the key works. The cause was found only by
reading the system log.

## Decision

- `ProviderFailure` turns a batch transcription error into a cause, from the
  status code, the error kind or an allowlisted ElevenLabs refusal code:
  refused key (401), missing permission, out of credit (402 or a named
  quota), refused (403), busy (429), not responding (5xx, an unfinished job,
  a timeout), no connection (the request never left the Mac). Other errors
  keep the existing wording. It is applied only when the take ends
  undelivered.
- The Drop failure face shows that cause with the provider's name. The audio
  stays for Retry as before.
- A refused key, missing permission or empty balance also records the
  refusal for the key (`KeyStatusStore`), so its tile and the feature's row
  show a key problem, and opens API & Models on the take's row once per
  take, as Smart cleanup already does. A 403 is not recorded: it can come
  from a plan, a region or a proxy. A later dictation that works forgets the
  record.
- The free key check that runs when Settings opens does not replace a
  recorded refusal with "limited": it cannot see what the dictation saw.
- Saving a key or Check now: when the ElevenLabs account endpoint answers
  `missing_permissions`, the check sends one second of silence to the
  speech-to-text endpoint. A refusal there is reported as "No Speech to Text
  access on this key" and the key is not saved.
- The key form's notice shows the reason a key was not saved instead of a
  bare "Key not accepted".

## Why

- The refusal is known at the moment it happens; hiding it behind "offline"
  sends the user to check a network that works.
- The status code is enough to name the cause. The response body is not
  read: it can quote dictated text.
- Opening Settings on the row follows the existing Smart cleanup behaviour
  and needs no new control in the island.
- A scoped key that the account endpoint recognised is a real key, so a
  refusal from the speech endpoint is the missing permission, not a wrong key.

## What we tested

- Status codes to causes, the wording, and which causes mark the key.
- A failed stream whose batch attempt gets 401: the cause is reported before
  the failure is shown, and the audio is retained. A Retry refused again
  reports again; a successful recovery reports nothing.
- An ElevenLabs key without the speech permission is refused on save; a scoped
  key that can transcribe stays "limited"; the free check is unchanged.
- Reopening Settings keeps a recorded refusal against a "limited" answer;
  Check now replaces it.
- An independent review of the first commit found seven defects, fixed in
  the second: the reason is applied only when the take ends undelivered
  (Settings no longer opens for a take whose partial was pasted); a Retry
  that fails for another reason clears the earlier reason; Settings opens
  once per take; a working dictation forgets a recorded refusal, so a key
  whose healthy free answer is "limited" is not marked forever; a 403 is
  shown but not recorded against the key; ElevenLabs refusals are told apart
  by the parsed `detail.status` (missing permission, quota, invalid key), so
  an exhausted quota does not read as a missing permission and an
  unexplained 401 does not block saving a scoped key; only errors that mean
  the request never left the Mac read as "No connection".
- Not seen in a running app, and not tried against the real ElevenLabs API:
  the three `detail.status` values are the ones the account endpoint and the
  reported case show, and their use by the speech endpoint is assumed.

## Rejected

- A Fix button in the island's failure face: new island UI that could not be
  checked in a running app from a feature session; opening Settings on the
  row already exists for Smart cleanup.
- Reading the provider's error body for more detail: it can contain dictated
  text.
- The same treatment for Agent voice, Voice search and Meetings in this
  change: they have no failure surface yet and are a separate step.

2026-11-19.
