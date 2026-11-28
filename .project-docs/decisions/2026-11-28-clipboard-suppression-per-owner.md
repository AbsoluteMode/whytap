---
id: clipboard-suppression-per-owner-2026-11-28
type: decision
title: Clipboard suppression is held per owner and Whytap's own writes are suppressed by their exact generation
summary: ClipboardSuppression's flag became a counted hold, so one owner releasing it cannot lift another owner's suppression. History multi-paste and History Copy no longer hold the flag at all; each skips exactly the generations it wrote, so a copy the user makes meanwhile is recorded and never overwritten. A series paste sends no V-down once its own write was replaced.
status: confirmed
tags: [history, clipboard, paste, drop]
canonical_for: [clipboard-suppression-ownership]
verified_at: 2026-11-28
sources:
  - type: user-confirmed
    reference: On 2026-11-28 the release-batch inquisition (orchestrator card 42) reported that a finishing Drop restore cleared History multi-paste's suppression, that the series' final skip-through swallowed a user copy made during it, and that the series checked the pasteboard generation only after Cmd+V; the orchestrator asked for owned suppression that keeps the accepted multi-paste behaviour.
    confirmed_at: 2026-11-28
  - type: repository
    reference: Sources/Sidekey/AutoPasteEngine.swift
    confirmed_at: 2026-11-28
  - type: repository
    reference: Sources/Sidekey/History/HistoryMultiPaste.swift
    confirmed_at: 2026-11-28
  - type: repository
    reference: Tests/SidekeyTests/History/HistoryMultiPasteTests.swift
    confirmed_at: 2026-11-28
related: [2026-11-28-history-multi-paste-every-image.md, 2026-11-22-history-multi-paste.md, 2026-10-21-clipboard-privacy-markers.md]
---

# Clipboard suppression per owner

## Context

`ClipboardSuppression.isSuppressed` was a bare flag shared by Drop, the
selection fallback's Cmd+C dance, History Copy and History multi-paste.
History multi-paste raised it, then waited for a pending Drop restore; the
restore lowered the flag, so the whole series ran unsuppressed and its
multi-attachment writes and the final restore could be recorded as user
copies. After the series an unconditional skip-through to the current
generation swallowed a real Cmd+C the user made during it. The series also
checked the pasteboard generation only after Cmd+V, and a refused write
restored the old clipboard without checking whose generation was current.

## Decision

- The flag is a counted hold: `setSuppressed(true)` raises one hold,
  `setSuppressed(false)` releases one, and suppression lasts while any hold
  remains. Every remaining caller pairs them synchronously.
- History multi-paste and History Copy do not hold the flag. Each skips the
  exact generation it wrote, right after writing and before anything else can
  run on the main actor (`suppressThrough`), including a refused write's own
  clear and the restore.
- The series restores the user's clipboard only while the pasteboard still
  holds the series' own last generation. A series paste sends no V-down once
  that generation was replaced.
- The accepted behaviour stays: three marked rows paste all three in order and
  the previous clipboard comes back afterwards.

## Why

A shared boolean has no owner, so the first owner to finish lifts everyone's
suppression. Exact generations are the only evidence that a change is
Whytap's own; anything newer belongs to the user and must be recorded and
kept.

## What we tested

- History multi-paste: three rows paste three times and restore, suppressing
  only the three writes and the restore; a user copy during the series is not
  suppressed and not overwritten; a refused write during which another copy
  landed does not restore over it.
- The engine sends no V-down when the pasteboard changed while modifiers were
  released and focus settled.
- The clipboard watcher keeps skipping while another owner's hold remains
  after a Drop-style hold was released.

## Rejected

- Keeping the flag and re-raising it after waiting for Drop: still clobbered by
  any other owner finishing during the series.
- A final skip-through to the current generation: covers the user's own copy.

2026-11-28 · orchestrator card 42, release-batch inquisition
