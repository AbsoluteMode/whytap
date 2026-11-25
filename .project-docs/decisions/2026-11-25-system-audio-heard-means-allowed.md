---
id: system-audio-heard-means-allowed-2026-11-25
type: decision
title: System audio counts as allowed once a capture has heard sound
summary: macOS has no public status check for System Audio Recording, so Settings always showed "?" and the Subtitles overlay offered "Open audio permissions" whenever the Mac was quiet, even with the grant given and Subtitles working. The first non-zero sample any capture hears is now remembered; from then on Settings shows Allowed and the overlay never suggests the privacy pane. Before that, the overlay waits 5 s of silence.
status: confirmed
tags: [permissions, system-audio, subtitles, meetings, settings, tcc]
canonical_for: [system-audio-permission-status]
verified_at: 2026-11-25
sources:
  - type: user-confirmed
    reference: In build 2.2.27 (1753) the user had allowed system audio and Subtitles heard the Mac, yet the overlay showed "Open audio permissions" under Stop and Settings showed "?" with "macOS asks at the first recording".
    confirmed_at: 2026-11-25
  - type: repository
    reference: Sources/Sidekey/Permissions/SystemAudioAccess.swift
    confirmed_at: 2026-11-25
  - type: repository
    reference: Sources/Sidekey/Meetings/CoreAudioSystemAudioSource.swift
    confirmed_at: 2026-11-25
  - type: repository
    reference: Sources/Sidekey/Translation/LiveSubtitleModel.swift
    confirmed_at: 2026-11-25
  - type: repository
    reference: Sources/Sidekey/Settings/Features/FeatureCatalog.swift
    confirmed_at: 2026-11-25
  - type: repository
    reference: Tests/SidekeyTests/Translation/SubtitleAudioAccessHintTests.swift
    confirmed_at: 2026-11-25
related: []
---

# System audio counts as allowed once a capture has heard sound

## Context

Build 2.2.27 (1753). The user had allowed System Audio Recording and Subtitles
translated the Mac's sound, but:

1. The Subtitles overlay, listening (Stop and close shown, no pairs yet),
   showed the link "Open audio permissions".
2. Settings -> Features -> Translate & Subtitles (and Meeting Notes) showed the
   System audio row with "?" and "macOS asks at the first recording".

The overlay showed the link whenever a session was listening and had not yet
received one non-zero sample, which is also what a granted but quiet Mac looks
like. The catalog returned `askedLater` for System audio unconditionally,
because macOS offers no public status check for TCC `AudioCapture`: a refused
grant opens the process tap without error and delivers exact zeros.

## Decision

- `SystemAudioAccess` remembers, in user defaults
  (`sidekey.systemAudio.heard.v1`), that some capture has heard sound.
  `CoreAudioSystemAudioSource` records it from its IO queue on the first input
  buffer with any non-zero sample, measured on the delivered PCM of every
  channel (interleaved or planar) before the channels are mixed to mono:
  opposite stereo channels average to zero but are sound. The first-proof
  write is serialized, so concurrent first callbacks notify once. That source is the only process tap in the
  app, so Subtitles, Meeting Notes, the meeting detector and the onboarding
  question all count.
- `FeatureSetupSnapshot.systemAudioHeard` feeds the catalog: System audio is
  `.met` (Allowed, check mark) once heard, `askedLater` before. Settings ->
  Features refreshes on `SystemAudioAccess.didChange`, posted once.
- `LiveSubtitleModel.silenceMayMeanNoAccess` drives the overlay link. It
  becomes true only when the session is listening, nothing was heard for 5 s,
  and no capture has ever heard sound on this Mac. The first sound clears it,
  and so does `SystemAudioAccess.didChange` when another capture (a meeting,
  the detector) proves the grant while the hint is already shown.

## Why

A non-zero sample is the only thing that proves the grant: without it the
tap delivers zeros only. Silence cannot prove a refusal (the Mac may just be
quiet), so the overlay waits before suggesting the pane, and never suggests it
once the grant was proven. The proof is remembered because a quiet moment
later says nothing new.

## Tested

- `SubtitleAudioAccessHintTests`: a quiet Mac heard before never shows the
  hint; silence before any proof shows it only after the delay; the first
  sound clears it; sound before the delay means no hint; proof arriving from
  another capture while waiting cancels it; proof from another capture clears
  an already visible hint; a new Start begins without it.
- `SystemAudioInputSignalTests`: +0.25/-0.25 interleaved float, planar float
  and interleaved Int16 stereo count as sound; exact zeros in every layout do
  not; one tiny sample in one plane does.
- `SystemAudioAccessTests`: the proof persists, only the first record
  notifies, 16 concurrent first records notify once (20 rounds).
- Build queue review 555 found the three gaps above (visible hint not cleared
  by outside proof, signal measured after the mono mix, racy first write);
  each now has a regression test.
- `FeatureCatalogTests`: System audio reads `.met` on Meeting Notes and
  Translate & Subtitles once heard, `askedLater` before, and never blocks.
- The live grant path (real TCC, real tap) was not exercised by tests; it is
  the user's acceptance in the installed app.

## Rejected

- Private `TCCAccessPreflight` through dlsym: it would read refusals and
  withdrawn grants, but it is undocumented SPI whose return codes and
  signature can change without notice; a wrong answer would show a false
  refusal. Not needed for the reported problem.
- Showing the link on any silence (the old rule): it contradicts a working
  grant every time Subtitles start before sound plays.
- Marking System audio allowed after the onboarding question: being asked is
  not the answer.

## Known limit

A grant withdrawn later in System Settings is not noticed: Settings keeps
Allowed and the overlay does not offer the pane. Re-allowing is done in System
Settings -> Privacy & Security -> Screen & System Audio Recording.

2026-11-25 · branch claude/system-audio-status
