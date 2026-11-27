---
id: drop-paste-restore-on-read-2026-11-27
type: decision
title: Drop restores the clipboard after the target reads the dictation
summary: Drop publishes the dictation as promised pasteboard data and gives the user's clipboard back 150 ms after the last read that follows Cmd+V (2 s fallback), instead of a fixed 120 ms after Cmd+V that busy Chromium/Electron targets lost, pasting the previous clipboard.
status: confirmed
tags: [drop, paste, clipboard, pasteboard, electron, chromium]
canonical_for: [drop-paste-clipboard-restore-timing]
verified_at: 2026-11-27
sources:
  - type: user-confirmed
    reference: On 2026-11-27 the owner reported, through the orchestrator as task 94, that Drop into Electron/Chromium apps sometimes pasted the clipboard's previous content (an old screenshot) instead of the dictation, and asked that the dictation always be what the target reads while the previous clipboard is still restored.
    confirmed_at: 2026-11-27
  - type: repository
    reference: Sources/Sidekey/AutoPasteEngine.swift
    confirmed_at: 2026-11-27
  - type: repository
    reference: Sources/Sidekey/Pasteboard/PromisedPasteboardPayload.swift
    confirmed_at: 2026-11-27
related: [2026-10-21-clipboard-privacy-markers.md]
---

# Drop restores the clipboard after the target reads the dictation

## Context

`AutoPasteEngine.paste` wrote the dictation to the general pasteboard, posted
Cmd+V and restored the user's previous clipboard a fixed 120 ms later.
Chromium reads the pasteboard only when the page handles the paste event; a
busy renderer does that later. Real log of 2026-11-27: Cmd+V at
12:58:13.261, restore at 12:58:13.382, target Whycode (Electron), previous
clipboard png/tiff only. The target pasted the old screenshot.

## Decision

- The dictation (plain, or plain/RTF/HTML for rich paste) is written as
  promised data through `NSPasteboardItemDataProvider`. Every provided type
  counts as a read (`PasteboardReadMonitor`).
- `paste` returns after Cmd+V. A pending restore polls every 10 ms and
  restores 150 ms after the last read seen after Cmd+V, or after 2 s when
  none came; reads before Cmd+V do not count.
- Drop owns only the clipboard generation its own write produced (a claim
  from the write to the restore). The skip-through threshold covers exactly
  that write and the suppression flag drops right after it, so a later copy
  reaches clipboard history. Newer content found after the write or at the
  Cmd+V boundary stops the paste without a key event (`paste` returns
  false, the take offers Retry) and is never restored over; the modifier
  timeout, quit and every restore check ownership first.
- A remembered, still running target that loses focus during the 80 ms
  non-blocking settle stops the paste and the clipboard comes back: the
  global Cmd+V would reach the other app. The take's target is fixed when
  its paste starts, so a newer take capturing another app cannot redirect
  it.
- The global Cmd+V is checked once more between Command-down and V-down
  (the event that pastes): the clipboard must still hold this take's
  dictation and the app that was frontmost at Command-down must still be
  frontmost. Otherwise Command is released, V is never sent, and the
  clipboard comes back only if it is still Drop's. Without a remembered
  target only ownership decides (the documented fallback).
- A failed write restores only when the write itself moved the change
  count (or the previous take's dictation is still there) and nothing newer
  arrived after it.
- Drop pastes run one at a time. A take that starts while the previous one
  waits for its read waits too (up to the 2 s fallback), so the previous
  target reads its own dictation, then inherits the snapshot; if its write
  fails, the snapshot is restored at once.
- `applicationWillTerminate` gives the clipboard back whether the paste is
  before Cmd+V (it then stops) or after it. Every Drop paste that began
  before the flush stops before writing or posting, including takes that
  wait for the previous target's read or for their paste turn. A
  handed-over claim stays registered until the next take's write replaces
  it, so a flush in between still restores it.
- Another Whytap feature that snapshots the clipboard, writes and restores
  (selection capture, a failed Shot text copy) puts the dictation back with
  a new change count. Drop recognises its dictation by content (transient
  marker and the same text), adopts that generation and still restores the
  user's clipboard. Real external copies and successful Shot/History copies
  carry no marker and are kept. `Pasteboard.snapshot` reads are Whytap's own
  and do not count as the target's read.
- The dictation item carries `org.nspasteboard.TransientType`, so
  `ClipboardWatcher` and clipboard managers that honour the marker skip it
  without reading it (a read would look like the target's).
- The 80 ms settle before Cmd+V no longer blocks the main thread, so reads
  requested before Cmd+V are served (and not counted) before it.

## Why

Only the reader knows when it reads; a longer fixed delay would still lose to
a slower renderer and keep the dictation on the clipboard longer for every
app. A prototype on a named pasteboard confirmed AppKit calls the provider on
the main thread once per type, serves repeated reads from its cache, and
holds a reader that asks while our main thread is blocked until it is free
(the read is delayed, not lost). The 150 ms quiet time covers readers that
take several types in a burst. The fallback restores the clipboard when the
target ignores Cmd+V, or when a reader before Cmd+V caused the target to be
served from the cache without a signal.

## What was tested

Unit scenarios with a simulated pasteboard and clock: a reader at 400 ms
after Cmd+V sees the dictation; a fast reader; two reads; no reader
(restore at the 2 s fallback); a read before Cmd+V is ignored; a user copy
during the wait is kept and not suppressed; back-to-back takes keep the
original; a second take after a user copy keeps that copy; a second take
whose write fails restores at once; an image-only previous clipboard comes
back; quit restores at once. After the build-queue review of ticket 687:
a copy right after the write, a copy during the settle and a copy during the
modifier timeout are neither pasted nor overwritten; quit before Cmd+V
restores and posts nothing, and leaves a newer owner alone in both phases;
a second Drop waits until the first target read "take one", then each
target reads its own take; concurrent pastes run in turn; focus lost during
the settle posts nothing; selection capture (with and without a selection)
and a failed Shot text copy no longer strand the dictation, and a
successful Shot copy is kept. After the review of ticket 692: a copy
between Command-down and V-down (with and without a target) is not pasted
and not overwritten; a failed write does not restore over a later copy; quit
while a second take waits for the first read, or while two later takes
wait, stops them; a newer take capturing another app during the settle, and
a focus change between Command-down and V-down, post no V. On a named pasteboard: promise read counting
and cache, `ClipboardWatcher` skipping the item unread, and an end-to-end
run where a separate `osascript` process reads 300 ms after Cmd+V from an
image-only pasteboard. With the timing forced back to 120 ms that process
read the old pasteboard (no text); with this change it read the dictation
and the image came back.

## Rejected

- A longer fixed delay (for example 500 ms): still a race, and slower for
  every app.
- Leaving the dictation on the clipboard: breaks the rule that Drop does not
  change the user's clipboard.
- Detecting the paste through the target's text (Accessibility): not
  available in many Electron/web editors.

## Limits

A reader that is not the target but reads first after Cmd+V (one that
ignores the transient marker) can still end the wait early; macOS does not
identify readers. A target that reads the same payload again after the
restore sees the old clipboard. A Whytap round trip that snapshots the
still-promised dictation resolves it in-process; the target is then served
from the cache and only the fallback timing applies. A second take can wait
up to the 2 s fallback when the first target never reads. If the app is
killed during the wait, the dictation stays on the clipboard.

2026-11-27, PR: see fix/paste-restore-on-read.
