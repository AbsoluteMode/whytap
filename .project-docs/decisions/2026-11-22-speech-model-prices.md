---
id: speech-model-prices-2026-11-22
type: decision
title: Speech pickers show each transcription model's list price per minute
summary: The Speech pickers (shared Speech row and Advanced) show a known pay-as-you-go list price per audio minute for Soniox, Deepgram, ElevenLabs and OpenAI transcription models, from a dated table in ModelRegistry; "From" marks a base price that options billed extra raise; an unknown price, a user's server and On this Mac show none, never zero.
status: confirmed
tags: [settings, models, speech, prices]
canonical_for: [speech-model-prices]
verified_at: 2026-11-22
sources:
  - type: user-confirmed
    reference: On 2026-11-22 the maintainer asked, through the orchestrating session (ORCH-TASK 73, revision 3), for prices on the transcription models in the model pickers, for every provider whose price is known.
    confirmed_at: 2026-11-22
  - type: url
    reference: https://soniox.com/pricing, https://deepgram.com/pricing, https://elevenlabs.io/pricing/api and OpenAI's pricing page, read 2026-11-22.
    confirmed_at: 2026-11-22
  - type: repository
    reference: Sources/Sidekey/AIRouting/ModelRegistry.swift
    confirmed_at: 2026-11-22
  - type: repository
    reference: Tests/SidekeyTests/AIRouting/ModelStatusResolverTests.swift
    confirmed_at: 2026-11-22
related: [2026-11-22-direct-model-list-prices.md, 2026-11-22-openai-speech-provider.md, 2026-11-20-speech-model-lists.md]
---

# Speech pickers show each transcription model's list price per minute

## Context

LLM rows in the model picker show a list price per million tokens
([direct model list prices](2026-11-22-direct-model-list-prices.md)). Speech
rows showed none, although speech is billed by the minute and providers
differ several times over. The maintainer asked for the price on the
transcription models in the Speech pickers.

## Decision

- `ModelRegistry.speechListPrice(model, kind, use)` holds the published
  pay-as-you-go price in USD per audio minute, with the pages and the date it
  was checked in the code. The picker row shows it as `$0.017 per min`
  through `ModelStatusResolver.speechPriceLabel`, in the shared Speech row's
  picker and in Advanced alike (both build `PickerSection`s).
- Prices, checked 2026-11-22:
  - OpenAI: `gpt-live-transcribe` $0.017, `gpt-transcribe` $0.0045
    (`openAISpeechUSDPerMinute`, also used by Costs).
  - Soniox: `stt-rt-v6` about $0.12/h ($0.002 per min), `stt-async-v6`
    about $0.10/h ($0.00167 per min); v5 the same.
  - Deepgram `nova-3`: From $0.0048 per min live (the pay-as-you-go
    promotional price), From $0.0043 recorded. Monolingual: Whytap's Auto
    language uses the multilingual model ($0.0058 / $0.0052), and keyterms
    cost $0.0013 more.
  - ElevenLabs: Scribe v3 Live (and v2 Realtime) From $0.22/h, Scribe v3
    (and v2) From $0.20/h; keyterms are billed extra. Plans pay in credits,
    so this is the API's list price, not a plan's.
- The live price shows on a live feature and the recorded one on Meetings,
  because the same model (Deepgram `nova-3`) can cost differently.
- No price for a user's server, On this Mac, or any model not in the table
  (for example Deepgram `nova-2` on a saved route). A zero price shows
  nothing. Never a guess.
- Display only: search, routing and Costs do not read the label.

## Why

- Speech is billed per minute and the cheapest and dearest current models
  differ about tenfold; the picker is where the choice is made.
- A dated table in code is the only source: the speech providers' model lists
  carry no price, and OpenRouter has no speech models.
- "From" is honest where the shown base grows with options Whytap can turn on
  (Deepgram multilingual, keyterms), instead of a precise-looking wrong number.

## What we tested

- `ModelStatusResolverTests.test_speech_pickers_show_the_price_per_minute_where_it_is_known`:
  a live feature and Meetings with Soniox, Deepgram, ElevenLabs and OpenAI
  keys and a server; each label, no OpenAI on Meetings, no label for a server
  or an unpriced saved model, no zero.
- `SharedModelRowsTests`: the shared Speech row's OpenAI option shows
  `$0.017 per min`.

## Rejected

- Prices per hour: the request named per minute, and OpenAI states per
  minute.
- Fetching prices at runtime: no provider publishes a machine-readable
  speech price list; the invariant against Whytap services rules out a
  Whytap-hosted table.
- The multilingual Deepgram price: Auto language is one setting among
  several, and "From" already says the price can be higher.

2026-11-22 · ORCH-TASK 73 rev. 3
