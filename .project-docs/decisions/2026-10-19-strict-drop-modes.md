---
id: strict-drop-modes-2026-10-19
type: decision
title: Honor Fast and Smart throughout a Drop take
summary: Fast bypasses the cleanup LLM. Smart never silently pastes raw speech after cleanup fails; it retains the transcript in memory and offers Retry with the original mode and target.
status: confirmed
tags: [drop, smart, fast, cleanup, retry, ux]
canonical_for: [drop-output-mode-contract]
verified_at: 2026-10-19
sources:
  - type: user-confirmed
    reference: 2026-10-19 request in the Drop troubleshooting chat. When Smart is selected it must actually use Smart and must not silently behave like Fast.
    confirmed_at: 2026-10-19
  - type: repository
    reference: Sources/Sidekey/DropOutputPolicy.swift
    confirmed_at: 2026-10-19
  - type: repository
    reference: Sources/Sidekey/AppDelegate.swift
    confirmed_at: 2026-10-19
  - type: repository
    reference: Tests/SidekeyTests/DropOutputPolicyTests.swift
    confirmed_at: 2026-10-19
related: [2026-10-21-smart-decisions.md, 2026-10-19-api-and-models.md, ../project.md, 2026-10-18-remove-local-models.md, 2026-10-21-smart-editor-prompt.md, 2026-11-11-wake-word.md]
---

# Strict Drop modes

The successful Smart output rule is extended by [Smart Decision routing](2026-10-21-smart-decisions.md): a confident clean verdict may skip editing. Failure and Retry rules below remain in force.

## Context

The user reported that Smart appeared to behave like Fast. The installed
implementation called cleanup in both modes and pasted the raw transcript
after a cleanup error. Empty cleanup and the partial-salvage rung could also
bypass Smart. Local diagnostics confirmed raw fallback after LLM errors;
they do not establish the cause of those provider failures.

## Decision

- Capture the mode when a take starts. A later preference change applies to
  the next take. Retry keeps the failed take's mode and target.
- Fast skips both the cleanup LLM and its Accessibility context read. Filler
  rules remain; their existing Fast-only empty-output safeguard remains.
- Smart requires a nonempty processed result, including after filler rules.
  An unavailable route, provider failure or empty result never auto-pastes
  the raw transcript. Keep the transcript only in memory and show an explicit
  Smart failure with Retry. Configuration errors open Settings -> Models;
  transient failures remain retryable in the island.
- Apply the same contract to full realtime transcripts, batch recovery and
  recovered partials. Recovery clears a retained take only after successful
  processing and delivery. A new take discards the old retry.
- Publish preference changes after persistence so the island's mode indicator
  follows changes from every mode control.
- Show the cleanup provider only during Smart processing (`verifying`).
  Pasting (`inserting`) shows “pasting…” without a provider mark, including
  when an OpenRouter route is configured in Fast.
- Error labels and logs contain fixed copy and numeric status codes, never
  provider error bodies, dictated text, keys or endpoint values.

## Alternatives and rationale

Automatic raw fallback preserves immediate delivery but misrepresents Smart.
An explicit “Use Fast” action could be added later; it is not implicit in Retry.
Retaining the transcript allows cleanup to be retried without recording the
same speech again or retranscribing retained audio.

## Sources and verification

The sources above define the mode policy and runtime wiring. Behavioral tests
cover mode routing, empty results, errors, mode changes, retained retry state,
partial recovery and the island's failure message. Provider-mark tests cover Fast insertion and the Smart-to-paste transition.
An installed-app test with real speech and the user's provider is a separate acceptance check.

Local verification on 2026-10-19: the final Swift suite passed 2,897 tests
with 5 skipped and 0 failures (49.149 seconds). Focused mode/provider-mark
tests passed 50/50. Guidance synchronization, customization doctor (12/12),
production packaging preflight and `git diff --check` passed. An earlier
dev candidate passed signature verification and `--installation-check`;
the final 2.2.13 production candidate and real-speech acceptance are separate
checks. No provider or model setting is changed by this fix.

The repository-wide documentation validator reports the same 15 findings on
the unchanged build commit and this candidate, with no new findings. They
concern older records' reciprocal links, a broken link, personal paths and
placeholder credential patterns. That global documentation check is not green.

## Comments and objections

The previous best-effort paste policy is superseded for Smart. Fast keeps its
existing filler-only output. No provider or model is substituted automatically.

## Consequences

Smart provider failures are visible and require Retry or a new take. Retained
transcripts do not survive application quit. Clipboard-only paste fallback
continues to use the already processed Smart result.

## Supersedes / superseded by

Supersedes the cleanup-to-Fast fallback clause in the local-model removal
decision. Its speech-route and meeting rules remain applicable. No later
decision is recorded.
