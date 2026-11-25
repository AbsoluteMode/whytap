---
id: subtitle-pairs-close-speed-2026-11-23
type: decision
title: Subtitle pairs that keep a joined sentence, × and Stop that act at once, and where the delay comes from
summary: When the speech-translation model joins a short sentence to the one before it, the pairer keeps that sentence with the translation, choosing among the original's sentence ends by the session's own length ratio and translation delay instead of a fixed 5 s gap. × and the session button take their click in the panel's sendEvent from measured frames. Stop shows the stopped overlay at once while the last translation settles in the background. Audio is sent off the main actor, caption changes are batched with an 80 ms interval, and a held last word can appear on the first flush after 0.3 s. Most of the delay is the model's; a numbers-only log now shows where it grows. Showing the original as heard is a one-constant switch left to the user.
status: confirmed
tags: [translation, subtitles, overlay, latency]
canonical_for: [subtitle-pairs-close-speed]
verified_at: 2026-11-23
sources:
  - type: user-confirmed
    reference: On installed build 1733 the user reported, relayed by the orchestrating session with a screenshot, that × in the running Subtitles overlay does not close it, that the left and right columns do not match (the original "Just to show you that it's not very scary." stood beside the next sentence's translation, and that sentence's translation ("nothing scary") stood one row above), and asked what could make subtitles faster.
    confirmed_at: 2026-11-23
  - type: user-confirmed
    reference: The user observed that translation appears almost at once when a video starts and then falls behind, and asked that Stop show its result at once.
    confirmed_at: 2026-11-23
  - type: repository
    reference: Sources/Sidekey/Translation/SubtitleSpeechPairer.swift
    confirmed_at: 2026-11-23
  - type: repository
    reference: Sources/Sidekey/Translation/SubtitleOverlayHitTargets.swift
    confirmed_at: 2026-11-23
  - type: repository
    reference: Sources/Sidekey/Translation/LiveSubtitleModel.swift
    confirmed_at: 2026-11-23
  - type: repository
    reference: Sources/Sidekey/Translation/TranslationView.swift
    confirmed_at: 2026-11-23
  - type: repository
    reference: Tests/SidekeyTests/Translation/SubtitleLecturePairingTests.swift
    confirmed_at: 2026-11-23
  - type: repository
    reference: Tests/SidekeyTests/Translation/SubtitleOverlayCloseTests.swift
    confirmed_at: 2026-11-23
  - type: repository
    reference: Tests/SidekeyTests/Translation/SubtitleDisplayLagProbeTests.swift
    confirmed_at: 2026-11-23
  - type: repository
    reference: Tests/SidekeyTests/Translation/OpenAITranslateRecordedSession.swift
    confirmed_at: 2026-11-23
  - type: repository
    reference: docs/bugs/2026-09-04-island-answer-close-first-mouse.md
    confirmed_at: 2026-11-23
related: [2026-11-23-subtitle-steady-overlay.md, 2026-11-21-subtitle-speech-translation.md, 2026-11-23-subtitle-realtime-audio.md, 2026-11-24-click-to-copy-translation.md, 2026-11-25-subtitle-overlay-move-resize-scroll.md, 2026-11-25-subtitle-soniox-live-original.md]
---

# Subtitle pairs that keep a joined sentence, × and Stop that act at once, and where the delay comes from

## Context

Reports on build 1733:

- **×.** While Subtitles ran over a video, × beside Stop did not close the
  overlay.
- **Pairs.** In a lecture the model translated two sentences as one ("I mean,
  these are the kinds of expressions. Just to show you that it's not very
  scary."). The pairer kept only the first sentence with that translation.
  The second moved to the next row, beside the next sentence's translation,
  and every later row could stay one sentence off.
- **Speed.** Translation appears almost at once when a video starts, then
  falls behind. What makes it slow, and what can be sped up?
- **Stop.** Stop takes long to show its result.

A council of three models (Fable, Opus, Astra) read the code on origin/main
494f0ff3 in parallel. This record says where its findings were taken and
where they were not.

## Decision

- **A joined sentence stays with its translation.** At a translation's cut,
  the original's sentence ends heard by then (up to 0.4 s later, since the
  period arrives with the next word) are candidates. Ends 5 s or more before
  the cut are always taken, as before. Among the rest the pairer takes the end
  this translation fits best (`SubtitleSpeechPairer.mergeScore`). Two
  measures go into the fit, each against the session's own settled pairs:
  - the translation's length against the original's, using the session's
    ratio (starting at 1.0);
  - how far the translation ended after that sentence end, against the
    session's median delay (starting at 1.5 s).

  A miss of a third in the ratio weighs as much as a miss of a second in the
  delay.
