---
id: elevenlabs-scribe-v3-2026-11-20
type: decision
title: Replace ElevenLabs Scribe v2 with Scribe v3
summary: ElevenLabs speech runs on Scribe v3 Live (dictation) and Scribe v3 (recorded audio) instead of Scribe v2, and saved ElevenLabs routes naming Scribe v2 Realtime are moved to Scribe v3 Live on the same account at launch.
status: confirmed
tags: [elevenlabs, models, routes, settings, drop]
canonical_for: [elevenlabs-scribe-v3]
verified_at: 2026-11-20
sources:
  - type: user-confirmed
    reference: On 2026-11-20 the user asked why Scribe v3 was not in the model list. Offered v3 beside v2 (existing routes untouched) or v3 instead of v2 (saved routes change model), with the note that the second changes what existing users' speech is recognized with, the user chose to replace the old models.
    confirmed_at: 2026-11-20
  - type: repository
    reference: Sources/Sidekey/AIRouting/ModelRegistry.swift
    confirmed_at: 2026-11-20
  - type: repository
    reference: Sources/Sidekey/AIRouting/AIRoutingStore.swift
    confirmed_at: 2026-11-20
  - type: repository
    reference: Tests/SidekeyTests/AIRouting/ElevenLabsScribeUpgradeTests.swift
    confirmed_at: 2026-11-20
related: [2026-10-19-api-and-models.md, 2026-10-18-provider-batch-transcription.md, 2026-10-20-model-search.md]
---

## Context

ElevenLabs released Scribe v3 (`scribe_v3`, recorded audio) and Scribe v3 Live
(`scribe_v3_live`, streaming) on 2026-11-10. ElevenLabs' model API lists voice
models only, so Whytap's ElevenLabs speech models come from the built-in
registry, which named only `scribe_v2_realtime` and `scribe_v2`. There is no
field for typing an ElevenLabs model ID, so the new models could not be chosen.

## Decision

- The registry offers `scribe_v3_live` for the real-time features and uses
  `scribe_v3` for recorded audio (batch recovery, Retry, agent batch voice,
  the key check's speech probe). Scribe v2 is no longer offered.
- At every launch `AIRoutingStore.upgradeElevenLabsScribeIfNeeded` rewrites
  each saved route whose account is ElevenLabs and whose model is
  `scribe_v2_realtime` to `scribe_v3_live`. The account, its Keychain key and
  every other route stay as they are. A route restored from an older backup
  moves the same way. The pre-migration snapshot is not rewritten.
- A feature without a route stays Not set; nobody is moved to ElevenLabs. The
  same model name on a user's own server is left alone. A routing document
  this build could not read in full is not rewritten.

## Why

The owner chose replacement over offering both. It is a deliberate exception
to "saved routes change only by a user action": the provider, the account and
the key are the same, only the provider's model generation changes, and the
audio goes where it went before. Offering both would have left every existing
ElevenLabs user on the older model until they found the picker.

## What was checked

- The model IDs, the WebSocket endpoint and its messages, and the batch
  endpoint's parameters were read from ElevenLabs' API reference and launch
  post on 2026-11-20. The real-time protocol and the batch parameters Whytap
  sends are the same for v2 and v3; the docs name no parameter v3 rejects.
- Not checked: a real dictation or batch request on Scribe v3 with a key. No
  ElevenLabs key was available to the session. If an account is refused the
  new model, dictation on ElevenLabs fails with the provider's named reason
  until the route is changed.
- Costs: ElevenLabs estimates use the per-model credit rate from the user's
  own usage rows. Whether the usage API reports v3 under these IDs was not
  checked; without a rate the row shows no price, never zero.

## Rejected

- Offer v3 beside v2: existing users stay on the older model without knowing.
- Resolve v2 to v3 only in memory: Settings would show a model that is not
  the one used.
- Replace without moving saved routes: a saved v2 route would show as a model
  outside the registry and keep running on v2.

2026-11-20.
