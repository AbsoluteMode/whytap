---
id: drop-auto-stop-voice-guard-2026-11-13
type: decision
title: A quiet transcript ends an auto-stop Drop take only when the microphone is quiet too
summary: On build 1622 an auto-stop take was still cut at about 36 s of continuous speech, because the provider's live text stopped changing for longer than the quiet period while the user went on speaking. The quiet rule now also needs the microphone to have been quiet for that period, for at most 6 s.
status: confirmed
tags: [drop, dictation, auto-stop, elevenlabs, microphone-level]
canonical_for: [drop-auto-stop-voice-guard]
verified_at: 2026-11-13
sources:
  - type: user-confirmed
    reference: On 2026-11-13 the user reported that Whytap again stopped by itself after about 36 seconds.
    confirmed_at: 2026-11-13
  - type: trace
    reference: Build 1622 unified log, 2026-11-13. An auto-stop take started 17:18:43.455, an ordinary finish was requested 17:19:19.019 (35.6 s), the finish gate fired with reason=maxTail (no silence in the tail) and 402 characters were delivered. No degrade or transport event. Quiet period 1.5 s.
    confirmed_at: 2026-11-13
  - type: repository
    reference: Sources/Sidekey/DropAutoStop.swift
    confirmed_at: 2026-11-13
  - type: repository
    reference: Sources/Sidekey/AppDelegate.swift
    confirmed_at: 2026-11-13
  - type: repository
    reference: Tests/SidekeyTests/DropAutoStop/DropAutoStopTests.swift
    confirmed_at: 2026-11-13
related: [2026-11-12-drop-auto-stop-local-rule-only.md, 2026-11-11-drop-auto-stop.md]
---

# The microphone must be quiet too

## Context

After 2026-11-12 an auto-stop take ends only by `DropAutoStopRule`: the live
transcript stops changing for the quiet period. That decision left one thing
unverified: whether live text pauses for longer than the quiet period inside
continuous speech.

It does. On build 1622, with a quiet period of 1.5 s, a take was stopped by the
rule 35.6 s after it started, while the user was speaking: the finish gate
found no silence in the tail (`maxTail`). The stop was the ordinary one, so the
text up to that point was pasted. The time matches Scribe's segment cap of
about 36 s; the trace does not show the provider's events, so "Scribe holds
its live text back before the cap" is an inference from the timing.

## Decision

- `DropAutoStopRule` also receives the microphone level. A level at least
  0.15 (9 dB) above the quietest level heard in this take counts as a voice.
- With words already heard, the take ends when the transcript has not changed
  for the quiet period **and** no voice was heard within that period.
- Sound holds a quiet transcript open for at most 6 s
  (`DropAutoStopRule.voiceHoldLimit`). After that it is taken for the room
  (music, other people) and the take ends.
- The watcher feeds the loudest of the meter levels published since its
  previous 200 ms poll (`AppState.audioLevels`, 30 per second).
- The no-words rule (5 s) and the second press are unchanged.

## Why

- Live text normally trails the voice, so in an ordinary take the last text
  change is later than the last voice and the take ends at the same moment as
  before.
- It does not depend on how long a provider pauses or why: the speaker's own
  voice keeps the take open.
- Raising the quiet period instead would slow every stop and still guess the
  length of the pause.

## What was tested

- `testProviderHoldingItsTextBackDoesNotCutContinuousSpeech`: 3.4 s of voice
  with no new text from 33 s, quiet period 1.5 s: the take is kept, then ends
  1.5 s after the last text once the microphone is quiet.
- `testAQuietMicrophoneEndsTheTakeAfterTheQuietPeriod`: unchanged timing.
- `testSoundThatBringsNoWordsHoldsATakeOnlyUpToTheLimit`: 6 s.
- `testSteadyNoiseIsNotAVoice`, `testDroppedBuffersTeachNothingAboutTheRoom`,
  `testTheWatchPassesMicrophoneLevelsToItsRule`.

## Not verified

- A live auto-stop dictation longer than 36 s on the installed app.
- The 9 dB margin on real rooms and microphones: it is not calibrated. Too low
  delays stops by up to 6 s in a noisy room; too high cuts quiet speech during
  a provider pause.
- What the provider sends around its segment cap.

## Rejected

- A longer quiet period: slower every time, and the pause length is unknown.
- Reusing `StreamingFinishGate`'s 0.06 margin: tuned for a 450 ms tail, it
  would read small changes in room noise as a voice.
- No limit on the hold: any noisy room would keep the microphone on until the
  second press.
