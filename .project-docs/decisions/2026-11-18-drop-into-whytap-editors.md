---
id: drop-into-whytap-editors-2026-11-18
type: decision
title: Drop dictated into a Whytap text editor is inserted directly, not pasted
summary: Dictating into the floating Translate input inserted the name of a file from the clipboard instead of the speech. A take that starts in one of Whytap's own native text editors now remembers that editor and inserts the final text into its selection, without the clipboard or Cmd+V, and delivers nowhere else if that editor is gone.
status: confirmed
tags: [drop, dictation, paste, clipboard, translation]
canonical_for: [drop-delivery-into-own-editors]
verified_at: 2026-11-18
sources:
  - type: user-confirmed
    reference: On 2026-11-17 the user reported that Drop dictated into the open floating Translate input puts the name of a file from the clipboard into the field instead of the speech.
    confirmed_at: 2026-11-17
  - type: user-confirmed
    reference: On 2026-11-18 the maintainer chose direct delivery for all Whytap text fields, including the embedded translator.
    confirmed_at: 2026-11-18
  - type: repository
    reference: Sources/Sidekey/DropLocalEditor.swift
    confirmed_at: 2026-11-18
  - type: repository
    reference: Sources/Sidekey/AutoPasteEngine.swift
    confirmed_at: 2026-11-18
  - type: repository
    reference: Tests/SidekeyTests/DropLocalEditorTests.swift
    confirmed_at: 2026-11-18
  - type: repository
    reference: Tests/SidekeyTests/AutoPasteEngineTests.swift
    confirmed_at: 2026-11-18
related: [2026-10-20-translation-tools.md, 2026-11-21-first-launch-onboarding.md]
---

# Drop into Whytap's own text editors

## Behavior

A nonactivating Translate panel can own the keyboard while Finder stays
frontmost. The old Drop path posted Cmd+V and then restored the pasteboard
on the same main thread that needed to handle the event. A delayed paste
could therefore read a previously copied file name. A queued-handler fixture
reproduced that ordering with a synthetic clipboard.

At the start of a take, retain a weak reference to the original native
editor, its window and (for a shared field editor) the field it edits.
Hold Space checks that editor before asking the frontmost application about
its focused element. Delivery calls AppKit's text-input method at the
selection. The SwiftUI binding, undo and input filtering follow normal
typing. Fast, Smart, batch recovery and raw partials share the delivery path.

A direct delivery requires the original window to own the keyboard and the
same editor to remain focused. A take started in a hover editor keeps the drawer
mounted while the Drop recording and processing wing is visible. Explicit
dismissal still works. If the original field is gone, History receives the
finished text or the recovered raw partial. A status notice tells the user
where to find a saved take. Smart uses plain formatting and
omits Accessibility context from the app behind the panel.

The prior experiment lengthened the opportunity for a queued paste to run.
Direct insertion removes that timing dependency and leaves the clipboard
available for the user's next paste.

## Verification

Offscreen checks use the real Translate field and its SwiftUI binding, a
synthetic file name and an instrumented clipboard. They cover caret and
selection replacement, paragraphs, closure and focus changes, Finder behind
the panel, Settings fields, the island search field and external delivery. Live physical dictation and marked
text in an input method remain installed-app acceptance.
