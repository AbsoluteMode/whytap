---
id: no-default-realtime-host-2026-10-18
type: decision
title: The self-hosted realtime route has no default host
summary: BYOKRealtimeURL returns nil for a missing, empty or unparseable base URL instead of falling back to api.openai.com. Drop, meeting processing and the Settings probe fail with their existing errors before any socket opens.
status: confirmed
tags: [byok, self-hosted, realtime, privacy, settings]
canonical_for: [self-hosted-realtime-url]
verified_at: 2026-10-18
sources:
  - type: repository
    reference: Sources/Sidekey/Streaming/BYOK/BYOKRealtimeURL.swift
    confirmed_at: 2026-10-18
  - type: repository
    reference: Tests/SidekeyTests/Streaming/BYOK/BYOKRealtimeURLTests.swift
    confirmed_at: 2026-10-18
  - type: trace
    reference: Full local swift test on main bbfc076 plus this change, 2,839 tests, 5 skipped, 0 failures in 48.160 seconds.
    confirmed_at: 2026-10-18
related: [2026-10-18-provider-batch-transcription.md, ../project.md, 2026-10-18-remove-local-models.md, 2026-11-22-openai-speech-provider.md]
---

# No default host for the self-hosted realtime route

## Context

`BYOKRealtimeURL.openAIRealtime(baseURL:)` builds the WebSocket URL for the
OpenAI Realtime protocol. Without a usable base URL it returned
`wss://api.openai.com/v1/realtime?intent=transcription`.

OpenAI itself is no longer a speech provider: `BYOKProvider.selectable` leaves
it out, and `selectedProvider` reads a stored OpenAI choice as Soniox. The
self-hosted route is the only live caller. Its callers rejected an empty base
URL but not one that `URLComponents` cannot parse, such as
`http://my host:8000`. Such a value reached the fallback:

- Settings → Models: Test connection, and the connection check that Save runs
  first, sent the self-hosted key using the `Bearer` scheme to api.openai.com. The key
  left for a third party even when OpenAI rejected it.
- If OpenAI accepted the key, the probe passed and the route was saved. Drop
  and meeting processing then streamed audio to api.openai.com, a provider the
  user never chose.

## Decision

- `openAIRealtime(baseURL:)` returns `URL?`. A nil, empty or unparseable base
  URL gives nil; there is no default host.
- `OpenAIRealtimeAdapter` takes the resolved `URL` instead of a base string.
- When the URL does not resolve, `TranscriptionSessionFactory` throws its
  existing `.missingBaseURL` and `MeetingBYOKProcessor` its existing
  `.missingSelfHostedBaseURL`, before any socket opens.
- `OpenAIRealtimeProbe` returns false without opening a socket, so Settings
  shows "Could not reach provider" and does not save the route.
- The unreachable `.openAI` case shares this path and now fails the same way
  instead of dialing OpenAI.

## Why

- Fail closed: a typo in a self-hosted URL must not send the key or audio to a
  third party. Invariant 3 allows speech only to the provider or endpoint the
  user chose.
- Nothing supported relied on the default: OpenAI is not offered for speech.
- Existing errors keep the existing user path: an unparseable URL now behaves
  like an empty one. Drop opens Settings → Models, and meeting processing
  fails with the same error as before.

## What we tested

- TDD, red first: 5 new or changed tests failed for the expected reasons. The
  URL tests got the api.openai.com URL instead of nil, the factory did not
  throw, and the meeting test reached `.noAudio` instead of
  `.missingSelfHostedBaseURL`.
- Green: the BYOKRealtimeURL, factory, meeting processor, adapter and Settings
  view model tests, 43 tests, 0 failures. No test opens a socket.
- Mutation: restoring the api.openai.com fallback in `openAIRealtime` failed
  6 of 14 focused tests: the three no-host URL tests, both factory tests
  (including the existing empty-URL one) and the meeting test; reverted.
- Full suite on main `bbfc076` plus this change: 2,839 tests, 5 skipped,
  0 failures (48.160 s).
- Not tested directly: the probe's nil branch. A red run of that test would
  have dialed api.openai.com, so the branch is covered only by the compiler
  (`URL?` must be unwrapped) and review.

## Rejected

- Keep the fallback and document it: it reaches a provider the user never
  chose.
- A new `invalidBaseURL` error: the user path would be identical, so it adds a
  case without changing behavior. The `.missingSelfHostedBaseURL` text still
  says "missing" for an invalid URL.
- Also reject a URL without a host now, as the custom text endpoint does: such
  a value fails to connect and reaches no third party. Tightening it changes
  what users can save, so it is a separate follow-up.

2026-10-18, PR https://github.com/AbsoluteMode/exodia/pull/28.
