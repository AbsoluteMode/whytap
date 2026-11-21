---
id: hotkey-defaults-table-2026-11-21
type: decision
title: The default shortcuts table lives in docs/hotkey.md
summary: The README Tools accordion dropped the `| Action | Default |` hotkey table that the whytap.ai Ask assistant reads to confirm keys in its answers; the table now lives in docs/hotkey.md, which Ask reads first.
status: confirmed
tags: [hotkeys, docs, ask, landing]
canonical_for: [hotkey-defaults-table]
verified_at: 2026-11-21
sources:
  - type: user-confirmed
    reference: On 2026-11-21 Maxim chose to restore the table outside the README and teach Ask to read it there, before deploying the landing, over deploying with the failing check skipped.
    confirmed_at: 2026-11-21
  - type: repository
    reference: Sources/Sidekey/Hotkeys/HotkeyPreferences.swift
    confirmed_at: 2026-11-21
  - type: repository
    reference: docs/hotkey.md
    confirmed_at: 2026-11-21
related: []
---

## Context

The whytap.ai Ask assistant (private repository `AbsoluteMode/whytap-landing`,
`ask/facts.py`) builds its facts from this repository's `origin/main`. It
confirms every key combination an answer shows against the README
`| Action | Default |` table. The README Tools accordion (#328) removed that
table, so from then on the live Ask could not confirm any shortcut, and the
landing's pre-deploy tests failed against current main.

## Decision

The table of default shortcuts is in `docs/hotkey.md` under "Default
shortcuts", with the same columns and `<kbd>` markup. Ask reads it there and
falls back to the README. The README keeps its current design.

## Why

The README is the user-facing page and is being redesigned in its own
sessions; `docs/hotkey.md` is already the place a new hotkey must be
documented, so the defaults stay next to the rules for adding one.

## What was checked

The rows match `HotkeyConfiguration.defaults` (hold Space, Right ⌘ tap/hold,
Right ⌥ tap/hold for Google, ⌥Q to close the answer) and the documented
meeting-record default ⌥M; bare Esc also closes a visible answer
(`EscapeCloseEventMonitor`). Ask's parser reads all six rows.

## Rejected

- Restoring the table in the README: conflicts with the README redesign.
- Deploying the landing with the failing check skipped: the live Ask would
  keep rejecting every shortcut.
