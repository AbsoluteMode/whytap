---
id: whytap-translation-tools
type: decision
title: Text translation and system-audio subtitles inside Whytap
summary: Bring the standalone translator journeys into two native tools using the existing per-feature provider routes.
status: confirmed
tags: [translation, subtitles, system-audio, llm, tools]
canonical_for: [translation-tools]
verified_at: 2026-10-26
sources:
  - type: user-confirmed
    reference: On 2026-10-26 the user requested a full-width lighter upper input area, darker lower output area and an immediately focused caret.
    confirmed_at: 2026-10-26
  - type: user-confirmed
    reference: On 2026-10-26 the user rejected the visible input hint and blue border and required closing the text palette by clicking outside it.
    confirmed_at: 2026-10-26
  - type: user-confirmed
    reference: On 2026-10-26 the user requested only two text rows like the original translator and verification of subtitle translation behavior.
    confirmed_at: 2026-10-26
  - type: user-confirmed
    reference: On 2026-10-20 the user requested integration of Realtime Translator system-audio translation and its LLM translator into Whytap, with polished and reliable feature behavior.
    confirmed_at: 2026-10-20
  - type: user-confirmed
    reference: On 2026-10-20 the user requested both subtitle model roles in API and Models and chose a separate LLM for Subtitles instead of sharing text Translation.
    confirmed_at: 2026-10-20
  - type: repository
    reference: Sources/Sidekey/Translation/LiveSubtitleModel.swift
    confirmed_at: 2026-10-20
  - type: repository
    reference: Sources/Sidekey/Translation/TranslationService.swift
    confirmed_at: 2026-10-20
related: [../project.md, 2026-10-20-toolbox-mini-apps.md]
---

# Translation tools

## Context

The user requested both journeys from the standalone Realtime Translator:
floating system-audio subtitles and quick text translation. Whytap already has
system-audio process taps, speech adapters, Keychain storage, per-feature routes
and optional named tool hotkeys.

## Alternatives

Copying the standalone application's OpenAI endpoint, credential files and
independent hotkey registrar would create parallel setup and lifecycle paths.
Using the existing speech adapters followed by the configured text model fits
the application's current provider and key choices.

## Decision

Use two catalog tools, Translate and Subtitles, opening one native floating
window. Preserve the standalone RU/EN automatic text direction and offer
explicit targets. Keep original speech optional beside subtitles. The 2026-10-26
text layout uses only an input row (Return to submit) and a result/status row.
Saved explicit targets and secondary actions remain in the context menu; no
provider choice changes. See [design](../../docs/DESIGN.md) and the guide.

The implementation uses three routes: Translation (typed-text LLM),
Subtitles audio (real-time speech) and Subtitles translation (its independent
LLM). API & Models presents the latter two together as Subtitles, with Speech
and LLM controls. New routes start unset. Migration v2 preserves the exact
previous shared LLM/provider once for already configured subtitles; an existing
independent route wins, and later clears/changes never copy again. Partially
unreadable routing documents stay untouched at launch; their read-only effective
routes include the same v1 split, so valid configured subtitles keep using the
exact old LLM/provider before any edit. Their first explicit edit
retains the raw backup and splits routes before applying the user's change, so
an unset LLM or removed server cannot be repopulated at the next launch.
An explicitly stored but unreadable subtitle route remains unavailable; it is
never treated as an absent legacy setting eligible for this split.
Backup repair preserves the version
marker so restoring cannot refill an intentionally unset subtitle LLM.
Existing routes and layouts are preserved. This provider pipeline is an
implementation choice, not a user-selected provider or model.

## Rationale

A single setup, capture implementation and cancellation path avoid a second
credential store or app. Final-only phrase translation reduces redundant
requests. Bounded audio and phrase queues stop visibly when a provider cannot
keep up. Generation guards reject late responses after editing or cancellation.

Graceful Stop uses an opt-in terminal system-audio source. It stops and destroys
capture, waits for the serial IO queue, then ends stream subscriptions. Hardware
lifecycle operations share a lock so a previously dispatched route restart
cannot create a new capture after terminal shutdown. Queued callbacks retain
their capture generation until the barrier. The relay consumes source EOF
naturally, sends all retained PCM and only then calls the provider's endInput.
Cancelling that producer on Stop was proven to lose captured tail frames.
Immediate Cancel remains separate; ordinary meeting/VAD stop keeps subscriptions
open for reuse. Tests gate an in-flight conversion, queued source frames, a slow
provider send and the IO queue without creating a hardware tap.

## Sources

The request and source paths above; public usage and verification limits are
in [the translation guide](../../docs/translation.md).

## Comments and objections

Live provider quality and latency remain unverified until installed-app
acceptance. A two-stage pipeline has different latency from the standalone
OpenAI audio-to-translation model. No equivalence claim is made.

## Resolution

Keep provider choice explicit in API & Models. Expose errors and retry through
the native window; never substitute another model automatically.

## Consequences

Closing or sleeping stops capture and requests. App-initiated update restart
waits for translation. No system-audio recording or automatic translation
history is written to disk. Only the most recent forty subtitle lines remain.

## Supersedes / superseded by

None. Existing Drop translation and meeting recording contracts remain active.
