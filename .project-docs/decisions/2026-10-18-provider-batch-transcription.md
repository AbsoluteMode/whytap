---
id: provider-batch-transcription-2026-10-18
type: decision
title: Batch transcription with the user's own provider
summary: Production binds ProviderBatchTranscriber to BatchTranscribing. A whole take goes to the provider chosen in Settings -> Models, with that provider's Keychain key, through its batch API (Soniox file API, Deepgram pre-recorded, ElevenLabs speech-to-text, self-hosted OpenAI-compatible /v1/audio/transcriptions). Without that choice or key it is unavailable; it never falls back to another provider.
status: confirmed
tags: [byok, transcription, resilient-delivery, privacy, soniox, deepgram, elevenlabs, self-hosted]
canonical_for: [batch-transcription-route]
verified_at: 2026-10-18
sources:
  - type: user-confirmed
    reference: 2026-10-18 brief from the Exodia meeting-notes session after the on-device models were removed. Bind a provider batch recognizer to BatchTranscribing with SelfKeyPreferences.selectedProvider and its BYOKKeyStore key. Never fall back to another provider. Respect BatchRecoveryDeadline. An empty result is silence. Never write transcripts or keys to os_log.
    confirmed_at: 2026-10-18
  - type: url
    reference: https://soniox.com/docs/stt/async/async-transcription
    confirmed_at: 2026-10-18
  - type: url
    reference: https://soniox.com/docs/stt/api-reference/transcriptions/delete_transcription
    confirmed_at: 2026-10-18
  - type: url
    reference: https://soniox.com/docs/stt/api-reference/files/delete_file
    confirmed_at: 2026-10-18
  - type: url
    reference: https://developers.deepgram.com/reference/speech-to-text/listen-pre-recorded
    confirmed_at: 2026-10-18
  - type: url
    reference: https://elevenlabs.io/docs/api-reference/speech-to-text/convert
    confirmed_at: 2026-10-18
  - type: repository
    reference: Sources/Sidekey/Streaming/BYOK/ProviderBatchTranscriber.swift
    confirmed_at: 2026-10-18
  - type: repository
    reference: Tests/SidekeyTests/Streaming/BYOK/ProviderBatchTranscriberTests.swift
    confirmed_at: 2026-10-18
related: [../project.md, 2026-10-18-remove-local-models.md, 2026-10-18-no-default-realtime-host.md, 2026-09-10-byok-and-local-builds.md, 2026-10-18-silent-meetings.md, 2026-11-19-on-device-dictation.md, 2026-11-19-provider-failure-reasons.md, 2026-11-20-elevenlabs-scribe-v3.md]
---

# Batch transcription with the user's own provider

## Context

After the on-device models were removed, production bound
`UnavailableBatchTranscriber` to `BatchTranscribing`. That left four paths
without a recognizer:

- the resilient-delivery batch rung, which was skipped, so a degraded Drop
  went straight to the raw partial or to "Couldn't deliver";
- Retry on "Couldn't deliver";
- the Drop recorder fallback;
- the agent's record-then-transcribe voice path.

Every BYOK provider the realtime path supports also has a batch API. The user
has already chosen one of them and stored its key.

## Decision

- `AppDelegate.batchTranscriber` is `ProviderBatchTranscriber()`. The same
  instance reaches `AgentController` through
  `BatchAgentAudioTranscriber(batch:)`. `UnavailableBatchTranscriber` stays
  as the default of `BatchAgentAudioTranscriber`, so a controller built
  without a transcriber never sends audio anywhere.
- The route (`ProviderBatchRoute.current`) exists only when the transcription
  level is Your key. It uses the selected provider and that provider's own
  Keychain key; anything else returns nil, which means unavailable
  (`isAvailable() == false`, `transcribe` throws
  `BatchTranscriptionUnavailable`). The route is read on every call, so a
  provider chosen later applies without a relaunch.

  | Provider | Request |
  |---|---|
  | Soniox | file API: `POST /v1/files`, `POST /v1/transcriptions` with `stt-async-v5`, `GET /v1/transcriptions/{id}` every 500 ms, `GET .../transcript` |
  | Deepgram | `POST /v1/listen` (pre-recorded), the WAV as the body, `Token` key, the selected model |
  | ElevenLabs | `POST /v1/speech-to-text`, multipart, `scribe_v2`, `xi-api-key` |
  | Self-hosted | `https://<realtime host>[:port]/v1/audio/transcriptions`, multipart with the user's model, `Bearer` authorization |

  OpenAI cannot be selected for transcription, so it has no route.
- Self-hosted keeps the host and port of the realtime base URL and uses
  `https`, whatever the scheme, because the realtime socket is always `wss`.
  A base URL without a host means not configured. This is the same no-default
  rule as the realtime URL (`2026-10-18-no-default-realtime-host.md`).
- Each request makes the same choices as that provider's realtime request:
  - the chosen language, or none for Auto;
  - Soniox hints that language plus `en`;
  - Deepgram sets `smart_format` and `punctuate`;
  - ElevenLabs sets `no_verbatim=true`.

  ElevenLabs batch also sends `tag_audio_events=false`: the batch API tags
  events such as "(laughter)" by default, and the realtime API does not tag
  them.
- Raw PCM16 from the delivery ladder is wrapped as a 16 kHz mono WAV. A
  canonical WAV from `AudioRecorder` is sent unchanged.
- The result is the trimmed text, and an empty transcript is silence. Errors:
  - a non-2xx answer is `httpStatus`;
  - a 2xx answer without the expected field is `malformedResponse`;
  - a failed Soniox job is `jobFailed`;
  - a Soniox job unfinished after `jobTimeout` (30 s) is `timedOut`.