- **× and the session button act through the window.** The panel's
  `sendEvent` checks a mouse-down against the frames that × and the
  Stop / Start / Cancel button measured (`SubtitleOverlayHitTargets`). The
  click acts on mouse-up inside the same button, as the island does. A press
  belongs to the one button view, action and frame it began on, and acts only
  if all three are unchanged and the panel still shows. Leaving the button,
  hiding the panel or a new mode cancels it. Because SwiftUI never sees the
  press, the pressed button dims itself; × also shows its 28 pt target on
  hover. The SwiftUI buttons stay for their look, keyboard and VoiceOver. The running overlay
  also keeps its controls for 1 s after hover ends
  (`TranslationView.controlsLinger`). × has a 28 pt target and no tooltip.
- **Stop shows its result at once.** Stop ends capture and the overlay shows
  the stopped box in the same moment: the controls above the pairs, Start in
  place of Stop, no spinner (`SubtitlePhase.isRunning`). The last
  translation keeps settling in place in the background. Start during that
  time drops the tail and starts a new session once the old one is
  released. That waiting Start is tracked: closing the overlay, sleep or any
  cancel before it begins drops it, so no session or capture opens behind a
  closed overlay. The 10 s watchdog still names
  a provider that never finishes.
- **Audio off the main actor.** Captured audio is sent from a detached task,
  so a busy caption never holds it back.
- **Batching caption updates.** A delta publishes the caption if 80 ms
  have passed since the last flush (`LiveSubtitleModel.publishInterval`).
  An independent timer also flushes every 80 ms.
- **A held word can appear after 0.3 s.** The translation's last word is held
  back until the next delta shows it was whole (a third of the recorded deltas
  continue a word). Once nothing has followed it for 0.3 s
  (`SubtitleSpeechPairer.wordHold`), the next flush shows it: the 80 ms
  flush timer can add up to one tick. If the session then breaks off, that
  word may be a fragment and goes.
- **A numbers-only delay log.** On arrival of each delta, the adapter logs how
  far the model's `elapsed_ms` trails the audio sent so far
  (category `openai-realtime-translate`). `LiveSubtitleModel` logs the same
  when it processes a translation delta (category `subtitles`). No text,
  keys or audio are logged.
- **Original as heard: the user's choice, off.**
  `SubtitleSpeechPairer.liveOriginalAsHeard` switches the live row's original
  between in step with its translation (now) and as heard.

## Why

- **Pairs.** The two streams share only the audio clock. A short sentence
  can end before the previous translation does whether or not the model
  joined it, so the timing alone cannot decide. A joined translation is about
  as long as both sentences and ends its usual delay after the second; a
  translation of the first alone is shorter and ends its usual delay after the
  first.
- **×.** docs/bugs/2026-09-04-island-answer-close-first-mouse.md traced this
  on the island: on an inactive app's non-key panel, the AppKit-to-SwiftUI
  bridge drops the first-mouse click. `acceptsFirstMouse` on the hosting view
  never runs, because hit-testing returns SwiftUI's internal view. The
  overlay floats over a video in another app: the same case. The earlier
  test only checked that `acceptsFirstMouse` returns true, and a click sent
  straight to the window skips the activation path, so neither proves a
  click.
- **Stop.** The recorded provider took 5.7 s from session.close to
  session.closed, and the overlay showed a spinner all that time.

## Where the delay comes from

From the recorded live session (`OpenAITranslateRecordedSession`, 37.7 s of
synthetic speech, 2026-11-21), an offscreen replay and the code:

