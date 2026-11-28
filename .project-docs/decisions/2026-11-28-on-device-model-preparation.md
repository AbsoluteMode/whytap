---
id: on-device-model-preparation-2026-11-28
type: decision
title: The on-device speech model is prepared before the take, and a take never ends silently
summary: Parakeet's Core ML load (Neural Engine compilation, minutes on an older Mac the first time) is one shared preparation started after the download, at launch and on a route switch to On this Mac, and when a take begins. Settings says Downloading, Preparing, Ready. A released take waits at most 45 s under "preparing local model…", then ends with its reason and Retry over the kept audio. The loaded result is never thrown away.
status: confirmed
tags: [local, drop, models, settings, reliability]
canonical_for: [on-device-model-preparation]
verified_at: 2026-11-28
sources:
  - type: user-confirmed
    reference: On 2026-11-28 the owner installed 2.2.27 on a clean M1 MacBook and chose On this Mac for Drop, no keys. Every take said it was listening and pasted nothing; tens of minutes later, without changes, dictation started working. No log from the failing period.
    confirmed_at: 2026-11-28
  - type: repository
    reference: Sources/Sidekey/Streaming/OnDevice/OnDeviceSpeechModelStore.swift
    confirmed_at: 2026-11-28
  - type: repository
    reference: Tests/SidekeyTests/Streaming/OnDevice/OnDeviceModelPreparationTests.swift
    confirmed_at: 2026-11-28
related: [2026-11-19-on-device-dictation.md, 2026-11-21-on-device-everywhere.md, 2026-11-19-provider-failure-reasons.md, 2026-11-28-shot-ocr-warmup.md]
---

## Context

In 2.2.27 the model's state was a file check. Nothing loaded it before a
take, except the download itself. The take's first partial decode, about
0.8 s in, started `AsrModels.load`. That load is `MLModel(contentsOf:)`.
The first time it runs it compiles the model for the Neural Engine, and on
an M1 with 8 GB that can take minutes. The load ran under a 60 s deadline
inside a task group. A child the group cannot cancel still has to finish
before the group returns. So a slow load kept the take waiting until it
finished, then failed it and threw the loaded model away. The batch rung
loaded the model again under its own 30 s deadline, with the same group
problem. Meanwhile the island mapped `.transcribing` to the listening frame,
so after release it kept saying "listening…" for minutes. The take then
ended with "Couldn't deliver — offline" or no visible result. The next take
started the whole load again. Core ML keeps its compiled model in a system
cache, so each attempt got further, and once one load finished inside the
deadline dictation "started working by itself".

The readiness check also counted a model as present while it was still
downloading, because FluidAudio moves files into place one by one. A take
in that window loaded half-written files. FluidAudio answers a failed load
by deleting the folder and downloading it again.

## Decision

- One shared preparation per launch (`OnDeviceSpeechModelStore`). It starts
  when the files land, at launch and when a route switches to On this Mac
  (`OnDeviceSpeechWarmup`), when Settings shows the card, and when a take
  begins, so the load overlaps speech. A caller's wait ends on its deadline
  or on cancellation; the load goes on and its model is kept.
- The download fetches files only (`DownloadUtils.downloadRepo`); the Core
  ML load is the visible Preparing step. Settings and onboarding show
  Downloading, then Preparing with its time left (see the follow-up
  below), then Ready, which means loaded in
  this launch, or "didn't load" with Try Again.
- Route readiness is files in place and no download running.
- Partials skip an unloaded model. On release, a take whose model is not
  loaded shows "preparing local model…" and waits at most 45 s, then
  decodes the whole kept take. Past 45 s it ends with "Local model still
  preparing, retry soon" and Retry. A load failure ends with "Local model
  didn't load" and Retry, and opens Settings → Models once. Neither runs the
  batch rung; Retry waits at most 20 s, inside the 30 s
  `BatchRecoveryDeadline`. Meeting phrases wait without a limit.
- Timing and state only are logged (`com.rootwise.sidekey`,
  `on-device-speech`): preparing with reason, ready ms, preparation failed
  ms with error type and code, wait ended still preparing, waiting for the
  model, unloaded after idle, files in place ms. FluidAudio's own lines
  (`com.fluidinference`) name its compile and re-download steps.

### Follow-up the same day: never silent, and time left everywhere

- The field detail (Listening while held; after release the label went
  away, nothing pasted, no error) has its own scenario tests. With the
  model not ready a take ends only with text or a reason and Retry. One
  more empty path is closed: a model that loaded during the take and
  returns no text for audio at speech level (any 100 ms above about
  -34 dBFS) ends with "No text from local model, Retry" instead of
  silence. A quiet take stays silence (2026-07-26 decision unchanged).
- Download: percent from bytes plus a time left from the measured rate
  (details in "Download progress from real bytes" below). A failed download
  keeps "Check your connection and try again." with Download.
- Preparation: no progress signal exists, so the time left is the expected
  duration minus the elapsed time, with a moving bar and no percentage.
  Under a minute it says "Less than a minute left"; past the expectation
  "Taking longer than usual, still working". A preparation measured on this
  Mac replaces the table (x1.25 headroom); the first load after each
  download is a compile, later ones are reloads.
