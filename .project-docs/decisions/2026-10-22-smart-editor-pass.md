---
id: smart-editor-pass-2026-10-22
type: decision
title: Let the Smart editor pass ready messages in one request
summary: Remove the separate Jev/OpenAI Decision stage; the selected text model returns a reserved pass verdict or a conservatively edited message.
status: confirmed
tags: [smart, dictation, pass, sol, jev, latency, migration]
canonical_for: [smart-pass-routing]
verified_at: 2026-10-22
sources:
  - type: user-confirmed
    reference: On 2026-10-22 the user requested removing Jev and letting Sol return pass when changes are not important or useful, to deliver ready messages faster.
    confirmed_at: 2026-10-22
  - type: repository
    reference: Sources/Sidekey/PostProcessor.swift
    confirmed_at: 2026-10-22
  - type: repository
    reference: Sources/Sidekey/AIRouting/AIRoutingStore.swift
    confirmed_at: 2026-10-22
  - type: repository
    reference: Tests/SidekeyTests/SmartEditorPassTests.swift
    confirmed_at: 2026-10-22
  - type: url
    reference: https://developers.openai.com/api/docs/guides/prompt-engineering#message-roles-and-instruction-following
    confirmed_at: 2026-10-22
related: [2026-10-21-smart-decisions.md, 2026-10-21-smart-decision-calibration.md, 2026-10-21-smart-editor-prompt.md, 2026-10-21-smart-destination-formatting.md, 2026-11-20-smart-ready-text.md, 2026-11-24-smart-destination-line.md]
---

# One Smart editor request

On 2026-11-20 the editing criteria below were superseded by
[Smart returns a ready text](2026-11-20-smart-ready-text.md); the rest of this
record stands as history.

## Decision

Smart calls only the configured cleanup model. Keep its exact provider/model
and pin; do not choose another model or issue a second classifier request.
The user currently selects GPT-6 Sol through OpenRouter's openai/fast endpoint.
The same response contract works through the existing text adapters.

The editor returns either a full conservatively edited message or the exact
whole-response marker `<WHYTAP_PASS>`. Ordinary `pass`, `PASS` and numeric `0`
remain content: treating those as control would collide with legitimate text.
On a valid marker, use the retained transcript, with `usedEditor = false` and
plain delivery, including in rich destinations. An identical echoed transcript
also keeps that provenance. Existing local filler/output handling is retained.
Do not parse literal Markdown on a pass. A reserved marker mixed with prose or
partially emitted without an original literal reference fails into Retry.

Ask for pass when editing would only replace valid synonyms, rearrange words,
formalize tone or change minor punctuation/spacing preferences. Correct actual
recognition, spelling, grammar, duplication and self-correction errors. Long
multi-topic or explicit parallel requirements still benefit from paragraphs or
lists, preserving wording, thought order and all independent meaning. Already
structured messages do not need rewriting just because they are long.
Destination formatting rules do not force an otherwise unnecessary edit.

Output-language conversion always returns text; a pass marker is a failed
translation and reaches Retry. Empty/error/refused/cancelled requests cannot
silently paste raw content. There is no second call or automatic model fallback.
Inputs and screen references remain untrusted data inside the existing envelope.
No new transcript/response logging or telemetry is added.

## Remove the independent stage

Remove the Decision row from Drop Smart, the built-in Jev recommendation,
both Decision endpoint adapters and their probe. Generic Decision capability
metadata remains so cached/live non-generative models are still excluded from
text/agent pickers. Preserve the old `dropSmartDecision` enum raw value only to
decode historical usage/archives; omit it from active features, reject control
requests for it, and prevent route selection or resolution.

Routing migration 4 removes only the old Decision route and its migration
snapshot, preserving the selected cleanup/speech/agent routes, provider pins,
servers and keys. It is idempotent, works after restoring an older readable
archive, and never adds Jev on a new installation. Partially unreadable routing
documents are not rewritten at launch; the retired route is still unavailable
in memory, and the existing preserved-copy policy remains intact.

## Verification and limitations

Synthetic tests cover one editor call, pass provenance, rich-destination raw
delivery, ordinary pass/zero text, useful edits, translation, malformed markers,
empty/error/cancellation behavior, route retirement and legacy usage decoding.
Paid, user-authorized model acceptance is separate from automated tests; private
inputs/results stay in ignored local build output. No real recording, clipboard
mutation or native app launch is part of these tests.

Removing Jev eliminates its network round trip. A short pass response avoids
regenerating the transcript; the remaining request still has provider, prompt
processing and network latency. This does not promise instantaneous delivery or
perfect editorial judgments. Physical dictation/paste acceptance and the
builder's installed-source verification remain separate from source checks.

### Model acceptance

Evaluate exact `openai/gpt-6-sol`, pinned to `openai/fast`, no provider fallback,
temperature 0.1 and reasoning off. The final base prompt SHA-256 is
`8d0e4960778c3936ba6409e2b9ad01cb0ad5f23d922db998a1c47c734ad2768d`.
One generation each for 26 authorized actual dictations, 19 synthetic controls,
and eight additional destination/instruction-boundary controls. Historical
screen context was not retained; the additional context examples are synthetic.
Private texts, responses and exploratory candidates remain local and ignored.

On the final 53 generations all requests succeeded with the exact selected model
and normal stop. The 13 actual repair/structure examples entered editing; 12 of
13 already-usable actual messages passed. One still received an optional small
wording addition: the model's editorial judgment is not perfect. All five short
synthetic repair controls edited, all three long structure/literal controls
edited, and the translation returned text. A literal numeric zero was echoed
unchanged and correctly handled as original text rather than a control command.
The eight destination checks preserved pass for ready Telegram/technical text,
formatted long Telegram/GitHub messages, retained uncertainty in a grammar repair,
and kept transcript/context instructions as data. These are reused development
examples, not an independent accuracy estimate or physical paste acceptance.
