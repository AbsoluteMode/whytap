---
id: openrouter-model-prices-2026-11-17
type: decision
title: Show OpenRouter's list price in the model picker
summary: OpenRouter rows in the model picker show the catalog's price per million input and output tokens, read from the catalog response the app already loads. Unknown prices show nothing.
status: confirmed
tags: [settings, models, openrouter, prices]
canonical_for: [model-picker-prices]
verified_at: 2026-11-17
sources:
  - type: user-confirmed
    reference: On 2026-11-17 the user asked to show the model price for OpenRouter models, after a Drop Smart cleanup model change made each dictation several times more expensive and slower without any sign of it at the moment of choosing.
    confirmed_at: 2026-11-17
  - type: repository
    reference: Sources/Sidekey/AIRouting/ModelCatalog.swift
    confirmed_at: 2026-11-17
  - type: repository
    reference: Sources/Sidekey/AIRouting/ModelStatusResolver.swift
    confirmed_at: 2026-11-17
related: [2026-10-20-model-search.md, 2026-10-19-api-and-models.md, 2026-10-20-feature-costs.md, 2026-11-22-direct-model-list-prices.md]
---

## Context

On 2026-11-16 the Drop Smart cleanup route moved from one OpenRouter model to
another. A dictation went from roughly $0.002-0.005 to $0.008-0.011 and from
1-3 s to about 4.6 s; it was reported as "Smart does not work". Nothing in the
picker says what a model costs, so the difference was visible only afterwards
in Costs.

## Decision

Each OpenRouter row in `ModelPicker` gets one more secondary line under its
date: `$1.25 in / $10 out per 1M tokens`. The amounts are `pricing.prompt` and
`pricing.completion` from OpenRouter's public `/api/v1/models` response, which
the catalog fetch already downloads and caches; they are stored per model as
USD per million tokens (`CatalogTokenPrice`).

- A price exists only when both amounts are present, numeric and not negative.
  Missing, malformed, empty or negative amounts (OpenRouter prices routers at
  -1) give no line. An unknown price is never drawn as zero.
- `Free` appears only when the catalog states zero for both sides. One zero
  side stays numeric (`$0 in / $0.4 out`).
- Two decimals from $1 up, three significant digits below, so a small price is
  never rounded to zero.
- Only the OpenRouter account gets a label. Other catalogs carry no prices,
  and a model ID on another provider is a different price.
- Display only. The label is not searchable, does not order results and does
  not touch routes, model checks or the Costs journal.
- `CatalogSnapshot.currentMetadataVersion` goes from 3 to 4. A cache written
  before prices stays readable offline and is refetched once when a picker
  opens, exactly as for dates. The same bump refetches the OpenAI and Anthropic
  catalogs once; both are free list requests the app already makes daily.

## Why

The price belongs where the choice is made. The data is already in a response
the app loads, so there is no new request, host or key use: Invariant 1 is
unchanged. Per-million units are what OpenRouter and provider price pages
show, so the numbers can be compared without conversion.

## What was checked

- The existing catalog request already decoded `pricing.prompt` (to drop
  routers priced at -1); `completion` sits in the same object.
- Tests: parsing of string and numeric amounts, missing side, malformed and
  empty values, a `pricing` of another shape, negative amounts, zero; label
  formatting and the other providers; the picker options; search not matching
  a price; a version-3 cache kept offline and refetched once.

## Rejected

- A per-dictation estimate ("about $0.004 per Drop"): depends on text length
  and reasoning tokens; a guess presented as a number.
- Prices for direct OpenAI/Anthropic routes: their model lists carry none; a
  built-in table would go stale (Costs keeps its own for Anthropic estimates).
  Revisited on 2026-11-22: they now show the OpenRouter catalog's price for the
  same model (2026-11-22-direct-model-list-prices.md).
- Price in the selected-model row or a price sort: not requested.
- Cache-read, image or per-request prices: noise for choosing a text model.
- A separate version for OpenRouter only: one more field for saving two free
  requests once.

## Limits

This is OpenRouter's list price for the model. A pinned hosting provider, a
`:nitro`/`:floor` style variant or a long-context tier can cost differently;
Costs shows what requests actually cost. Latency is not shown.

2026-11-17. PR: see the commit that adds this file.
