---
id: drop-auto-stop-2026-11-11
type: decision
title: Drop can stop by itself after one press; the wake word was removed
summary: With "Stop Drop automatically" on, a Toggle shortcut starts a take that ends when the speaker has finished (provider turn prediction on ElevenLabs scribe_v3_live, otherwise a quiet live transcript). The wake word tried the same day, with its on-device keyword spotter, was removed at the user's request.
status: confirmed
tags: [drop, dictation, auto-stop, elevenlabs, turn-prediction, wake-word, on-device-model]
canonical_for: [drop-auto-stop, wake-word]
verified_at: 2026-11-11
sources:
  - type: user-confirmed
    reference: On 2026-11-11, after trying wake word build 1617, the user asked to remove voice activation ("it did not impress") and keep the automatic end of speech as a mode started by the Drop key, saving the second press.
    confirmed_at: 2026-11-11
  - type: repository
    reference: Sources/Sidekey/DropAutoStop.swift
    confirmed_at: 2026-11-11
  - type: repository
    reference: Sources/Sidekey/Streaming/BYOK/ElevenLabsBYOKAdapter.swift
    confirmed_at: 2026-11-11
  - type: repository
    reference: Tests/SidekeyTests/DropAutoStop/DropAutoStopTests.swift
    confirmed_at: 2026-11-11
related: [2026-10-18-remove-local-models.md, 2026-10-19-strict-drop-modes.md]
---

# Drop auto-stop

## Context

A Toggle Drop shortcut needs two presses: start and stop. ElevenLabs
`scribe_v3_live` (the user's Drop route since 2026-11-11) can predict the end
of a speaker's turn, so the second press can go.

The same day a wake word was built and installed (builds 1617-1618): an
always-on on-device keyword spotter that started such a take by voice. The
user tried it and asked to remove it, keeping only the automatic stop.

## Decision

- **Opt-in switch** in Settings -> Other -> Recording, "Stop Drop
  automatically", off by default. It applies to a Toggle shortcut only: one
  press starts the take and it ends by itself; a second press still stops it at
  once. A hold shortcut is unchanged, because releasing the key is the end.
- **The take is an ordinary Drop take** through the same dispatcher: mode
  latch, permissions, paste target, island UI, Retry and resilient delivery.
- **End of speech.** `DropAutoStopRule` stops the take 2 s after the live
  transcript stops changing, or when no words arrive within 5 s of recording
  (under the session's 6 s silent-stall check). It is always an ordinary stop,
  never a cancel: the delivery ladder pastes nothing for silence, and a
  connection that dropped before the first word resolves `.degraded` and is
  recovered from the retained audio. The rule exists from the moment
  recording begins (`DropAutoStopWatch`): words that arrive before the
  watcher's first 200 ms poll count as speech, not silence. There is no extra
  time cap: a deliberate
  long dictation runs to the hotkey's own limit.
- **Provider turn prediction.** On ElevenLabs `scribe_v3_live` such a take
  asks for `commit_strategy=turn_prediction`; the provider's first commit with
  words is the terminal and resolves `.endpointDetected`, a legitimate finish.
  A closed socket in that mode is a transport error, never a turn end. Other
  models and providers keep manual commit and rely on the rule.
- **Finals are live text.** The streaming session publishes committed finals
  as live text, so a provider that sends words only as finals (Deepgram) is
  seen by the rule and by the island.
- **Not on a self-hosted server route.** It transcribes only after a commit,
  so nothing could show that the speaker has finished; the press starts a
  normal Toggle take there.
- **Timings are calibrated on real speech, without rebuilds.**
  `DropAutoStopTuning` reads two optional defaults when a take starts:
  `com.sidekey.drop.autoStop.quietSeconds` (0.5-5, default 2) and
  `com.sidekey.drop.autoStop.providerSilenceSeconds` (0.3-3, default 1.5, sent
  as `vad_silence_threshold_secs`). No UI until the values settle.

## Why

- The key press is deliberate, so none of the wake word's safeguards are
  needed: no focus evidence, no always-on microphone, no false triggers.
- Reusing the Drop dispatcher keeps every Drop contract instead of a parallel
  dictation path.

## The wake word, and why it was removed

Built on sherpa-onnx keyword spotting with a bundled 3.3M English model. It
worked technically (the phrase was heard) but:

- the English model heard the user's "whytap" as "wait up" or "right up", so
  phrases had to be tuned per voice, and common-word phrases misfire;
- a trigger nobody pressed needs positive evidence of an editable field, which
  Electron apps do not give without being asked for their accessibility tree;
- it held the microphone open all day, which also made the builder's meeting
  gate read the Mac as busy;
- it added about 80 MB to the universal app.

The user judged the voice start not worth it. Removed with it: the listener,
the sherpa-onnx and ONNX Runtime binary targets, `Resources/WakeWord`, the
Settings card, the strict focus rule in `PasteTargetValidator`, the app-control
`wakeWordPaused` setting and the builder step that used it. Invariant 3 is back
to a single permitted on-device model, Silero VAD.

## Not verified

- `turn_prediction` against a live ElevenLabs socket (LIVE-VERIFY in
  `ElevenLabsRealtimeURL`). A rejected parameter degrades to batch recovery.
- Whether `scribe_v3_live` force-commits a segment at about 36 s under turn
  prediction; if it does, a longer auto-stop dictation ends there.
- The timings on real speech; they are the defaults from the wake word trial.

## Rejected

- A third value of the shared `HotkeyGesture` enum: it is also used by the
  Agent shortcuts, whose pickers and switches would gain a meaningless option.
- A fixed time cap on such a take: the press is deliberate.
- A local voice-activity detector for the end of speech: the live transcript
  is already there for every provider and needs no second audio path.

2026-11-11, branch `claude/drop-auto-stop`.
