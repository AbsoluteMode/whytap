---
id: history-multi-copy-2026-11-22
type: decision
title: A click with marked History rows copies all of them
summary: After marking three History rows with ⌘-click, a plain click copied nothing useful; it now copies every marked row in mark order as one pasteboard and clears the marks, and marking works without a paste target and in Toolbox.
status: confirmed
tags: [history, clipboard, copy, island, toolbox]
canonical_for: [history-multi-copy]
verified_at: 2026-11-22
sources:
  - type: user-confirmed
    reference: On 2026-11-22 the maintainer tested build 1698, marked three History rows with ⌘-click, clicked and asked why nothing was copied; he approved copying all marked rows on a click.
    confirmed_at: 2026-11-22
  - type: repository
    reference: Sources/Sidekey/History/HistoryMultiPaste.swift
    confirmed_at: 2026-11-22
  - type: repository
    reference: Sources/Sidekey/History/HistoryHoverView.swift
    confirmed_at: 2026-11-22
  - type: repository
    reference: Tests/SidekeyTests/History/HistoryMultiPasteTests.swift
    confirmed_at: 2026-11-22
related: [2026-11-22-history-multi-paste.md]
---

# Context

`2026-11-22-history-multi-paste.md` added ⌘-click marks that Enter pastes.
A plain click still copied only the clicked row, and marking existed only
where Enter could paste. The maintainer marked three rows, clicked, and
expected the three to be copied.

# Decision

While rows are marked, a plain click on any row copies every marked row in
mark order and clears the marks; the copied toast and panel behave as for an
ordinary copy. Without marks a click copies its row as before.

The copy is one pasteboard built from `HistoryPastePlan`'s groups
(`HistoryPasteboardWriter.writeAll`): texts one string a line each, files and
images one item each, and mixed rows one item per group in mark order. One
row is written exactly as before.

Marking now works everywhere: in the island with or without a paste target
and in the Toolbox History pane. Enter pastes only with a target; without one
it leaves the marks for a click. The footer with marks says "Click to copy N",
then "Enter to paste N to <app>" where there is a target, then "Esc to clear"
(island) or "⌘-click to unmark" (Toolbox, which has no key monitor). Like
History's single copy, the multi-row copy is kept out of clipboard history.

# Why

Marks are a selection; a click on a selection acting on one row read as a bug.
A copy has no target, so the same marks are useful without one and in
Toolbox, and one behaviour everywhere is easier to learn.

Mixed text and files cannot be one paste in every app. One pasteboard with
items in mark order is the closest honest form: file-aware apps attach the
files, a plain text read gets every text item joined by line breaks (AppKit
does this for several string items), some apps read only the first item.
Separate pastes, as Enter does, need a target and are not a copy.

# What was tested

`HistoryMultiPasteTests`: click with marks copies all marks in mark order,
also from an unmarked row; no marks copies the row; three files are one
pasteboard with three URLs in mark order; texts are one string a line each;
mixed rows are three items in order and a plain text read joins the texts; one
row is unchanged; the click closure copies and then clears marks, with ⌘
toggling; Enter without a target leaves marks and Escape clears them; footer
in every state. Not verified live: how each destination app reads a mixed
pasteboard.

# Rejected

- Click with marks copies only the clicked row: the reported surprise.
- Esc in Toolbox through a new key monitor in Settings: an app-wide monitor
  there could swallow Escape meant for other Settings controls.
- Mixed copy as text with file paths: loses the files where they could be
  attached.

2026-11-22, branch feature/history-multicopy.