| Stage | Delay | Source |
|---|---|---|
| Capture and 200 ms frames | up to 0.2 s, about 0.1 s on average | `OpenAIRealtimeTranslateAdapter.frameBytes`; OpenAI recommends 200 ms frames, and the model reports positions in 200 ms steps |
| Model: translation behind the original | 0.4 to 3.0 s at sentence ends (median 2.4 s) | `elapsed_ms` of the translation's period minus the original's |
| Model and network: a delta after its audio | grew from 2.3 to 4.0 s over 40 s | arrival time minus `elapsed_ms`; see below |
| Original column, in step with its translation | the translation's delay above, 0.4 to 3 s | `SubtitleSpeechPairer.liveSourceHead` (#422) |
| Whole-word hold | median 0.21 s, at most 0.68 s; at a pause up to the 1.2 s cut | gap to the next translation delta; now capped at 0.3 s |
| Arrival to published caption | median 6 to 17 ms in every 15 s of a 180 s replay, not growing; p95 0.4 to 0.55 s, which is held fragments | `SubtitleDisplayLagProbeTests`: real overlay panel off screen |
| Main thread | 50 ms ticks late by a p95 of 2 to 6 ms over 180 s | same replay |

- **The growth in the recording does not prove a growing model delay.** The
  recording's probe slept 100 ms after each send, so its audio ran about 4 %
  slower than real time. That alone makes arrival minus `elapsed_ms` grow by
  about 1.7 s in 40 s. The probe now sends on an absolute schedule and logs
  the audio sent with every event.
- **The display does not queue in the replay.** The caller sees the same
  10 ms from arrival to publish in minute three as in the first seconds.
  Offscreen, the panel draws no animation frames, so the cost of drawing on
  screen is not covered. The new log covers that in the app.
