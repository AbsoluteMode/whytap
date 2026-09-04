# Local Drop live partials: bounded-window fresh-state re-decode

Date: 2026-06-27
Status: accepted
Context: ROO-257 (local STT — live partial transcript in the Dynamic Island)

## Problem

The perf pass (commit `701eb35`, "incremental partials") tried to make the live
partial transcript cheaper by feeding the Parakeet decoder only the audio that
arrived since the previous tick (~400 ms slices) and carrying a `TdtDecoderState`
forward across ticks. In practice the island showed 2-3 short, garbled words that
periodically reset and never accumulated.

### Root cause

FluidAudio's only public streaming-capable entry point, `AsrManager.transcribe(_:
decoderState:language:)`, routes single-chunk audio (≤ `maxModelSamples`,
240_000 samples / 15 s) through the **internal** `transcribeWithState`, which
hardcodes `isLastChunk: true`. That runs the TDT "last chunk finalization" loop
and then `TdtDecoderState.finalizeLastChunk()`, which **nulls** the carried
streaming context (`timeJump`, `predictorOutput`) every call. A 400 ms slice is
6_400 samples — always under the threshold — so every tick tore down the carried
state. Worse, a 400 ms slice is only ~5 encoder frames
(`samplesPerEncoderFrame` = 1280) with no preceding acoustic context, so each
slice decoded to a few wrong/empty boundary tokens that were then space-glued
into garbage.

The blessed FluidAudio streaming path (`SlidingWindowAsrManager`) feeds
**overlapping** 10-15 s windows and merges them with `transcribeChunk(previousTokens:)`
token dedup — but both `transcribeWithState` and `transcribeChunk` (the only APIs
that accept `isLastChunk: false`) are `internal` to the package and not callable
from Sidekey without forking it.

## Decision

Each partial tick, re-decode a **bounded trailing window** (the last ~14 s,
`partialWindowSamples = 224_000`, kept strictly below the 240_000 / 15 s
single-chunk threshold) of the captured buffer with a **fresh** `TdtDecoderState`
— the same stateless full-buffer `decode` path used for the on-stop final, just
handed a capped window instead of the whole buffer.

Because the window is always below `maxModelSamples`, every tick stays on the
constant-cost single-chunk encoder path (which pads input to 240_000 before the
encoder regardless of window length, so a 14 s window costs the same as the old
<15 s full-buffer decode that shipped in `e17c7db`) and never falls into the
O(buffer) `ChunkProcessor` multi-chunk path. That multi-chunk path was the actual
source of the ~6 s lag / CPU peg — it only ever triggered once a dictation passed
15 s. Capping the window below 240k samples structurally avoids it.

Cadence relaxed from ~400 ms to ~800 ms (`partialByteStride = 25_600`) so the
heavier per-tick decode finishes comfortably before the next tick; decodes stay
serialized (`await emitPartial`), so an overrun just drops ticks instead of
piling up. The `lastEmittedPartial` monotonic-length guard is kept so the
head-truncated island tail never visibly shrinks.

## Consequences

- For dictations under ~14 s the partial is the whole growing transcript
  (identical to the correct `e17c7db` behavior).
- For longer dictations the island shows a correct, growing transcript of roughly
  the last ~14 s — fine for a display-only ticker (matches the "виден ХВОСТ
  транскрипта" / head-truncation intent at `IslandAgentWingView.swift:189`).
- The on-stop final is untouched: a fresh full-buffer decode over the entire
  `capturedPCM16()`, so the pasted text is byte-identical to the batch path
  (locked by `testFinalTranscriptMatchesBatchDecodeOfFullAudio`).

## Alternatives rejected

- **Carried-state incremental (the `701eb35` approach):** corrupts the partial
  and cannot be done correctly through FluidAudio's public API (needs internal
  `transcribeChunk` + overlap + token dedup).
- **`SlidingWindowAsrManager` refactor:** the proper long-term streaming route,
  but a much larger change (new model-store wiring, AsyncStream plumbing, heavier
  10-15 s windows per tick) and unnecessary for a display-only partial. Flagged as
  a follow-up if true full-length live partials are ever required.