- Settings card, the onboarding source caption, a footer strip on every
  onboarding step ("You can continue; Drop works as soon as it's ready",
  then "Speech model ready · Drop works now"), the try step's message and
  the island's Retry message ("Local model: about N min left") read the
  same value. The island's wait label stays "preparing local model…": the
  take waits at most 45 s, so minutes there would mislead.

Proposed expected durations (seconds). One measurement exists (M4 Pro,
download plus first load 74 s, mostly download). The rest follows Neural
Engine compile reports and memory pressure on 8 GB Macs. **Needs a real
clean M1 measurement**; `on-device model: ready ms=` in the log gives it.

| Chip | 8 GB first compile | 16 GB+ first compile |
|---|---|---|
| M1 | 240 | 150 |
| M2 | 180 | 120 |
| M3 | 120 | 90 |
| M4 and later | 90 | 60 |
| unknown | 180 | 180 |

Pro, Max and Ultra: x0.75. Reload: 15 s on 8 GB, 8 s otherwise.

## Why

- Local audio is the truth: the take keeps its audio and either pastes it
  or ends with a reason and Retry. It never ends in silence.
- The expensive step happens once and early, not in the user's first take.
- A bound keeps the island from waiting forever; 45 s covers a normal
  first load on a slower Mac, and a longer one still lands in the
  background for Retry.
- Five-minute idle eviction stays (2026-11-19): after the first compile a
  reload takes about a second and now starts when the key goes down.

## What we tested

- `OnDeviceModelPreparationTests` (fake load and clock, no Core ML): a take
  during the download is not ready even with every folder present;
  Downloading, Preparing, Ready only after the load; a take right after the
  download joins the one load; a preparation slower than the wait keeps its
  model for the next take with one load in total; a load failure is
  reported and the next take tries again; cold launch shows Preparing; a
  warm model never waits or reloads; a cancelled caller leaves the load
  running; Remove during preparation keeps nothing; the session's visible
  wait, still-preparing, load-failed, warm and Escape paths; the ladder skips
  the batch rung and offers Retry with the reason; the island label; warm-up
  at launch and on BYOK ↔ On this Mac switches; a provider take never joins
  the model.
- Not measured on a clean M1: the real first compile time and whether 45 s
  covers it.

## Rejected

- A percentage for the preparation: Core ML gives none, a made-up one
  freezes at 99%.
- Minutes in the island's wait label: the take stops waiting at 45 s.

- A longer or no deadline on the take: the island would wait for minutes
  with no way out after release.
- Keeping the model loaded while a local route is selected: about 0.5 GB on
  an 8 GB Mac for an app that is mostly idle.
- Escape after release: the hold monitor sees Escape only while the key is
  held; a new global Escape tap for the waiting state was left for later.
- A load path that never downloads: it needs FluidAudio internals; the
  readiness check now keeps a take off half-written files instead.

2026-11-28, task 119.

## Download progress from real bytes

The owner's acceptance of build 1808 failed: the bar jumped from 4% to 97%
and the card said "99% of about 470 MB · About 1157 min left".

Recorded on 2026-11-28 with `OnDeviceDownloadProgressRecordingTests` (a
real download into a scratch folder): FluidAudio's `downloadRepo` reported
progress only when a file finished, 24 callbacks for 23 files. It passes
its progress delegate to the async `URLSession.download(for:)`, which never
calls `didWriteData`. The encoder weights are about 445 MB of 483 MB, so
the raw fraction went from 0.0244 to 0.4851 (our 4.9% to 97%) after 12.8 s
without a callback; on a slower connection that silence lasts minutes. The
old estimator then divided the remaining 1-3% by the rate of the small tail
files, whose bytes are tiny next to their per-request latency, and smoothed
seconds rather than rate, so the number grew into hours.

- `OnDeviceModelDownloader` fetches exactly the files FluidAudio would (its
  public registry, the required Core ML folders plus root `.json`/`.txt`
  files, the same request timeout and optional token), skips files in place
  and downloads the rest with a delegate-based task, reporting bytes about
  ten times a second. Recorded: 170 callbacks, no step above 1.2%. Files
  already on disk count in the first report, which is the estimator's
  baseline, so they never read as speed. The download ends when the last
  byte lands and Preparing starts at once.
- `OnDeviceDownloadRateEstimator` takes the rate only inside a continuous
  run of reports (a gap over 1 s starts a new run, as each file is a new
  request) within the last 5 s, smoothed by half. A number needs 8 reports
  in 2 s and is held 5 s across a gap; there is none before 4 s or the first
  percent, after 8 s without bytes ("Stalled. Check your connection."), at
  98% or more ("Almost done"), or above two hours.
- `OnDeviceDownloadReplayTests` replays the recorded sequences (FluidAudio's,
  a clean download, a partly cached one) with a stall inserted and a tail
  a hundred times slower.

## Launch order with Shot's recognizer

After a new build is installed, the speech model and Shot's Vision recognizer
(`2026-11-28-shot-ocr-warmup.md`) both compile in the system Neural Engine
compiler. Measured on an M4 Pro with fresh clients (2026-11-28): the speech
model alone was ready after 13.0-13.6 s; started together with the Vision
preparation it was ready only when Vision was, after 16.9-18.1 s (four runs,
no failure). Run one after the other, the speech model was ready after 13.1 s
and Vision 4 s later. `LaunchModelPreparation` therefore starts Shot's
preparation once the speech model's launch preparation has finished; without
a feature on this Mac it starts at once. A Copy text before that still
prepares Vision on demand.
