---
id: transcript-copy-2026-09-08
type: decision
title: Copy the full meeting transcript from the Transcribe tab
summary: A native clipboard action preserves speakers and timestamps as plain text.
status: confirmed
tags: [meetings, transcript, clipboard, ui]
canonical_for: [meeting-transcript-copy]
verified_at: 2026-09-08
sources:
  - type: repository
    reference: Sources/Sidekey/Meetings/MeetingsDetailView.swift
    confirmed_at: 2026-09-08
  - type: repository
    reference: Sources/Sidekey/Meetings/TranscriptMarkdownFormatter.swift
    confirmed_at: 2026-09-08
related: [../project.md]
---

# Transcript copy

The Transcribe reader has a Copy transcript button in its toolbar. It copies
all loaded transcript segments to the macOS clipboard as plain text, keeping
speaker labels, timestamp ranges and paragraph breaks, without Markdown bold
markers. Successful writes show Copied. The action is unavailable without a
transcript; loading another or unavailable meeting clears the previous copy
payload and feedback. Both Settings and the standalone meetings window use
this shared detail view. Copying never changes the stored transcript or note.

Existing detail-model, transcript-formatting and content-controller tests are
run alongside a build check for this small native UI addition.
