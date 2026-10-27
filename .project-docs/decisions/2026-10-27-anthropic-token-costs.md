---
id: anthropic-token-costs-2026-10-27
type: decision
title: Direct Anthropic calls record cost estimated from usage tokens
summary: Costs prices direct Anthropic text and Agent requests from response token counts and published rates; anything unknown stays unavailable.
status: confirmed
tags: [costs, anthropic, providers, agent]
canonical_for: [anthropic-token-costs]
verified_at: 2026-10-27
sources:
  - type: user-confirmed
    reference: On 2026-10-27 Maxim approved counting Anthropic spend from tokens (no Admin API key on an individual organization) and adding it to the Whytap app.
    confirmed_at: 2026-10-27
  - type: url
    reference: https://platform.claude.com/docs/en/about-claude/pricing
    confirmed_at: 2026-10-27
related: [2026-10-20-feature-costs.md]
---

# Anthropic costs from tokens

## Context

Direct Anthropic routes (Drop Smart cleanup and other text features, the native
Agent) recorded rows with no amount: the Messages API returns `usage` token
counts, never a charge. The Usage & Cost Admin API needs an admin key, which an
individual Console organization cannot create.

## Decision

`AnthropicUsagePrices` estimates USD from `input_tokens`, cache writes (5-minute
1.25x, 1-hour 2x via `cache_creation`), cache reads and `output_tokens`, using the
published per-model rates. Claude Haiku 5.5 switches to its long-prompt rates
above 100,000 prompt tokens (cache included); `inference_geo: "us"` adds 1.1x.
Rows are stored with basis `estimated` and shown with ≈ in Costs.

## Why

Token counts are exact and already in every response; per-token prices are
published and stable. An estimate is more useful than an empty Price, and the
existing estimated basis already marks it honestly. No network read is added.

## What we tested

Focused unit tests cover each token category, the Haiku boundary (100,000 vs
100,001), the US multiplier, dated snapshot IDs, longest-prefix family matching
(`claude-opus-5-5` is not priced as `claude-opus-5`) and unavailable cases. The
text client and native Agent were exercised through stub HTTP responses.

## Rejected

- Admin API cost report: unavailable without converting the organization to a team.
- Guessing fast-mode or unknown-model prices: would present invented numbers.
- Pricing OpenRouter-hosted Claude here: OpenRouter already reports its charge.

2026-10-27
