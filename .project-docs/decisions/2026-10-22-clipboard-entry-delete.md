---
id: clipboard-entry-delete-2026-10-22
type: decision
title: Delete one clipboard history entry from History
summary: Clipboard rows in hover History, Toolbox History and the ⌥V strip offer Delete… behind a Cancel-default confirmation; the store removes the image sidecar and the row in one queue hop with secure_delete and a truncating WAL checkpoint. Uploaded backups are not changed.
status: stale
tags: [clipboard, history, privacy, sqlite, backup, macos]
canonical_for: [clipboard-entry-deletion-2026-10]
verified_at: 2026-10-22
sources:
  - type: trace
    reference: On 2026-10-21 an App Store Connect private key copied through the clipboard was recorded in Whytap's clipboard history. The marker check of AbsoluteMode/whytap#202 stops future marked copies, but rows recorded earlier cannot be identified retroactively and there was no per-entry delete, so the row stayed until fifty newer copies evicted it. The key's value was not read for this change.
    confirmed_at: 2026-10-22
  - type: repository
    reference: Sources/Sidekey/History/SQLiteHistoryStore.swift
    confirmed_at: 2026-10-22
  - type: trace
    reference: The deletion flow (Sources/Sidekey/History/ClipboardEntryDeletion.swift) and its tests were removed on 2026-11-21; see 2026-11-21-clipboard-no-entry-delete.md.
    confirmed_at: 2026-11-21
related: [2026-11-21-clipboard-no-entry-delete.md, 2026-10-18-clipboard-retention.md, 2026-10-21-clipboard-privacy-markers.md, 2026-10-21-backup-essentials-only.md, 2026-10-18-delete-meeting-and-staged-audio.md, 2026-10-22-history-free-page-scrub.md]
---

# Delete one clipboard history entry

## Context

Clipboard history keeps the newest 50 copies across restarts
([clipboard retention](2026-10-18-clipboard-retention.md)). The only removal
path was the cap's FIFO eviction. When a secret was copied before the
[privacy-marker check](2026-10-21-clipboard-privacy-markers.md) existed, or
by an app that does not mark its copies, the user had no way to remove that
one row short of copying fifty other things or deleting the database file.

## Decision

Every surface that lists clipboard rows offers **Delete…** in the row's
context menu: hover History (Clipboard tab), Toolbox → History and the ⌥V
bottom strip. Agent and Drop rows are unchanged. `ClipboardEntryDeletion`
asks first with an `NSAlert` ordered as in meeting delete: Cancel is the
first button and takes Escape; the destructive Delete has no key equivalent,
so only a click deletes and Return selects nothing. The alert says
what kind of copy it is but never quotes it. A file-list entry says that the
files themselves are not touched.

`SQLiteHistoryStore.deleteClipboardEntry(id:assetsDirectory:)` runs in one hop
on the store's serial queue: look up the row, remove an image's sidecar, delete
the row with `PRAGMA secure_delete` on (since the
[free-page scrub](2026-10-22-history-free-page-scrub.md) the connection keeps
it on for every delete), then `sqlite3_wal_checkpoint_v2(..., TRUNCATE)`. It returns
`false` when the row is already gone. After a removal the hover/Toolbox lists
reload and `HistoryStripController.contentRevision` re-renders the strip; the
strip also drops a hover or expanded view of that copy.

## Rationale

- **One queue hop.** The watcher's inserts and cap eviction use the same
  queue, so nothing interleaves between the lookup, the sidecar removal and
  the row delete.
- **Sidecar first; a failure keeps the row.** The opposite order of the cap's
  best-effort cleanup is deliberate: for a privacy delete, a row that stays
  listed can be retried, while a vanished row with a surviving image would be
  an invisible copy. A missing sidecar counts as removed.
- **secure_delete and WAL truncation.** A plain `DELETE` leaves the copied
  bytes in free pages, and in WAL mode the original insert's frames stay in
  the `-wal` file until a checkpoint. A mutation check showed the copied text
  still readable in the database files without either step.
- **Already-evicted ids are success for the UI.** A list can be stale by the
  time the user confirms; the entry is gone either way, so the list reloads
  without an error.
- **Modal guard on History key monitors.** Hover History, the strip and the
  expanded card intercept Return/Escape with local monitors. While the
  confirmation is modal they now pass keys through, so Return cannot paste the
  row under the pointer and Escape reaches the alert. The row is also released
  from hover and preview before the alert opens.

## Verification

`Tests/SidekeyTests/History/ClipboardEntryDeletionTests.swift` uses in-memory
stores (one temporary-file store for the on-disk check) and temporary asset
folders: text, image with sidecar (another image survives), image with a
missing sidecar, a sidecar in a read-only folder (throws, row kept), file URLs
(the named file stays intact), an evicted and a twice-deleted id, and the
deleted text absent from `history.sqlite` plus `-wal` while the marker was
detectable before. Disabling `secure_delete` or the checkpoint each makes the
on-disk test fail. Flow tests cover Cancel, confirmed delete, a stale entry,
a reported failure, non-clipboard cards, the alert's buttons and text, and the
strip controller's hover/expanded/revision handling.

These checks do not exercise a real right-click in the island panel, the
NSAlert on screen or the installed app; acceptance in the working app is
separate.

## Alternatives rejected

- Reusing `enforceClipboardCap`'s order (sidecar outside the queue, failures
  ignored): it can leave an unlisted image of a deleted entry.
- A bulk "Clear clipboard history" or wipes on launch/quit: retention is a
  deliberate decision; one wrong row should not cost the rest.
- `secure_delete` for the whole connection or a `VACUUM`: wider behavior and
  I/O change than this fix needs; old free pages from earlier evictions are not
  scrubbed by this change. Both were adopted afterwards by the
  [free-page scrub](2026-10-22-history-free-page-scrub.md).
- Clearing the system pasteboard when its content matches: a separate action
  the user did not ask for.
- SwiftUI `confirmationDialog` (Notify's hover panel): meeting delete's
  `NSAlert` order already gives the required Cancel-first behavior and is
  testable without showing a window.
- Making Cancel the Return default as `WhytapLinkConfirmation` does: it needs
  an extra Escape monitor; meeting delete's behavior is the requested model.

## Consequences

Encrypted backups already uploaded are not changed. Archives made before
2026-10-21 contain the History database, and restoring one brings its entries
back, including deleted ones. Time Machine, APFS snapshots and other disk
copies are outside the app. Earlier versions of the row that SQLite may have
left in pages freed by past evictions are not scrubbed by this change; the
[free-page scrub](2026-10-22-history-free-page-scrub.md) handles them. The truncating checkpoint is
best effort: another active SQLite reader can postpone WAL cleanup, even after
the row is deleted. This is per-entry removal, not a forensic disk wipe.

## Superseded by

On 2026-11-21 the user removed per-entry Delete from clipboard History; see
[no clipboard entry delete](2026-11-21-clipboard-no-entry-delete.md). The
History connection's `secure_delete` and the free-page scrub stay in force.

2026-10-22 · PR: https://github.com/AbsoluteMode/whytap/pull/206
