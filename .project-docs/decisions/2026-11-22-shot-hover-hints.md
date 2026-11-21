---
id: shot-hover-hints-2026-11-22
type: decision
title: Shot's toolbar shows its own hover help, and hover search finds Copy text by OCR words
summary: The Shot editor's buttons already carried AppKit tool tips that never appeared, because Whytap stays inactive while the editor's nonactivating panels float at screen-saver level; ScreenshotHoverHint now shows that help in its own click-through panel above the editor, and island search finds Shot's Copy text by "OCR", "recognize text" and similar English and Russian words.
status: confirmed
tags: [screenshots, toolbar, tooltips, accessibility, hover-search]
canonical_for: [screenshot-hover-help]
verified_at: 2026-11-22
sources:
  - type: user-confirmed
    reference: On 2026-11-22 the maintainer learned only from another conversation that Shot already has Copy text (the document-in-a-frame icon beside Share) and asked for help on hover for the Shot editor's buttons, so its icons explain themselves.
    confirmed_at: 2026-11-22
  - type: repository
    reference: Sources/Sidekey/Screenshots/ScreenshotHoverHint.swift
    confirmed_at: 2026-11-22
  - type: repository
    reference: Sources/Sidekey/Screenshots/ScreenshotToolbarButton.swift
    confirmed_at: 2026-11-22
  - type: repository
    reference: Sources/Sidekey/Screenshots/ScreenshotCoordinator.swift
    confirmed_at: 2026-11-22
  - type: repository
    reference: Sources/Sidekey/DynamicIsland/IslandHoverToolSearch.swift
    confirmed_at: 2026-11-22
  - type: repository
    reference: Tests/SidekeyTests/Screenshots/ScreenshotHoverHintTests.swift
    confirmed_at: 2026-11-22
related: [2026-10-20-screenshot-toolbar.md, 2026-10-17-hover-tool-search.md]
---

# Context

Every Shot toolbar button already had a `toolTip`, Copy text included
("recognize text and numbers on this Mac, copy and exit"). The maintainer had
never seen one and did not know Copy text existed. The editor is a set of
`.nonactivatingPanel` windows at `.screenSaver` level, and Shot never activates
Whytap (it returns focus to the previous app on close). AppKit shows tool tips
only for the active application, in a window below that level, so these tool
tips could not appear. The adjacent settings panel (color, width, shape, blur
mode) had the same problem.

# Decision

- `ScreenshotHoverHint` shows the help: one borderless, nonactivating,
  click-through panel at `.screenSaver + 1`, below the control (above it when
  there is no room), kept on the display. The first hint waits 0.45 s; moving
  to the next control within 0.4 s shows its hint at once, as AppKit does. A
  click, key press or scroll (local event monitor while a hint is pending or
  shown), leaving the control, an empty selection and closing the editor hide it.
- `ScreenshotToolbarButton` keeps its text in `toolTip` but no longer registers
  an AppKit tool tip, so a hint can never appear twice when Whytap happens to
  be active; the text is also the button's accessibility help. The hover
  tracking area it already had (`.activeAlways`) drives the hint. Settings
  controls carry their help in `ScreenshotSettingHover`, with `toolTip` cleared.
- Texts are short: name, key, then what it does ("Blur · B — blur text and
  numbers or a whole area"; "Copy text — recognize the text in the selection,
  copy it and close (OCR on this Mac)"). The long tails ("Click again to stop
  drawing…", "Drag onto an arrow to assign") were dropped from the hints; the
  guide keeps them. Arrow-key pairs say "↑ key: Blur — click to choose another
  action or drag a toolbar tool here. Changes save immediately."
- Island hover search: Copy text is a command inside Shot's editor, not a tool,
  so it is found through Shot. `copyTextAliases` adds OCR, recognize, copy text,
  text from screen and the Russian words for recognize, copy text and text from
  the screen. When a query
  is explained only by those words, the Shot result reads "Shot — Copy text"
  with "Select an area, then click Copy text (OCR)"; ordinary Shot queries keep
  the usual label.

# Why

The buttons are icons; without visible help a feature like Copy text is
invisible. Making Whytap active to get AppKit tool tips would take focus from
the user's app during a screenshot, which the editor deliberately avoids, and
the tool tip would still sit below the screen-saver-level panels. A private
panel is the only way to show help over this editor.

A separate Copy text catalog tool (capture and recognize in one action) would
be a new feature with its own hotkey, Toolbox tile and link destination; the
request was to make the existing command findable, so search points to Shot and
says where to click.

# What was checked

- `ScreenshotHoverHintTests`: all 17 toolbar buttons have short help equal to
  their accessibility help, with the documented keys; settings controls have no
  AppKit tool tip and do have accessibility help; hint placement (below, flipped
  above, clamped to the display); the delayed first hint, immediate next hint,
  leave/hide and no hint for a hidden editor, in an offscreen nonactivating panel.
- `IslandHoverToolSearchTests`: the OCR queries find Shot first with the Copy
  text label; "shot", the Russian words for screenshot and text keep the Shot
  label; "copy" still
  finds Clipboard.
- Offscreen renders of the Copy text, Blur, Share and ↑ hints in light and dark
  (`WHYTAP_SHOT_HINT_RENDER_DIR`). The editor's materials draw only in a live
  window, so the renders use flat stand-in backgrounds.
- Not checked: the hint in the installed app with a real pointer over the live
  editor, multiple displays and Reduce Transparency.

# Rejected

- Activating Whytap while the editor is open: steals focus and AppKit tool tips
  would still be under the screen-saver-level panels.
- Raising the editor's tool tips through `NSToolTipManager`: private API.
- A new Copy text catalog tool: a feature change beyond making the command findable.

2026-11-22 · branch feature/shot-tooltips
