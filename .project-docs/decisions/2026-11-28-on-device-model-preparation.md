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
  - type: user-report
    reference: On 2026-11-28 the owner installed 2.2.27 on a clean M1 MacBook and chose On this Mac for Drop, no keys. Every take said it was listening and pasted nothing; tens of minutes later, without changes, dictation started working. No log from the failing period.
    confirmed_at: 2026-11-28
  - type: repository
    reference: Sources/Sidekey/Streaming/OnDevice/OnDeviceSpeechModelStore.swift
    confirmed_at: 2026-11-28
  - type: repository
    reference: Tests/SidekeyTests/Streaming/OnDevice/OnDeviceModelPreparationTests.swift
    confirmed_at: 2026-11-28
related: [2026-11-19-on-device-dictation.md, 2026-11-21-on-device-everywhere.md, 2026-11-19-provider-failure-reasons.md]
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
  Downloading, then Preparing ("Getting the model ready to dictate. The
  first time can take a few minutes."), then Ready, which means loaded in
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

- A longer or no deadline on the take: the island would wait for minutes
  with no way out after release.
- Keeping the model loaded while a local route is selected: about 0.5 GB on
  an 8 GB Mac for an app that is mostly idle.
- Escape after release: the hold monitor sees Escape only while the key is
  held; a new global Escape tap for the waiting state was left for later.
- A load path that never downloads: it needs FluidAudio internals; the
  readiness check now keeps a take off half-written files instead.

2026-11-28, task 119.
