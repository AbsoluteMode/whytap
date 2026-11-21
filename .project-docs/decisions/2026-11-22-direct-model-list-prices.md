---
id: direct-model-list-prices-2026-11-22
type: decision
title: Every keyed LLM provider is visible in the model picker, with dates and list prices
summary: OpenRouter's huge catalog no longer hides the Anthropic, OpenAI and server sections (it comes last, and a provider bar shows one provider at a time); direct Anthropic and OpenAI rows get the price and reasoning note of the same model in OpenRouter's cached catalog; servers show a real created date and no price.
status: confirmed
tags: [settings, models, openrouter, anthropic, openai, prices]
canonical_for: [direct-model-picker-prices]
verified_at: 2026-11-22
sources:
  - type: user-confirmed
    reference: On 2026-11-22 the maintainer asked, through the orchestrating session, for the Anthropic and OpenAI sections of the model picker to show the same information as OpenRouter's rows (date, price per million tokens, reasoning note), for every LLM provider with a key including the user's own servers, and reported that the Drop Smart text picker showed only OpenRouter although his Anthropic and OpenAI keys were valid. He will switch routes himself.
    confirmed_at: 2026-11-22
  - type: repository
    reference: Sources/Sidekey/AIRouting/ModelStatusResolver.swift
    confirmed_at: 2026-11-22
  - type: repository
    reference: Tests/SidekeyTests/AIRouting/ModelStatusResolverTests.swift
    confirmed_at: 2026-11-22
related: [2026-11-17-openrouter-model-prices.md]
---

# Every keyed LLM provider is visible in the model picker, with dates and list prices

## Context

OpenRouter rows in `ModelPicker` show a date, `$X in / $Y out per 1M tokens`
and, in Drop Smart cleanup, "always reasons, slower". Anthropic and OpenAI rows
showed only their date: their `/v1/models` responses carry no price and do not
say whether a model always reasons. The 2026-11-17 decision rejected prices for
direct routes; the maintainer now asked for them.

The maintainer's Drop Smart text picker looked like OpenRouter only, with
valid Anthropic and OpenAI keys. The resolver did return their sections (the
running app's `whytap_list_models` lists them), but OpenRouter came first with
about 358 models in a 300 pt list, so Anthropic and OpenAI sat several
thousand points below the visible rows, and an OpenRouter route opened the list
scrolled to its own model. In practice every LLM feature stayed on OpenRouter.

## Decision

- Section order: speech providers, Anthropic, OpenAI, the user's servers, then
  OpenRouter. Every provider with a key (a server needs none) that can serve
  the feature keeps its section, as before.
- With more than one section, a provider bar under the search field offers All
  and each provider with its model count; choosing one shows only that
  section. Search runs over the shown sections. A provider that disappears
  while the picker is open falls back to All. Nothing switches a route.
- A refused or unreadable key keeps its section (fixing the key makes it work)
  with `· Key not accepted` or `· Couldn't read the key` in its header. When
  such a section (or one whose first catalog fetch failed) has no rows, as the
  sole provider, the one chosen in the bar or alongside others, the picker
  shows its header, a one-line reason and, for a key, Open API keys. The build
  queue's review found the first version rendered such a picker byte-identical
  to a plain "No matching models".
- A user's server shows `created` from its /v1/models as `Added <date>` when the
  date is over an hour older than the fetch. Ollama sends when the model was
  pulled or changed; vLLM and llama.cpp stamp every model with the request
  time, which is not a model date. Servers get no price line: nothing states
  one, and a server's model is not the provider's model of the same name.

- The price line and the reasoning note of a direct Anthropic or OpenAI row
  come from the same model's entry in the OpenRouter catalog the app already
  caches (`ModelStatusResolver.openRouterCounterpart`). One source for every
  list price in the picker, formatted by the same `catalogPriceLabel`.
- Matching: OpenAI `gpt-5.4` is `openai/gpt-5.4`, exactly; a dated snapshot
  (`gpt-5.4-2026-03-05`) is priced only when OpenRouter lists that snapshot,
  because a pinned snapshot can be priced differently from its alias
  (`gpt-4o-2024-05-13` vs `gpt-4o`). Anthropic tries `anthropic/<id>`, then the
  ID without its `-YYYYMMDD` suffix and with dots between version digits
  (`claude-opus-4-5-20251101` is `anthropic/claude-opus-4.5`,
  `claude-fable-5-2` is `anthropic/claude-fable-5.2`): Anthropic's dated ID
  is the model itself, not a separately priced snapshot.
- The date stays the provider's own (`Released` for Anthropic, `Created` for
  OpenAI). OpenRouter's "added" date describes another event and is not used.
- No match, no cached OpenRouter catalog (no OpenRouter key) or a first
  OpenRouter fetch that failed: no price and no note. Never a guess or a zero.
- Display only, as before: not searchable, no effect on routes, checks or
  Costs.

## Why

OpenRouter passes provider list prices through for these models, and its
catalog is already downloaded, cached and parsed with all the edge cases
(missing, malformed, router -1 prices) handled. A built-in price table would
be a second source of truth that goes stale; `AnthropicUsagePrices` exists
only for estimating Costs and has no OpenAI counterpart. No new request, host
or key use: Invariant 1 is unchanged.

## What was checked

- The local catalog cache (2026-11-22) lists every current Anthropic model
  under the dotted name and OpenAI models under the same ID.
- Tests: ID mapping for OpenAI, Anthropic dated/dotted/legacy IDs, prefixed and
  empty IDs and other providers; picker rows with price, reasoning note,
  unchanged provider date, no line for unmatched IDs and dated OpenAI
  snapshots; agent rows priced without the cleanup note; unchanged states and
  search; no OpenRouter catalog and a failed first fetch show no extra lines.

- Tests also cover: Anthropic, OpenAI, a server and a 400-model OpenRouter
  catalog in that order for Smart cleanup, notes and translation (Agent without
  the server); search leading with the direct section; a refused key keeping
  its labelled section; a removed key dropping only its own; the provider bar
  filter and its fallback; a stubbed Ollama-style /v1/models with and without
  `created`; server dates within an hour of the fetch hidden; no server price.

## Rejected

- Dates from OpenRouter for direct rows: a different event under a misleading
  label.
- A built-in price table, or `AnthropicUsagePrices` for Anthropic only: a
  second source that drifts, and nothing for OpenAI.
- Fetching OpenRouter's public catalog for users without an OpenRouter key: a
  new network destination they did not configure (Invariant 1).
- Matching dated OpenAI snapshots to their alias: can show the wrong price.
- Moving the picker to the current route's provider automatically, or
  switching any route to a direct provider: the maintainer chooses himself.
- "Local · free" on server rows: a server may be a paid remote endpoint; no
  line is better than a claim.
- Hiding sections with a refused key: the key can be fixed, and a vanished
  section looks like the original bug.

## Limits

The line is OpenRouter's list price for the model, which for these providers
matches their published per-million rates; batch, cache, long-context tiers
and priority processing are not shown. Users without an OpenRouter key see no
price on direct rows. Costs shows what requests actually cost.

2026-11-22. PR: see the commit that adds this file.
