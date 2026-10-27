---
id: feature-costs-2026-10-20
type: decision
title: Feature costs preserve historical models and separate ElevenLabs credits
summary: Soniox uses exact request prices when available and duration estimates otherwise; ElevenLabs uses local model credit rates and recorded time.
status: confirmed
tags: [settings, costs, models, credits, providers]
canonical_for: [feature-costs]
verified_at: 2026-10-21
sources:
  - type: user-confirmed
    reference: On 2026-10-21 Maxim reported unavailable scribe_v2 credits beside a working realtime estimate and asked to check the previous fix.
    confirmed_at: 2026-10-21
  - type: user-confirmed
    reference: On 2026-10-21 Maxim chose exact Soniox API prices with local estimates when unavailable, and calculated ElevenLabs credits.
    confirmed_at: 2026-10-21
  - type: url
    reference: https://soniox.com/docs/openapi.yaml
    confirmed_at: 2026-10-21
  - type: user-confirmed
    reference: On 2026-10-21 Maxim requested a more convenient Costs calendar, objected to its large blue focus ring and asked how to choose a year.
    confirmed_at: 2026-10-21
  - type: user-confirmed
    reference: On 2026-10-21 Maxim requested verification on existing sessions, approved separate reported usage by API key and directed feature estimates from recorded time with each model.
    confirmed_at: 2026-10-21
  - type: url
    reference: https://elevenlabs.io/docs/api-reference/analytics/workspace/usage
    confirmed_at: 2026-10-21
  - type: user-confirmed
    reference: On 2026-10-20 Maxim requested one Price column, removal of the bottom explanation, This month by default, consistent control fills, no persistent date selection and repair of ElevenLabs credits.
    confirmed_at: 2026-10-20
  - type: url
    reference: https://elevenlabs.io/docs/api-reference/analytics/workspace/requests
    confirmed_at: 2026-10-20
  - type: user-confirmed
    reference: On 2026-10-20 Maxim approved API keys, Models, Costs and API hints, used features only, a nearby period selector and historical models on hover in a unified panel.
    confirmed_at: 2026-10-20
  - type: user-confirmed
    reference: On 2026-10-20 Maxim requested ElevenLabs credits because free and purchased credit allocations do not have a universal dollar conversion.
    confirmed_at: 2026-10-20
  - type: repository
    reference: Sources/Sidekey/AIRouting/AIUsageStore.swift
    confirmed_at: 2026-10-20
  - type: repository
    reference: Sources/Sidekey/Settings/APIAndModels/AIUsageCostsView.swift
    confirmed_at: 2026-10-20
  - type: url
    reference: https://openrouter.ai/docs/cookbook/administration/usage-accounting
    confirmed_at: 2026-10-20
  - type: url
    reference: https://soniox.com/pricing
    confirmed_at: 2026-10-20
  - type: url
    reference: https://github.com/elevenlabs/elevenlabs-python/tree/main/src/elevenlabs/workspace/analytics/requests
    confirmed_at: 2026-10-20
  - type: url
    reference: https://github.com/anomalyco/opencode/blob/v1.17.12/packages/opencode/src/session/session.ts
    confirmed_at: 2026-10-20
related: [2026-10-19-api-hints.md, 2026-10-27-anthropic-token-costs.md]
---

# Feature expenses

The four tabs share one native settings panel. Models remains the initial tab;
runtime repair links select it before expanding the affected feature. API hints
becomes the fourth tab, retaining its offer content and existing add-key form.

Costs shows Today, Last 7 days, This month or Custom dates at the heading. Each
visit starts at This month; custom dates remain selectable within that visit.
From/To use the same neutral control fill as the period menu. As amended on
2026-10-21, their calendar has a month menu and an editable year combo with the
recent 100 years (earlier positive years can be typed). Browsing changes only
the visible month; choosing a day or Today commits and closes. Done/Return and
Escape close without applying a browsed month. Future days and navigation past
the current month are unavailable. Individual controls and days retain visible
keyboard focus, hover and pressed feedback, replacing the native calendar’s
large focus ring. The local native month popup draws from its actual enabled/
highlighted state; its pressed proof does not rely on the shared plain SwiftUI
menu. Disabled controls suppress highlight and disabled future month actions
are rejected. Disabled days never react to hover. No selected text segment
remains on the closed control. Feature-row fill follows actual
pointer hover rather than the lifetime of its detail popover. Dates
use the local calendar and include the selected end day. Only feature groups
with activity in that period appear. Hover, click or keyboard focus reveals all
models actually used, grouped by provider and model; Escape closes details.
Paired speech/text routes aggregate into one feature, preserving both models.