- **Where it can grow.** Only at the provider (`trail_ms` rising in the
  adapter's log), or on the main actor before processing (`trail_ms` in the
  subtitles log rising faster than in the adapter's). The audio relay holds
  at most 128 capture buffers (about 1.3 to 2.7 s) and stops the session
  visibly beyond that.

RealtimeTranslator, the reference the user compares against, runs the same
model. It shows only a translation that grows, at most every 70 ms, without
animation, from audio sent per capture buffer off the main thread. It has no
originals, so nothing can be paired wrong.

## Council findings

Taken:

- the pairing cause;
- × through the window;
- audio off the main actor;
- throttled publishing;
- the original-as-heard switch as the user's choice.

Not taken:

- **Removing `mergeLag` and returning a trailing sentence to the previous
  row.** That moves a sentence already shown in the live row up into the
  settled row: shown text would leave its row. The fit above decides before
  the row settles. It still keeps the 5 s rule for sentences that surely
  belong.
- **Animating only new rows.** Text that wraps to a new line would push the
  older lines up in one jump. The steady overlay (2026-11-23) chose the
  0.3 s motion, and the replay found no main-thread cost to remove.
- **"The model's delay grows 0.4 to 3-4 s in 40 s."** This is the probe's
  slow pacing, as above. Not refuted either: the live log decides.

## Original as heard (the user decides)

`SubtitleSpeechPairer.liveOriginalAsHeard`:

- **false (now).** The live row's original appears only as far as its
  translation has reached, 0.4 to 3 s after it is heard. A word shown never
  moves to another row.
- **true.** It appears as heard, up to its first sentence end.

In the sixty generated lectures both give the same pairs (47 of 720 rows
misaligned). As heard, one row of 720 lost shown words to the next row. The
lectures do not model a translation that splits one original sentence into
two pairs. The build queue's #460 case was that split, and there the shown
words would move.

## What was tested

- `SubtitleLecturePairingTests` streams lectures like the model does: words
  in 200 ms steps, each period arriving with the next word, translations
  trailing their originals.
  - The user's case: a joined short sentence stays with its translation.
    This test fails on the previous pairer.
  - The opposite case: a short sentence with its own translation starts the
    next row.
  - Sixty lectures: sentences of 2 to 20 words, translations 0.75 to 1.4 times
    as long, a delay drifting between 0.4 and 3 s, and every fourth
    translation joining two sentences. The previous pairer misaligned 519 of
    720 rows (one miss shifts every later pair); the new one misaligns 47
    (6.5 %), mostly a two-word sentence beside a 3 s delay. Weights tried:
    length 0.2 to 0.5 per point and delay 0.7 to 1.5 s per point gave 45 to
    64. Length alone gave 121, delay alone 48. In step with its translation,
    no shown original moved.
  - A last word is shown after 0.3 s without a following delta.
- `SubtitleOverlayCloseTests`: on the overlay panel far off screen, the
  frames × and Start measured take the click in `sendEvent`. A press that
  leaves the button does nothing, Start starts, and × closes. A press whose
  action changes, or whose panel hides, does nothing.
- `SpeechTranslationTests`: Stop with a provider still finishing is no
  longer running in the same moment, shows the stopped box, and settles the
  tail after. Start during the finish closes the old session and opens a new
  one.
- `SubtitleDisplayLagProbeTests` (opt-in, `WHYTAP_SUBTITLE_DISPLAY_PROBE=180`)
  gave the replay figures above.
- The earlier steadiness and pairing tests pass, including the recorded
  session.

Not checked:

- a real pointer on the running overlay;
- a real lecture;
- the live delay log. The paid probe needs the OpenAI key through Case,
  which refused this session.

## After the build check (ticket #483)

The build queue found three problems in the first version:

- **A Start that ran after closing.** Start during Stop's tail queued a
  restart that a later close did not cancel, so OpenAI and capture could
  reopen behind a closed overlay. Now `cancel()` drops it.
  `testClosingWhileAStartWaitsForTheOldSessionStartsNothing` fails without
  this.
- **A press resolved at mouse-up.** The press kept only the control's kind,
  so Stop pressed and released over Start fired Start, and × fired after its
  panel hid. A press now holds its view, action and frame (above).
  `testAPressActsOnlyOnTheActionItBeganOnWhileThePanelShows` covers both
  cases, leaving and coming back, and the pressed look.
- **A test that sampled on time.** The steadiness replay read the caption
  12 ms after each event; with throttled publishing it could miss the last
  row. It now waits until the caption reflects each event
  (`LiveSubtitleModel.publishedEvents`).

## After the second build check (ticket #484)

A press begun on Start, a session started meanwhile by something else, and
a mouse-up before SwiftUI redrew the button: the button's action was chosen
from the live phase at mouse-up, so it ran Stop. The session button's
window action is now bound to the action drawn:

- Start only starts while nothing runs.
- Stop and Cancel only act on the session they were drawn for.

`testAPressBegunOnStartNeverStopsASessionStartedMeanwhile` (the queue's
fixture) fails on the previous head.

## After the third build check (ticket #485)

Cancel and Stop still shared one action, and the model chose cancel or the
graceful Stop from the phase at mouse-up. A press begun on Cancel, the same
session connecting meanwhile, and a mouse-up before SwiftUI redrew the
button ran the graceful Stop. The button's action is now a value,
`SubtitleSessionAction` (`start`, `cancel(session)`, `stop(session)`), read
from `LiveSubtitleModel.sessionAction` when the button is drawn.
`LiveSubtitleModel.perform` runs it only while it equals the action the
model shows now, so the phase and the session are both checked. A press
whose action is no longer shown does nothing.

`testAPressBegunOnCancelNeverStopsTheSessionThatConnectedMeanwhile` (the
queue's #485 fixture) fails with the shared action and passes with this one.

## Rejected

- A shorter merge gap alone: a short sentence with its own translation
  would join the previous row.
- Pairing by length alone: single-sentence ratios spread from 0.75 to 1.41
  in the recording, so length alone misaligned 121 of 720.
- Showing every delta at once, as RealtimeTranslator does: a third of the
  deltas continue a word, and a word that grows past the line end jumps to
  the next line.
- `acceptsFirstMouse` and click-catching views alone, for the reasons in the
  island bug record.
- Keeping the spinner until the provider closes: up to 10 s with no visible
  result of Stop.

2026-11-23 · branch claude/subtitles-close-pairs-speed
