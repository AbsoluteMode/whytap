---
id: remove-local-models-2026-10-18
type: decision
title: Remove on-device models and keep BYOK only
summary: Parakeet, MLX Qwen, the on-device diarizer and the local meeting pipeline are removed. Speech and text run only on providers or endpoints the user chose; a saved or default Local choice reads as not configured instead of switching to a provider.
status: confirmed
tags: [byok, local, models, privacy, settings, meetings, packaging]
canonical_for: [processing-routes, retired-local-route]
verified_at: 2026-10-18
sources:
  - type: user-confirmed
    reference: User instruction in the 2026-10-18 Exodia task to remove the local models for now and keep only BYOK; meeting speaker labels should come from the provider.
    confirmed_at: 2026-10-18
  - type: repository
    reference: Sources/Sidekey/Settings/SelfKeyPreferences.swift
    confirmed_at: 2026-10-18
  - type: repository
    reference: Sources/Sidekey/Streaming/BatchTranscribing.swift
    confirmed_at: 2026-10-18
  - type: repository
    reference: Sources/Sidekey/Meetings/MeetingBYOKProcessor.swift
    confirmed_at: 2026-10-18
  - type: repository
    reference: Tests/SidekeyTests/Settings/RetiredLocalRouteTests.swift
    confirmed_at: 2026-10-18
related: [2026-10-19-api-and-models.md, 2026-10-19-strict-drop-modes.md, 2026-10-18-legacy-model-cleanup.md, 2026-10-18-no-default-realtime-host.md, 2026-10-18-provider-batch-transcription.md, ../project.md, 2026-09-10-byok-and-local-builds.md, 2026-10-18-silent-meetings.md, 2026-11-11-drop-auto-stop.md]
---

# Remove on-device models

## Context

Settings -> Models offered two processing levels: Your key (the user's
provider key or their own OpenAI-compatible endpoint) and Local. Local meant
FluidAudio Parakeet TDT v3 for Drop and batch recovery, MLX
Qwen3-4B-Instruct for cleanup and meeting summaries, and the FluidAudio
diarizer for the fully local meeting pipeline. It needed Apple Silicon,
gigabyte-scale downloads, the mlx-swift package family and a 3.7 MB
`Resources/mlx.metallib` version-locked to mlx-swift and sealed into the
bundle. Local was the default on Apple Silicon when the user never chose.

On 2026-10-18 the user asked to remove the local models for now and keep
only BYOK. Meeting speaker labels should come from the provider (Soniox), not
from an on-device diarizer.

## Decision

- Remove Parakeet (Drop and batch recovery), MLX Qwen (cleanup and meeting
  summaries), the diarizer, the local meeting pipeline, the Local option in
  Settings -> Models, mlx-swift, mlx-swift-lm and their transitive packages,
  `Resources/mlx.metallib` and `scripts/build-metallib.sh`.
- Keep FluidAudio only for the meeting detector's Silero VAD.
- `TranscriptionIsolationLevel` has only `.yourKey`; `LLMIsolationLevel` has
  `.yourKey` and `.custom`. Both getters are optional. A stored `local`, or no
  stored level on Apple Silicon, reads as not configured even when a provider
  key is stored. Intel keeps its Your key default.
- Not configured: Drop opens Settings -> Models and records nothing. The
  original cleanup-to-Fast fallback is superseded by
  [strict Drop modes](2026-10-19-strict-drop-modes.md): Smart retains its
  transcript with an explicit failure and Retry. A recorded meeting stays staged as failed with
  "Add your own provider keys in Settings > Models to process this meeting."
  until both routes are chosen. Settings shows "not set up" banners.
- Keep the batch seam. Production binds `UnavailableBatchTranscriber` to
  `BatchTranscribing`, so the resilient-delivery batch rung is skipped, and
  Retry, the recorder fallback and agent batch voice have no recognizer until
  provider batch APIs are wired. Superseded: production now binds
  `ProviderBatchTranscriber` (see below).
- `LocalPathLoggingInvariantTests` now guards the provider paths that carry the
  same content: `OpenRouterLLMClient`, `MeetingBYOKProcessor` and
  `DirectProviderStreamingSession`. The class name stays because docs and the
  capability map reference it.

## Why

- The user chose BYOK only for now.
- A Local user chose, or defaulted to, audio and text that never leave the
  Mac. Switching them to a provider because a key happens to be in the
  Keychain would send that content off the device without their choice.
  Not configured is visible and recoverable: one Save in Settings restores
  dictation.
- Intel never had Local, so its default was always the user's key. Keeping
  that default does not change where an Intel user's content goes.
- Without MLX the dependency graph is FluidAudio and Sparkle, and the release
  no longer carries a metallib with its own Gatekeeper constraints.
- The meeting detector needs Silero VAD, which FluidAudio provides.

## What we tested

- `RetiredLocalRouteTests` (7 tests) was written before the migration: stored
  Local on any hardware, no level on Apple Silicon, the Intel default, Drop
  with a stored Soniox key, cleanup with a stored OpenRouter key, meetings,
  and choosing Your key afterwards. The migration cases failed before the
  change and pass after it.
- Mutation: treating a nil LLM level as `.yourKey` in
  `DirectLLMRouteResolver` failed
  `test_cleanup_withoutChoice_doesNotUseStoredOpenRouterKey`.
- Mutation: committing the picker value instead of the validated route on LLM
  save failed `testLLMSaveCommitsTheRouteThatWasValidated`. Both mutations were
  reverted byte for byte.
- After `swift package clean`, the build and the full suite passed: 2,825
  tests, 5 skipped, 0 failures (45.05 s). That is 131 fewer than the 2,956
  before: 22 on-device test files were deleted and local cases were removed
  from shared files; the 7 route tests were added. No compiler warning falls
  on a changed line.
- Not verified: the Settings -> Models banners on screen, an upgrade of a real
  former-Local install, and meeting processing with real provider keys.

## Rejected

- Migrate Local users to Your key when a key is stored: sends content to a
  provider without the user's choice.
- Keep Parakeet only for batch recovery: keeps the download, the Apple Silicon
  gate and the Core ML stack that were asked to go; provider batch APIs are
  the follow-up.
- Remove FluidAudio entirely: the meeting detector needs its Silero VAD.
- Delete the batch seam: provider batch transcription plugs into it.
- Delete previously downloaded model files on upgrade: not done here. The
  app no longer reads `LocalTranscriptionModels`, `LocalLLMModels` or
  `LocalDiarizationModels` under Application Support/Sidekey; cleaning them
  up is a separate decision. Decided later: a one-time launch cleanup,
  `2026-10-18-legacy-model-cleanup.md`.

## Supersedes / superseded by

The "Keep the batch seam" bullet is superseded by
[provider batch transcription](2026-10-18-provider-batch-transcription.md).
The rest of this decision stands.

2026-10-18, PR https://github.com/AbsoluteMode/exodia/pull/22.
