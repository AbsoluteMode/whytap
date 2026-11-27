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
- The restore is dropped when the pasteboard's change count moved (the user
  or another app copied something). The suppression flag covers only the
  write and the restore themselves; a skip-through threshold covers the
  dictation write, so such a copy reaches clipboard history.
- A take that starts while a restore is pending inherits its snapshot,
  unless the clipboard was replaced; if its write then fails, the snapshot
  is restored at once. `applicationWillTerminate` restores a pending one.
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
back; quit restores at once. On a named pasteboard: promise read counting
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
restore sees the old clipboard. Another Whytap feature that writes the
clipboard during the wait (for example the selection-capture Cmd+C) cancels
the restore. If the app is killed during the wait, the dictation stays on the
clipboard.

2026-11-27, PR: see fix/paste-restore-on-read.
