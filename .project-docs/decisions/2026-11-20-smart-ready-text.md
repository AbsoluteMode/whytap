---
id: smart-ready-text-2026-11-20
type: decision
title: Smart returns a ready, structured text instead of minimal repairs
summary: The Smart editor cleans dictation of everything unneeded, merges repeats and lays the text out in blocks; the pass verdict is kept only for text that is already clean.
status: confirmed
tags: [smart, dictation, prompt, editing, structure, pass]
canonical_for: [smart-ready-text]
verified_at: 2026-11-20
sources:
  - type: user-confirmed
    reference: On 2026-11-20 the user reported that Smart "does not change a word" and stated that Smart is the mode that turns thinking aloud into a ready, clean, structured, good-quality text; Markdown is not urgent. The user added that it had worked this way for a while and was fine.
    confirmed_at: 2026-11-20
  - type: repository
    reference: Sources/Sidekey/PostProcessor.swift
    confirmed_at: 2026-11-20
related: [2026-10-21-smart-editor-prompt.md, 2026-10-22-smart-editor-pass.md]
---

# Smart: ready text

## Context

The user's local History on 2026-11-20 showed what the conservative contract
does in practice. Of the last twenty Smart takes, seven came back unchanged and
six more changed only a space before punctuation. A recognized `yTap` or
`whytap` stayed as it was: the pass rule listed case and punctuation preferences
as reasons to return the marker, which overrode the name list further down the
same prompt. Weaker cleanup models (`gpt-oss-120b`, `qwen3.8-27b`) followed the
pass rule more readily than `gpt-6.1-terra` or `claude-sonnet-5.5`.

The prompt that shipped from 2026-09-04 to 2026-10-21 asked for a finished
message and allowed full rephrasing; this is the period the user remembers as
working well. The 2026-10-21 deep-editing revision rebuilt messages around their
main request and drifted in meaning within hours, which led to the conservative
contract and, a day later, the pass verdict.

## Decision

`PostProcessor.systemPrompt` asks for the text the author would have written
after sitting down to it:

- Remove stumbles, filler words, searching for wording, abandoned starts and
  remarks about the dictation itself. Say every thought once and carry all
  refinements from its repeats into that one wording. Keep only the final
  version of a self-correction, with what still holds from the rejected one.
- Repair recognition, grammar, punctuation and case; turn heavy spoken
  constructions into clear written sentences; bring remarks on one topic
  together.
- Paragraphs for long text, a plain list for three or more parallel items,
  numbers for dependent steps. No headings or other Markdown in the base
  prompt; destination formatting stays a separate appended instruction.
- Keep the author's voice: tone, form of address, slang and profanity. No
  added formality.
- The meaning safeguards of the conservative prompt stay word for word in
  intent: every fact, reason, condition, negation, number, deadline, addressee,
  scope and degree of certainty; nothing added; nested requests are edited, not
  carried out.
- A misspelled known name is always an error. Whytap's observed recognitions
  (`whytap`, `ytap`, `yTap`, `VayTAP` and Cyrillic phonetic spellings) are listed.
- The pass marker remains, narrowed to text with nothing to remove, repair or
  structure. A filler word, a repeat, a wrong name or a long unbroken text is a
  reason to edit. The one-request protocol, marker parsing, translation rule
  and Retry behavior are unchanged.

## Why

Smart is the mode where the user expects a finished text; Fast already gives
the transcript as spoken. A prompt whose first instruction is "edit only if
useful" makes the two modes look the same on a recognizer as clean as Scribe v3.
The drift of 2026-10-21 came from reordering around a "main request" and
condensing examples, not from removing fillers and repeats, so this prompt
restores the cleaning and structuring while keeping the fact safeguards and
examples that keep the author's first-person framing.

## What was tested

- `swift test --filter 'PostProcessor|SmartEditorPass|SmartFormatting'` on the
  new prompt: 33 tests, 0 failures. They cover the message envelope, pass
  parsing and formatting, not the quality of the model's editing.
- Live model acceptance, run by the user with the app's own OpenRouter key:
  twelve of the user's dictations from 2026-11-17..20, one generation each on
  `anthropic/claude-sonnet-5.5` and `openai/gpt-6.1-terra`, temperature 0.1,
  24 requests, no errors, $0.16. Every long take came back cleaned and split
  into paragraphs; every `yTap`/`ytap`/`whytap` became Whytap on both models;
  short clean questions passed or stayed close to verbatim.
- Defects seen in that run: one invented closing sentence, one question moved
  from the start to the end, one clean short phrase reordered for taste, and
  one relayed instruction ("tell it to split…") turned into direct commands.
  The prompt gained a rule for each.
- Builder review of the first submitted head found two contradictions in the
  prompt itself: an example turned "I would like" into "must not", against the
  modality rule, and the closing line banned code blocks that destination
  formatting allows. The example keeps the preference; the closing line now
  forbids only wrapping the whole answer.
- Final prompt, six synthetic samples on the same two models (12 requests, no
  errors, $0.07), run by the user with the app's key. No invented closing
  sentence; the leading question stayed first; the relayed instruction stayed
  an instruction to pass on, its examples stayed examples; "I would like"
  stayed a preference. With the GitHub destination appended, both models
  returned a numbered list with inline code for the commands, the parameter
  and the file name, and no fence around the answer.
- Remaining after that run: Sonnet still reordered one clean short sentence
  without changing its meaning (Terra passed it), and in the numbered list
  each model reworded the step lead-ins ("build the project", imperative
  verbs) around the literal commands. One generation per sample; the unit
  tests (33, 0 failures) cover the envelope, not editing quality.

## Rejected

- Literal rollback to the September prompt: it forbids lists, has no pass
  protocol and no safeguards against the meaning drift reported on 2026-10-21.
- Keeping the conservative prompt and only exempting names from the pass rule:
  fixes `Whytap`, leaves Smart indistinguishable from Fast.
- Removing the pass marker: a short clean message would be regenerated for no
  benefit, and the parsing/Retry contract would change.
- Sending Vocab terms to the editor as canonical spellings: the user's list is
  lower-case (`whytap`), so it would teach the wrong case. Left for a separate
  change together with the Vocab's own casing.

## Supersedes / superseded by

Supersedes the minimal-repair contract of
[2026-10-21-smart-editor-prompt.md](2026-10-21-smart-editor-prompt.md) and the
"ask for pass" criteria of
[2026-10-22-smart-editor-pass.md](2026-10-22-smart-editor-pass.md). The pass
protocol itself and Decision-stage removal from that document stand.

2026-11-20 · branch `claude/smart-mode-issues-ed2221`