The new local `ai-usage.sqlite` stores only timestamps, stable request IDs,
feature/provider/model identifiers, duration, currency, amount and price basis.
It never stores credentials, endpoint URLs, prompts, transcripts, audio or replies.
Routes are captured before the request; later changes cannot rewrite history.
Synthetic model checks are excluded. Tracking starts with this update: there is
no retroactive estimate from current routes or account-wide spending.

USD and ElevenLabs credits are distinct values in one **Price** column, each
with its unit. If a feature used both, the cell and Total retain both on separate
lines. The user replaced the earlier two-column design; currencies are never
added or converted. The bottom explanation is removed; estimate/incomplete
marks remain on values and their explanation is available in help/details. OpenRouter `usage.cost` is a
reported expense. Soniox's equivalent hourly rates ($0.12 realtime / $0.10 async
for the supported v5 models) and OpenCode's per-step token/price calculation are
estimates, marked ≈. A partial total uses + for excluded unknown prices; a wholly
unknown price is Unavailable. Failed/interrupted work is not silently free.
OpenCode child-agent costs that are absent from its top-level event stream leave
an incomplete marker rather than a fabricated complete total.

Live verification on 2026-10-21 established that the request log returns request
metadata without credit amounts. Its documented example is not the live billing
schema. The saved session references did not resolve through the usage table's
request/trace filters. The previous exact-request reconciliation is therefore
replaced by the user's approved time calculation.

## Current speech accounting — 2026-10-21

Soniox initially records its supported v5 model's public equivalent hourly
estimate. Costs reads `GET /v1/usage-logs` and accepts a reported `cost_usd` only
for the exact request reference and historical model, scoped to API requests.
Realtime and batch calls send a fresh random `client_reference_id`; new meeting
jobs persist that reference in their checkpoint so retries retain one charge.
Legacy `soniox-job:` rows can match the provider UUID; uncorrelated history is
never matched by time, duration, model alone or a share of account totals.

Usage-log windows filter by request end time, so a query extends beyond an
activity day's end for audio and asynchronous completion. Each window is at
most 31 days, pagination is bounded, and repeated cursors terminate safely.
Missing, delayed, malformed, ambiguous or inaccessible prices retain estimates
marked ≈. An explicit reported zero remains zero. Late exact prices replace
estimates in the existing journal row, preserving its feature, model, currency,
start date and duration. Repeated responses cannot duplicate or downgrade a
reported charge. No provider request is sent merely to generate a test charge.

ElevenLabs feature credits are calculated from recorded audio minutes and a
cached model-specific credit/minute rate. The rate is learned from the STT
credit/minute usage table over the latest 31 days, weighted by reported minutes;
it is never derived from USD, credit balance differences or subscription price.
Only model rates and their update time are cached locally. Key names, hashes,
workspace totals and full responses are not persisted. Rate refresh is attempted
when needed or after a day; an unavailable API retains the previous usable rate.
Recording itself uses the cache without a billing request. A first-use model
without a usable rate remains unavailable rather than borrowing another model's
rate. Known per-request amounts remain unchanged, and calculated amounts stay ≈.
Calculated estimates are saved with their own historical event, so later rate
updates do not reprice saved usage.

Model details distinguish an unknown amount with missing recorded duration
from one with measured audio but no model rate. A durationless attempt cannot
use a credit/minute rate, so it does not request one or raise the missing-rate
warning. Its cost remains unknown and excluded, never zero or a rate borrowed
from another model. Existing amounts and historical events remain unchanged.

The earlier separate ElevenLabs workspace Reported usage section is superseded
by this choice. Costs has one feature table and Total, with USD and credits
kept separate. Refresh retries price lookups; API failure shows a concise
explanation while known estimates remain visible. Loading prices does not hide
local history. Tests and fixtures use temporary stores, synthetic keys and stub
network responses. Installed UI and live billing acceptance remain separate from
source/parser checks.