- Every wait is cancellable: URLSession async calls, `Task.sleep` and
  `Task.checkCancellation` in the poll loop. `BatchRecoveryDeadline` (30 s)
  therefore ends any request or poll on the rung and on Retry. `jobTimeout`
  bounds Soniox polling on the recorder fallback and agent voice, which have
  no recovery deadline.
- Soniox deletes the take's audio after every outcome: success, failure,
  timeout and cancellation. The cleanup is detached from the take. It deletes
  the file first, then the job. If the job is still processing, Soniox answers
  `409`; that deletion is retried every poll interval until `jobTimeout`
  passes, then given up.
- Logs carry the provider, audio byte count, milliseconds, character count,
  failure labels (`http_<code>`, `malformed_response`, `job_failed`,
  `timed_out`, `cancelled`, `url_error_<code>`) and cleanup HTTP statuses.
  The file is in `LocalPathLoggingInvariantTests.guardedFiles`.
- `SonioxFileAPI` holds the base URL, the async model, the request builder and
  resource-ID parsing. `SonioxMeetingTranscriber` uses the same helpers;
  meeting behavior is unchanged.

## Why

- The user chose this provider and stored its key for exactly this audio.
  Sending the same take to the same provider does not change where the
  content goes. Using another provider or another stored key would. That is
  also why the retired Local route reads as not configured
  (`2026-10-18-remove-local-models.md`).
- Batch output replaces what the stream would have pasted. Different language
  handling or filler removal would give a different text for the same take.
- Silence is not a failure (`docs/decisions/2026-07-26-empty-batch-is-silence-not-offline.md`).
  Reporting it as one would show "Couldn't deliver", and Retry would upload
  the same silence again.
- `withBatchRecoveryDeadline` waits for its children after cancelling them. The
  deadline can only end a transcriber that cooperates with cancellation.
- Soniox keeps uploads and transcripts until they are deleted, and the take
  should not stay on the user's account. Per the Soniox documentation:
  - deleting a job does not delete its file;
  - deleting the file makes a queued job fail instead of starting;
  - deleting a job that is still processing answers `409`.

  Deleting the file first therefore removes the audio even while the job
  still runs.
- The cleanup is detached because the paste should not wait for remote
  deletions, and a take ended by the deadline must still delete.
- The ladder asks `isAvailable()` before the batch rung and before Retry. An
  unconfigured user therefore keeps the behavior of the unbound seam: the raw
  partial, then "Couldn't deliver" or idle
  (`docs/decisions/2026-06-24-deliveryfailed-escapable-and-retry-robust.md`).

## What we tested

- The tests were written first in
  `ProviderBatchTranscriberTests.swift`: 8 route, 21 adapter and 2 wiring
  tests, all through `StubURLProtocol`.
- The skeleton failed 37 assertions in 31 tests. Later, the Soniox `409` retry
  and give-up tests failed 20 assertions in 8 tests before the cleanup
  existed.
- Focused results after the implementation:
  - 45 tests, 0 failures, with only the 2 wiring tests still red: routes 8,
    adapters 21, `LocalPathLoggingInvariantTests` and
    `SonioxMeetingTranscriberTests` 13;
  - after the wiring: 147 tests, 0 failures. That run covered the wiring
    tests plus `DropBatchRecoveryTests`, `AppDelegateDropFlowRouteTests` and
    the `AgentController` suites.
- Mutations, each reverted byte for byte (SHA checked):
  - ignoring the transcription level failed
    `test_noChosenProvider_isNotConfigured_evenWithAStoredKey`;
  - borrowing another provider's key failed
    `test_selectedProviderWithoutKey_neverUsesAnotherProvidersKey`;
  - a fallback host for self-hosted without a base URL failed
    `test_selfHosted_withoutBaseURL_isNotConfigured`;
  - a request from an unconfigured transcriber failed
    `test_unconfigured_isUnavailable_andSendsNothing`;
  - a request that ignores cancellation failed
    `test_providerThatNeverAnswers_isEndedByTheRecoveryDeadline`;
  - deleting only after a finished job failed the rejected-job, timeout,
    give-up and recovery-deadline Soniox tests.
- Full suite `swift test` on `f3f9174` (main with #26 to #28) plus this
  change: 2,870 tests, 5 skipped, 0 failures (46.68 s). Before that sync, on
  `5105bfc`: 2,865 tests, 5 skipped, 0 failures. The skips are
  environment-dependent integration and view tests. No compiler warning falls
  on a changed line.
- Not verified: real provider accounts and keys (all HTTP is stubbed), the
  installed app, and a real degraded stream.

## Rejected

- Falling back to another stored key or a default provider: sends content to
  a provider the user did not choose.
- Deleting the Soniox job first: it fails with `409` while processing, and the
  file stays.
- Awaiting the Soniox cleanup inside the take: delays the paste, and a take
  ended by the deadline would skip it.
- Deepgram `detect_language` for Auto: the realtime request does not detect a
  language either, and the two paths should agree.
- Vocabulary terms in batch requests: realtime sends them (Deepgram `keyterm`,
  ElevenLabs `keyterms`, Soniox context terms), but batch v1 does not; left
  as a follow-up.
- A local fallback model: it was removed with the on-device models.

## Supersedes / superseded by

Supersedes the "Keep the batch seam" bullet of
[remove on-device models](2026-10-18-remove-local-models.md): production no
longer binds `UnavailableBatchTranscriber`. No superseding decision is known.

2026-10-18, PR https://github.com/AbsoluteMode/exodia/pull/29.
