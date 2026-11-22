---
id: speech-model-lists-2026-11-20
type: decision
title: Offer only Nova-3 for Deepgram and only v6 for Soniox
summary: The Deepgram picker offers only the built-in nova-3 and the Soniox picker only stt-rt-v6 and stt-async-v6, other catalog rows are hidden, and saved Soniox v5 routes move to v6 of the same kind at launch.
status: confirmed
tags: [deepgram, soniox, models, routes, settings, drop]
canonical_for: [speech-model-lists]
verified_at: 2026-11-20
sources:
  - type: user-confirmed
    reference: On 2026-11-20 the user asked whether Deepgram had new speech models, was told Nova-3 is still the newest, and said to keep only Nova-3 for real time and prerecorded and delete the rest, calling the rest noise. He then sent a screenshot of the Soniox stt-rt-v5 row and said it goes to the bin too.
    confirmed_at: 2026-11-20
  - type: url
    reference: https://docs.soniox.com/stt/models#november-3-2026
    confirmed_at: 2026-11-20
  - type: url
    reference: https://developers.deepgram.com/changelog
    confirmed_at: 2026-11-20
  - type: repository
    reference: Sources/Sidekey/AIRouting/ModelRegistry.swift
    confirmed_at: 2026-11-20
  - type: repository
    reference: Sources/Sidekey/AIRouting/ModelStatusResolver.swift
    confirmed_at: 2026-11-20
  - type: repository
    reference: Sources/Sidekey/AIRouting/AIRoutingStore.swift
    confirmed_at: 2026-11-20
  - type: repository
    reference: Tests/SidekeyTests/AIRouting/SpeechModelListTests.swift
    confirmed_at: 2026-11-20
related: [2026-10-19-api-and-models.md, 2026-11-20-elevenlabs-scribe-v3.md, 2026-11-22-speech-model-prices.md]
---

# Offer only Nova-3 for Deepgram and only v6 for Soniox

## Context

The model picker listed every row of a provider's catalog. For Deepgram that is
dozens of domain, language and legacy models (medical, pharma, Nova-2,
enhanced, base) around the one model people pick, and Deepgram has released
nothing newer than Nova-3. Soniox released `stt-rt-v6` and `stt-async-v6` on
2026-11-03 and deprecated v5, which it removes on 2026-12-15 by routing v5
requests to v6. The app still shipped v5 as the built-in Soniox model.

## Decision

- `ModelRegistry.offersOnlyBuiltInModels` is true for Deepgram and Soniox. Their
  pickers list the built-in models only: `nova-3`, which serves live and
  recorded audio, and Soniox `stt-rt-v6` (live) and `stt-async-v6` (recorded).
- The built-in Soniox models, the recommended models, the legacy default and
  the file API model are v6. Costs estimates use the same public hourly rates
  for v6 as for v5.
- A route already saved on another model of these providers stays listed on its
  own feature and keeps working. Nothing is rewritten for Deepgram.
- Saved Soniox routes naming `stt-rt-v5` or `stt-async-v5` move to the v6 model
  of the same kind on the same account at launch
  (`AIRoutingStore.upgradeSonioxModelsIfNeeded`), also after restoring an older
  backup. The migration snapshot keeps the earlier choice.

## Why

The owner called the other rows noise: nobody should have to tell
`nova-3-general` from `nova-3` or pick a deprecated Soniox version. Soniox
describes v6 as fully compatible with v5 (only the model name changes) and
will route v5 to v6 itself three weeks later, so moving saved routes now
changes nothing a user would not get anyway, on the same account and key. The
owner's own routes had been on v6 for dictation and meetings since its release.

The rule about never switching a user's provider still holds: no route changes
account, and a Deepgram route on a hidden model is left alone because Deepgram
did not retire it.

## What was checked

- Deepgram's changelog from 2026-10-01 to 2026-11-17 names no speech model newer
  than Nova-3; Flux needs the v2 streaming API and stays unsupported.
- Soniox's model page: v6 active, v5 deprecated with removal on 2026-12-15 and
  automatic routing to v6; pricing page: 0.12 USD per hour live and 0.10 USD
  per hour for files, not split by version.
- Unit tests cover the pickers, the saved-route upgrade and its limits (other
  accounts, older names, partial documents, a second launch) and the estimate.
- Not checked in the running app: the pickers and a live v6 take on a Mac whose
  routes were on v5.

## Rejected

- Keep the full catalogs and only reorder: the noise stays.
- Filter the catalog when it is fetched: a saved route on a hidden model would
  read as removed by the provider.
- Hide v5 without moving saved routes: every existing Soniox user would sit on
  a model missing from the list until Soniox reroutes it.
- Also hide ElevenLabs and OpenRouter catalog models: not asked for.

## Known side effect

Soniox v6 writes prices and codes the way they were spoken ("15 dollars and 20
cents"), which changes the raw text of takes that used v5.

Decided 2026-11-20. PR: feature/deepgram-nova3-only.
