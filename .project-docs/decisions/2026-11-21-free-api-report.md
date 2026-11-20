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
  SVGs) under the caption "Everyday use fits in the free quotas." and one line
  "No card needed · Reviewed monthly · Last checked".
  Maxim asked for no extra words: details and per-offer dates stay in the
  app. Above the cards a banner compares a struck-through $600 ("≈ paid apps
  per year") with $0 for Whytap. The figure is an estimate Maxim chose: the
  README's earlier per-tool prices (dictation, meeting notes, AI launcher,
  secrets vault) add up to about $636 a year. Paid-plan credits
  (Claude Max/Ultra, ChatGPT Pro) stay in the app only: the section is about
  starting without payment.
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
  Free plan confirmed for 10,000 credits a month with Speech to Text, but its
  pages no longer state API access or separate realtime and batch quotas for
  Free, so that wording was replaced. No new no-card offer at Soniox, OpenAI or
  Anthropic.
- The generator reproduces its section byte for byte; `--check` passes.

## Rejected

- A separate docs page with every offer and its history: Maxim chose the
  README section.
- A private monthly report only: the README would still need manual updates.
- A generated raster picture for the price comparison: an SVG banner follows
  GitHub's dark and light themes and stays sharp.
- Listing paid-plan credits in the README: not "without payment".
- Letting the task add newly found offers itself: each row is a product
  decision (only offers whose key works in Whytap as it is).

2026-11-21.
