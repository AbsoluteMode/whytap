---
id: drop-edit-observation-2026-11-22
type: decision
title: Learning from edits watches the field until it is sent instead of reading it once after 5 s
summary: After a Drop paste Whytap watches the same field (AX value notifications plus a 0.5 s bounded read) until it empties, focus leaves it, it goes away, another take starts or 2 minutes pass, and learns from the last text that still holds the take. Return only triggers an extra read. Electron and web apps get AXManualAccessibility or AXEnhancedUserInterface turned on for the target app only, from take start until the field is no longer watched.
status: confirmed
tags: [drop, learning, accessibility, privacy, electron]
canonical_for: [drop-edit-observation, drop-learning-electron-fields]
verified_at: 2026-11-22
sources:
  - type: user-confirmed
    reference: ORCH-TASK 72 REV 18 forwarded by the orchestrator. Live check on build 1718 failed. The user twice fixed a misheard word in the Claude desktop chat field and sent it with Return; no suggestion came. The user then approved both detection paths, value notifications and Return in the same field ("let us do 1 and 2").
    confirmed_at: 2026-11-22
  - type: trace
    reference: Build 1718 defaults (read only) had sidekey.dropLearning.enabled = 1 and no sidekey.dropLearning.ledger.v1 key. The ledger is written on every successful read, even one with no candidates, so no read of a pasted field ever succeeded.
    confirmed_at: 2026-11-22
  - type: repository
    reference: Sources/Sidekey/DropLearning/DropLearningCoordinator.swift
    confirmed_at: 2026-11-22
  - type: repository
    reference: Sources/Sidekey/DropLearning/DropEditFieldReader.swift
    confirmed_at: 2026-11-22
  - type: repository
    reference: Tests/SidekeyTests/DropLearning/DropLearningScenarioTests.swift
    confirmed_at: 2026-11-22
related: [2026-11-22-drop-edit-learning.md, 2026-11-22-drop-learning-drops.md, 2026-11-22-drop-learning-default-on.md]
---

## Context

The first version read the pasted field once, 5 seconds after the paste.
The live check on build 1718 failed in the most common case: dictate into
a chat (Claude desktop), fix a word by hand, press Return. Two things broke
it.

1. Chat apps empty the field when the message is sent. A read after Return
   sees an empty field, and the word diff needs text, so nothing counts. A
   fix that took longer than 5 s was read before it happened.
2. Electron apps (Claude desktop, Slack and others) and Chromium web views
   build their accessibility tree only on request. Without it the focused
   element is a web area, not a text field, so the gate refuses the
   capture at the paste and nothing is watched. Whytap never asked for the
   tree. The empty ledger in 1718 shows that no read of a pasted field ever
   succeeded.

## Decision

- **Watching, not one read.** After the paste, the coordinator watches the
  same field. It subscribes to AX notifications on that element (value
  changed, element destroyed, the app's focused element changed) and also
  makes one bounded read every 0.5 s, for apps that send no notifications.
  Every read goes through the same gate as before: same frontmost app,
  same focused element, metadata gate, length-bounded `AXStringForRange`,
  focus confirmed again after the transfer.
- **What counts.** The last text that still aligns with the take
  (`DropEditDiff`) is kept in memory. Watching ends when:
  - the field empties (sent): the kept text counts;
  - focus leaves the field, the field goes away, another take starts, or
    2 minutes pass: the kept text counts;
  - the field holds text that no longer aligns (another message, a
    rewrite): nothing counts;
  - the paste never shows up within 5 s, or the field cannot be read:
    nothing counts.
- **Return.** While a field is watched, a listen-only global key monitor
  looks only at the key code of Return and keypad Enter. On either key it
  reads the field at once and again 0.15 s later. Return is never held,
  swallowed or changed, and the monitor keeps nothing. The monitor exists
  only during an observation. Most fixes are already in the kept text from
  the value notification of the last keystroke. Return mainly shortens the
  time until the emptied field is noticed.
- **Electron and web fields.** At take start (the target was remembered
  at hotkey-down) the target app is asked to expose its fields, but only
  under three conditions: its focused element is not already a readable
  text field, the gate would allow the app (not a terminal or password
  manager, no secure input, no AX error), and it is frontmost. The request
  sets `AXManualAccessibility` (Electron) or, when the app does not answer
  that, `AXEnhancedUserInterface` (Chromium browsers), and only if the
  attribute is off now. It is turned off again when the field is no longer
  watched, when the next take goes to another app, or 11 minutes after a
  take start that produced no paste. It is turned off only while it still
  holds the value Whytap set. An attribute already on (VoiceOver, the
  user, another tool) is never touched.
- **Calibration** journals one `observed` entry per take with the reason
  watching ended, instead of the 5 s read and the settled read.

## Why

- The text right before the field empties is the only moment that holds
  both the paste and the user's fixes in chat apps. Reading at a fixed
  delay cannot hit it.
- Notifications plus a 0.5 s read keep the kept text current without
  recording keystrokes. Only the field's own text is read, through the
  same bounded, focus-checked path.
- The previous gate already refused unknown roles, so Electron fields were
  silently out of scope. Asking only the target app, only while needed, is
  the narrowest way to read them. The same request is what screen readers
  and automation tools make.

## What we tested

- The 1718 failure explained from the code and the defaults. The ledger key
  was absent, so no read reached the ledger, and an empty field gives no
  diff.
- Scenario tests drive the coordinator with a fake field:
  - fix and Return in a chat counts twice into a Vocab suggestion;
  - Return that only adds a line keeps watching;
  - leaving the field and the field going away count;
  - another message, a field that never shows the paste, and switching
    learning or calibration off count nothing;
  - watching stops after 2 minutes;
  - a new take counts the field before its paste;
  - exposure is released after the observation, after a take that is never
    pasted, and when the next take goes to another app;
  - nothing is exposed while learning is off.
- Field access tests check the exposure rules with fake AX attributes:
  - an Electron app gets `AXManualAccessibility` and it is undone once;
  - a Chromium browser gets `AXEnhancedUserInterface`;
  - a native text field is not touched;
  - an attribute that is already on is left alone;
  - a value changed by another tool is not fought;
  - denied apps, secure input and background apps are never exposed.
- Not verified here: real Electron, Slack, Telegram and browser fields need
  the built app, because a feature session does not launch it. These are
  the acceptance checks for the builder and the maintainer.

## Rejected

- Keep one read and move it later: a sent chat field is empty whatever the
  delay.
- Read inside the existing Space hotkey event tap before Return reaches
  the app. That tap exists only for the Space hotkey, and a synchronous
  read there would delay every Return.
- Record typed keys and replay the edit: that is a keylogger. The field's
  own text is enough.
- Turn on accessibility for every Electron app at launch: it changes
  other apps' behaviour all the time for a feature that needs one field
  for a few minutes.

2026-11-22, branch claude/drop-learning-observe.
