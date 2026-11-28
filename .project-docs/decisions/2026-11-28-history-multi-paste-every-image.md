---
id: history-multi-paste-every-image-2026-11-28
type: decision
title: History multi-paste pastes every image separately and waits for each read
summary: Marked text, image, image pasted only the text and one image because both images shared one paste; every image is now its own Cmd+V, each paste waits for the target's read and the user's clipboard comes back after the last.
status: confirmed
tags: [history, clipboard, paste, island]
canonical_for: [history-multi-paste-every-image]
verified_at: 2026-11-28
sources:
  - type: user-confirmed
    reference: On 2026-11-28 the maintainer reported that three marked Clipboard rows (text, image, image) pasted only two, in Whycode and other apps alike; installed build 1787.
    confirmed_at: 2026-11-28
  - type: repository
    reference: Sources/Sidekey/History/HistoryMultiPaste.swift
    confirmed_at: 2026-11-28
  - type: repository
    reference: Sources/Sidekey/AppDelegate.swift
    confirmed_at: 2026-11-28
  - type: repository
    reference: Tests/SidekeyTests/History/HistoryMultiPasteTests.swift
    confirmed_at: 2026-11-28
related: [2026-11-22-history-multi-paste.md, 2026-11-28-clipboard-suppression-per-owner.md]
---

# Context

The maintainer marked three Clipboard rows in the island's History (1 text,
2 and 3 images) and pressed Enter. The target received the text and one
image. It happened in Whycode (Electron) and in other apps.

`HistoryPastePlan` merged neighbouring attachments into one paste, so the two
images went out as one pasteboard with two image items and one Cmd+V. Native
AppKit text views insert both, but Chromium and Electron build a paste from a
single image (the first item that has image data), and so do most apps that
accept pasted images. Mixing file URLs and an image in one paste has the same
problem in reverse: Chromium takes the files and drops the image. The selection
order, the loop and the focus handling were correct.

# Decision

- Every image is a paste of its own. Neighbouring files still share one paste
  (Finder-style file URLs are read as a list), neighbouring texts still join
  with line breaks.
- Text and image pastes are written as promised data
  (`PromisedPasteboardPayload` from the Drop restore-on-read change, one item
  with the `org.nspasteboard.TransientType` marker; an image offers PNG and
  TIFF). Each read by a reader counts. `HistoryPasteReadWaiter` lets the
  series replace the pasteboard only 150 ms after the last read of the current
  paste, or after a 2 s fallback when nothing reads it. File pastes give no
  read signal and keep the former fixed 400 ms gap.
- After the last paste was read, the user's clipboard from before the series
  comes back (`Pasteboard.restore`), like Drop. If other content replaced the
  series' write (the user copied something), the series stops and that content
  stays. A refused write or an unposted Cmd+V gives the clipboard back at once.
  Before taking its snapshot the series waits for a pending Drop restore.
- A single row pasted with Enter is unchanged: it stays on the clipboard.

# Why

Splitting images is the only change that makes every ordinary app receive
every image; a combined payload depends on each app's reader. More pastes make
the fixed 400 ms gap a second risk: Chromium reads only when the page handles
the paste, possibly later (the Drop log of 2026-11-27 shows it), and a late
read takes whatever the series wrote next, which shifts or drops items. Waiting
for the read reuses the Drop mechanism instead of a second one. Restoring the
user's clipboard keeps a multi-paste from silently replacing what they copied
and is what makes waiting for the last read necessary.

# What was tested

`HistoryMultiPasteTests` with a simulated pasteboard and a target that reads a
set time after Cmd+V and takes whatever is on the pasteboard then: the
maintainer's text, image, image in badge order; images then text; ten
alternating items and ten images; a target reading 900 ms late; a target that
never reads (fallback, then restore); a user copy during the series (kept, the
rest stops); a refused write; an image with nothing pastable (skipped); a read
burst. The restore happens only after the last item was read. On a named
pasteboard: two image items read the way Chromium reads give only the first
image (the reported loss); one image paste is one item with PNG and TIFF and
counts the read; an end-to-end run with real sleeps and a reader 450 ms after
Cmd+V receives text, image, image in order and then finds the user's clipboard.
Mutation checks: with images merged again, or with the fixed 400 ms gap instead
of the read wait, these tests fail (the slow reader receives image, image and
the user's clipboard). `AutoPasteEngineTests` series cases still pass.

Not verified live: pastes into Whycode, Chrome, Notes and TextEdit in the
installed app, and how each app reads a promised image.

# Limits

The read signal does not identify the reader. A clipboard tool that ignores the
transient marker and reads first can end a wait early. A target that reads a
paste again after the restore sees the user's clipboard. Quitting Whytap in the
middle of a series leaves the current item on the clipboard.

# Rejected

- One paste with all images as items: the reported failure.
- A longer fixed gap: slower for every paste and still wrong for a slower
  reader.
- Image pastes as file URLs of the stored PNGs: text fields that accept images
  but not files would paste a path or nothing.
- Keeping the last item on the clipboard (the former behaviour): requested
  otherwise for this fix; a multi-paste is not a copy.

2026-11-28, branch fix/clipboard-multi-paste-last-item.
