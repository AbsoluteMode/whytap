---
id: smart-no-window-context-2026-11-22
type: decision
title: Smart sends the selected model no text of the target window
summary: Smart no longer reads the text of the target window through Accessibility or adds it to its request; the app name stays, and only local formatting metadata (focused role, document URL) is still read.
status: confirmed
tags: [smart, privacy, accessibility, context, dictation, prompt]
canonical_for: [smart-request-content]
verified_at: 2026-11-22
sources:
  - type: user-confirmed
    reference: On 2026-11-22 the maintainer decided, after an external new-user review flagged it, to remove the active-window Accessibility context from Smart entirely, with no setting to bring it back.
    confirmed_at: 2026-11-22
  - type: repository
    reference: Sources/Sidekey/PostProcessor.swift
    confirmed_at: 2026-11-22
  - type: repository
    reference: Sources/Sidekey/SmartFormattingMetadataReader.swift
    confirmed_at: 2026-11-22
related: [2026-10-21-smart-destination-formatting.md, 2026-09-07-smart-latency.md, 2026-10-19-strict-drop-modes.md, 2026-11-24-smart-markdown-off.md]
---

# Smart: no window context

## Context

An external review of Whytap from a new user's point of view found that Smart
dictation read up to 2,000 characters of the target app's focused window
through Accessibility (values, titles and descriptions of every element, up
to 600 nodes) and appended them to the cleanup request as an
`<active_app_context>` envelope, together with the app's name. Users grant
Accessibility for the hotkeys and for pasting; they do not expect the text of
the window they are typing into (a chat thread, a document, a mail) to go to
an LLM provider with every Smart take.

## Decision

- Smart sends the selected cleanup model its own instructions (the system
  prompt plus the fixed rules of the chosen destination format), the target
  app's name, the input/output language hints, the transcription mode and
  the transcript. No text of the target window.
- There is no setting to turn the window context back on.
- `AXContextReader` is replaced by `SmartFormattingMetadataReader`, which
  reads only the focused element's role and the containing document's URL
  within the same 1.5 s deadline. Those values select the local formatting
  profile and never enter the request.
- The system prompt no longer mentions an application context block; the
  transcript remains the only data block.
- Vocab is not affected (Smart's cleanup request did not carry it before
  this change either).
- Fast is unchanged: it never ran the cleanup closure, so it never read
  Accessibility for Smart.

## Why

The context was a quality aid for spelling names and terms, not a contract
of the editor. The canonical term list in the prompt covers the common
product and technology names. Silently sending private
on-screen text to a third party under a permission granted for something
else is not acceptable for a privacy-first app. The app name is a single,
expected word about where the text goes and was sent before the window
context existed; the maintainer's scope was the window text only.

## What was tested

- The Smart request built by the production `PostProcessor` path for plain,
  Slack, Telegram, GitHub and CommonMark profiles equals exactly the system
  prompt (plus format rules) and the app name and hints followed by the
  transcript.
- The reader's source has no value, title, description, selected-text or
  children reads; `AXContextReader.swift` no longer exists.
- The formatting metadata keeps its single deadline, discards late results,
  reads nothing without a target and returns at once on cancellation.
- The system prompt keeps its data boundary, pass marker, structure and term
  sections.
- Fast never calls cleanup (existing `DropOutputPolicyTests`).

Answer quality without the context was not measured on real takes.

## Rejected

- A switch, default off: the maintainer asked for removal without one.
- Removing the app name too: outside the maintainer's scope (window text
  only); it is not content from the screen.
- Deleting the Accessibility metadata read: destination formatting needs the
  focused role and document URL, which stay on the Mac.

## Supersedes / superseded by

Supersedes the screen-context envelope described in
[2026-10-21-smart-destination-formatting.md](2026-10-21-smart-destination-formatting.md)
and the context collection part of
[2026-09-07-smart-latency.md](2026-09-07-smart-latency.md); its deadline now
bounds only the formatting metadata read.

Since 2026-11-24 Markdown is off in Smart: no destination format rules are
sent and the focused role and document URL are not read at all while
`SmartFormattingProfile.isMarkdownEnabled` is off:
[2026-11-24-smart-markdown-off.md](2026-11-24-smart-markdown-off.md).
The request still carries no window text and no address.

2026-11-22 · branch `claude/smart-no-ax-context-0bf183`
