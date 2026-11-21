---
id: history-multi-paste-2026-11-22
type: decision
title: Island History pastes several marked rows in one opening
summary: Enter in the island's History pasted one row and closed the panel, so several files took one reopening each; ⌘-click now marks rows in order and Enter pastes all of them, files together in one Cmd+V.
status: confirmed
tags: [history, clipboard, paste, island]
canonical_for: [history-multi-paste]
verified_at: 2026-11-22
sources:
  - type: user-confirmed
    reference: On 2026-11-22 the maintainer reported that Enter closes History, so pasting several files meant reopening it for each file and took long.
    confirmed_at: 2026-11-22
  - type: repository
    reference: Sources/Sidekey/History/HistoryMultiPaste.swift
    confirmed_at: 2026-11-22
  - type: repository
    reference: Sources/Sidekey/History/HistoryHoverView.swift
    confirmed_at: 2026-11-22
  - type: repository
    reference: Sources/Sidekey/AppDelegate.swift
    confirmed_at: 2026-11-22
  - type: repository
    reference: Tests/SidekeyTests/History/HistoryMultiPasteTests.swift
    confirmed_at: 2026-11-22
related: [2026-11-21-clipboard-no-entry-delete.md, 2026-11-21-history-backdrop-always.md]
---

# Context

History in the island takes key status while it is open so its local key
monitor receives Return. Enter on a hovered row writes that row to the
pasteboard, switches the drawer back to the tools (`panelMode = .controls`),
which resigns key so the synthetic Cmd+V reaches the remembered target, and
then posts Cmd+V. Every further row needed History opened again: hover the
island, open History, hover the row, press Return.

# Decision

With a paste target, ⌘-click marks History rows in click order; a blue badge
shows each row's number and ⌘-click again unmarks it. Enter pastes the marked
rows (instead of the hovered one) and closes History as before. Escape clears
the marks; without marks it passes on as before. Plain click (copy) and plain
Enter on one row are unchanged. The footer says "⌘-click for several" and,
once rows are marked, "Enter to paste N to <app>   Esc to clear".

`HistoryPastePlan` keeps mark order and merges neighbouring rows of one kind:
files and images become one pasteboard write with one item each (one Cmd+V,
as Finder copies several files), texts one paste with a line each. Text, files,
text are three pastes. `HistoryMultiPaster` posts them 400 ms apart and stops at
the first Cmd+V the engine could not post.

The series is bound to the target remembered when Enter was pressed. Before
each pasteboard write the paster checks that the app still runs and is still
the engine's remembered target; `AutoPasteEngine.pasteAlreadyOnPasteboard(into:)`
checks again, restores focus, and posts Cmd+V only if that app is frontmost.
Otherwise the rest of the series stops with no key event and the pasteboard
keeps the last pasted content. A single-row paste keeps its old behaviour. Marks live while the panel is open,
survive switching the Agent, Drop and Clipboard tabs and are off without a paste
target and in the Toolbox History pane, where ⌘-click copies as before.
Multi-row pastes are suppressed from clipboard history like History's Copy.

# Why

The complaint is several files. Marking them and pressing Enter once attaches
all of them in a single paste: the shortest path, and it reuses the one proven
paste step (resign key, restore target, Cmd+V) without new focus handling.
A paste with several file items is what Finder produces, so chats, mail and
forms that accept dropped or pasted files take all of them.

# What was tested

Scenario tests (`HistoryMultiPasteTests`): one hovered row is still one paste
with the same pasteboard content; three marked files in mark order are one
write of three URLs and one Cmd+V; texts join with line breaks; text, two
files, text are three pastes with the gap between them; a failed paste stops
the rest; nothing marked and nothing hovered leaves Enter alone; ⌘-click again
unmarks and renumbers; Escape clears marks and otherwise passes; the footer and
the absence of marking without a target. The builder's review found that in
the gap between pastes a new target capture (Drop, History reopened elsewhere)
or the target app quitting sent the next Cmd+V to another app;
`AutoPasteEngineTests` now run the series through the real engine with fake
events for both cases, plus a replaced target after the series check and focus
that cannot return, and none posts a key event outside the target. Offscreen renders of the panel with
the hint, three marked files and mixed rows. Not verified in the installed app:
real ⌘-click delivery on the island panel and how particular apps treat a paste
that mixes several file items.

# Rejected

- ⌥Enter pastes and keeps History open: the panel must give up key for Cmd+V
  and take it back after every paste, a new focus dance on the non-activating
  panel; several files still need one press each.
- Keep History open after every Enter: typing after a paste would go to the
  island while it holds key; changes the common single paste.
- A paste queue that swaps the clipboard on each ⌘V in the target: needs a
  global ⌘V interception and is invisible state; larger than the complaint.
- One write with mixed text and file items: apps differ in which items they
  read, so text could be dropped silently; separate pastes are predictable.

2026-11-22, branch feature/history-multipaste.
