---
id: smart-latency-2026-09-07
type: decision
title: Bound context collection and explicitly finalize Smart dictation
summary: Use supported minimal reasoning, provider-confirmed finalization and local stage diagnostics.
status: confirmed
tags: [smart, latency, reasoning, soniox, accessibility, diagnostics]
canonical_for: [smart-dictation-latency-policy]
verified_at: 2026-09-07
sources:
  - type: repository
    reference: Sources/Sidekey/AXContextReader.swift
    confirmed_at: 2026-09-07
  - type: repository
    reference: Sources/Sidekey/Streaming/BYOK/OpenRouterReasoningPolicy.swift
    confirmed_at: 2026-09-07
  - type: repository
    reference: Sources/Sidekey/Streaming/BYOK/SonioxBYOKAdapter.swift
    confirmed_at: 2026-09-07
  - type: url
    reference: https://openrouter.ai/docs/guides/best-practices/reasoning-tokens
    confirmed_at: 2026-09-07
  - type: url
    reference: https://soniox.com/docs/stt/rt/manual-finalization
    confirmed_at: 2026-09-07
related: [../project.md]
---

# Smart dictation latency

## Context

Smart previously omitted reasoning settings, inheriting model defaults. Gemini
3.8 Flash advertises mandatory reasoning, default medium, with low as its
minimum. AX cancellation still awaited synchronous IPC, exceeding its stated
deadline. Soniox Stop relied solely on an empty text EOF and finished=true.

## Alternatives

A universal reasoning-off switch fails on models with mandatory reasoning.
Shortening the STT watchdog without a provider acknowledgement risks dropping
last words. Replacing text EOF with binary EOF did not improve the synthetic
Foundation WebSocket probe. A structured task-group timeout waits for a
non-cooperating AX child, so it does not enforce the caller deadline.

## Decision

- Apply a dictation-specific OpenRouter profile. Use catalog capabilities to
  disable optional reasoning, or select the lowest explicitly supported effort
  for mandatory reasoning. Cache the catalog for one hour; bound each discovery
  request to 1.5 seconds of inactivity and back off failed discovery for 30s.
  Unknown capability data preserves provider defaults. Discovery sends no key.
  Custom endpoints and meeting summaries do not receive this policy.
- After draining every captured Soniox audio chunk, append 200ms PCM silence,
  send finalize, then text EOF. A final <fin> acknowledges all preceding audio
  and may complete the take before finished=true. Strip control markers.
  Retain the 10s watchdog, cancellation precedence and raw-audio recovery.
- Serialize Soniox state with an actor; fail on provider error frames or audio
  send failures instead of silently waiting. Accept JSON in text or data frames.
- Race AX results against an independent deadline through AsyncStream. Cancel
  losing work, discard late values, check cancellation between AX IPC calls.
- Log local timing/count/ID metadata only: AX, cleanup, catalog, LLM, STT
  finalization, release-to-completion and reasoning-token usage. Missing usage
  is -1, never inferred zero. No content, credentials, or server error bodies.

- Prioritize provider throughput for Smart via `provider.sort: throughput`.
  Preserve the selected model and normal provider fallbacks; do not pin one
  endpoint or opt into priority service tiers. OpenRouter picks among eligible
  providers using its current performance data. Standard/meeting requests and
  custom endpoints omit this preference.

## Rationale

A semantic provider acknowledgement preserves the full utterance while removing
unnecessary close-handshake waiting. Explicit model capabilities avoid silent
reasoning changes after model selection. Stage timings distinguish provider
latency from context extraction and insertion.

## Sources

See frontmatter and the regression tests in `Tests/SidekeyTests/AXContextReaderTests.swift`,
`Tests/SidekeyTests/OpenRouterLLMClientTests.swift`, and
`Tests/SidekeyTests/Streaming/BYOK/SonioxBYOKAdapterTests.swift`.

## Verification follow-up

A synthetic request to Gemini 3.8 Flash with `reasoning.max_tokens: 0` returned
HTTP 400: reasoning is mandatory for the endpoint. The same sample with effort
low and throughput sorting completed through Google AI Studio in 1.296 seconds,
with 0 reported reasoning tokens. This single sample demonstrates compatibility,
not a latency guarantee or proof that reasoning is disabled. OpenRouter documents
that Gemini 3 budgets map to thinking levels rather than precise token limits.
The endpoint catalog exposed AI Studio and Vertex variants but had null public
throughput/latency measurements, so no static fastest-provider claim is made.

Routing reference: https://openrouter.ai/docs/guides/routing/provider-selection

## Comments and objections

The original stall's provider/network cause is unknown. Manual finalization is
an independently verified improvement, not proof of that historical cause.
Additional silence is synthesized locally; no extra microphone recording occurs.

## Resolution

Implement the policy and regression tests. Public release validation is tracked
in the delivery task rather than asserted by this decision.

## Consequences

A cold catalog lookup may add up to its request timeout; later dictations reuse
cached capabilities. Optional reasoning can be disabled; mandatory reasoning
can only be reduced. The AX caller no longer waits for slow IPC to finish, but
an in-flight system call may outlive its caller until the next cancellation check.

## Supersedes / superseded by

Clarifies the caller-deadline guarantee of the 2026-06-17 AX timeout decision.
No superseding decision is known.
