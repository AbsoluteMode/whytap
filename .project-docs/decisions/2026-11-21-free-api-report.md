---
id: free-api-report-2026-11-21
type: decision
title: Free API offers are reviewed monthly and published in the README
summary: The no-card offers from API hints form a Free API keys table in README.md, generated from APIHintsView.hints; a monthly scheduled review rechecks every offer on its official page, updates the app and the README in one PR and reports what changed.
status: confirmed
tags: [readme, api-hints, providers, pricing, maintenance]
canonical_for: [free-api-report]
verified_at: 2026-11-21
sources:
  - type: user-confirmed
    reference: On 2026-11-21 Maxim asked for a monthly report on free API offers that need no payment, also on GitHub, and chose a README section updated together with the app's API hints over a separate page or a private report only.
    confirmed_at: 2026-11-21
  - type: repository
    reference: scripts/readme-free-apis.py
    confirmed_at: 2026-11-21
  - type: repository
    reference: Sources/Sidekey/Settings/APIAndModels/APIHintsView.swift
    confirmed_at: 2026-11-21
  - type: repository
    reference: Tests/SidekeyTests/Settings/APIHintsRenderTests.swift
    confirmed_at: 2026-11-21
related: [2026-10-19-api-hints.md]
---

## Context

Settings → API & Models → API hints promises "Reviewed monthly" and shows the
newest check date, but nothing scheduled the review. Maxim also wanted people
reading the repository to see which providers let them try Whytap without
paying.

## Decision

- `APIHintsView.hints` stays the only source of offers. README's
  **Free API keys** section shows the offers with `access: .noCard` as small
  linked cards (logo, provider, allowance, period, purpose; dark and light
  SVGs). The caption "Everyday use fits in the free quotas." and the line
  "No card needed · Reviewed monthly · Last checked" sit at the bottom of the
  banner, below a thin rule (Maxim found the banner empty on 2026-11-21 and
  asked to move them there); the generator writes the date into the banner
  and its alt text, the phone banner splits the line in two. The same day he
  asked to add the other ways to run without paying: a row of three columns,
  "Your own keys" (BYOK), "Local speech-to-text" (on this Mac, Apple Silicon)
  and "Self-hosted" (OpenAI-compatible servers). With them the section is no
  longer only about keys, so it is now **Free to run**; the generator replaces
  the old "Free API keys" heading in place. Later that day Maxim renamed it
  **Free to use**, and asked for a line under the cards saying what
  ElevenLabs' free credits mean for dictation. The ElevenLabs API pricing page
  lists 2 h 30 min of Scribe v3 Live (realtime) for the Free plan, so the line
  says "up to 2.5 hours", about five minutes of speech a day; Vocab terms are
  billed as keyterm prompting on top and leave fewer hours. The numbers are not
  in the app, so the script keeps them in `NOTES` with the allowance they were
  written for and stops when that allowance changes; the monthly review
  rechecks them on the same page.
  Maxim asked for no extra words: details and per-offer dates stay in the
  app. Above the cards a banner compares a struck-through $600 ("≈ paid apps
  per year") with $0 for Whytap. The figure is an estimate Maxim chose: the
  README's earlier per-tool prices (dictation, meeting notes, AI launcher,
  secrets vault) add up to about $636 a year. Later that day Maxim asked
  for the $600 → $0 comparison at the bottom of the same block, under the
  quota lines, with a drawn arrow: the "→" glyph looked thin and uneven when
  the block is scaled. Because the section edges did not line up with the
  Tools rows and code blocks, the block is shown at the column's full width
  and the offers are two wide linked cards per row, each 49% wide (the
  compact card on phones). Paid-plan credits
  (Claude Max/Ultra, ChatGPT Pro) stay in the app only: the section is about
  starting without payment.
- Under the cards, **My setup** (asked by Maxim on 2026-11-21) shows his own
  routes from API & Models as "free* right now", in two panels: an Anthropic
  key (Claude Sonnet 5.5 for Drop Smart and Meetings notes, Haiku 5.5 for
  Agent, Translation and Subtitles) and an OpenAI key with the same price
  class (GPT-6.2 Sol, GPT-6 Luna, his choice); speech is ElevenLabs Scribe
  v3 Live in both. The asterisk explains it: the models are paid from a Claude
  Max/Ultra or ChatGPT Pro plan's monthly API credit, speech from ElevenLabs'
  free credits (non-commercial use). This is the one place the README names
  paid-plan credits, labelled as such. Maxim updates the setup himself every
  month (`SETUP_*` in the script, with its own check date). Moving Meetings to
  a recorded-audio model was considered first and dropped: Meetings on
  ElevenLabs and Deepgram stream the recording through the realtime socket,
  so it would need an app change; the panel shows the setup as it is.
- `scripts/readme-free-apis.py` writes the section; `--check` reports a stale
  one. `APIHintsRenderTests.testReadmeFreeAPICardsMatchNoCardOffers` fails
  when the README no longer matches the app.
- A scheduled task on Maxim's Mac runs on the first of each month. It rechecks
  every offer on the provider's official page, updates changed terms and every
  rechecked date in the Swift offers and the evidence in
  [API hints](2026-10-19-api-hints.md), regenerates the README, opens one PR
  and submits it to the build queue, then reports to Maxim what changed. New
  offers it finds at providers Whytap supports are proposed in the report,
  not added: adding or removing a row is Maxim's call.

## Why

One source keeps the app and the README from disagreeing. A date the task
updates only after reading the official page keeps "Last checked" honest.

## What was tested

- The first review on 2026-11-21 (official pages, no accounts): Deepgram,
  OpenRouter, Claude Max/Ultra, ChatGPT Pro and Tavily unchanged; ElevenLabs'
  Free plan lists 10,000 credits a month and Speech to Text. The API pricing
  table groups Free and Pay as you go in one column, so the app quotes the
  monthly Free credit allowance. No new no-card offer at Soniox, OpenAI or
  Anthropic.
- The generator reproduces its section byte for byte; `--check` passes.

## Rejected

- A separate docs page with every offer and its history: Maxim chose the
  README section.
- A private monthly report only: the README would still need manual updates.
- A generated raster picture for the price comparison: an SVG banner follows
  GitHub's dark and light themes and stays sharp.
- Listing paid-plan credits among the free offers: not "without payment"
  (they appear only in My setup, marked free*).
- Letting the task add newly found offers itself: each row is a product
  decision (only offers whose key works in Whytap as it is).

2026-11-21.
