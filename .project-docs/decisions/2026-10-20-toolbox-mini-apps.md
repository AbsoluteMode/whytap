---
id: toolbox-mini-apps-2026-10-20
type: decision
title: Toolbox keeps Add visible and hosts working tool panels
summary: A fixed header keeps Add and Settings visible while saved tools scroll horizontally; catalog selection opens working mini apps or explicit action controls.
status: confirmed
tags: [toolbox, hover, drag-and-drop, translation, mini-apps, accessibility]
canonical_for: [toolbox-mini-apps, toolbox-pinned-add]
verified_at: 2026-10-20
sources:
  - type: user-confirmed
    reference: On 2026-10-20 the user reported inaccessible dragging and missing in-Toolbox interactions, requesting mini apps and an always-visible empty slot.
    confirmed_at: 2026-10-20
  - type: repository
    reference: Sources/Sidekey/Settings/ToolboxSettingsView.swift
    confirmed_at: 2026-10-20
  - type: repository
    reference: Sources/Sidekey/Settings/ToolboxMiniApps.swift
    confirmed_at: 2026-10-20
related: [2026-10-18-toolbox-drag-feedback.md, 2026-10-20-translation-tools.md, 2026-10-20-whytap-links.md, 2026-11-20-toolbox-system-background.md]
---

# Toolbox mini apps and a fixed Add target

The Settings Toolbox header stays outside the independently scrolling catalog
and tool pane. Saved tools scroll horizontally; Add and locked Settings remain
visible at the right, even when every catalog tool is pinned. Clicking Add opens
a chooser; dropping on it appends or moves the tool to the end. This replaces
the earlier Settings editor's wrapping-grid Add geometry. The live island grid
and its saved layout format are unchanged.

Catalog tools remain clickable and draggable after pinning. A checkmark and
VoiceOver value communicate membership. The tool header and context menu offer
Add/Remove. Keyboard Return/Space and the accessibility action select tiles.
Selecting a navigation/action tool stays in Toolbox until its explicit action
button is pressed.

Translate and Subtitles embed the existing translation view with compact
spacing, sharing the floating window's models, preferences, errors and provider
routes. Each surface owns its presentation mode. Selecting a tool starts no
provider request or audio capture. A token identifies the embedded session so
an old view's teardown cannot cancel its replacement. Leaving the tool or
closing Settings cancels requests/capture when the floating window is not
visible. A separately visible translator keeps ownership. Embedded visibility
participates in the existing update activity guard, including unsent text.

History embeds the existing bounded history view with explicit Copy; it does
not install the island's keyboard-to-paste monitor in Settings. Monitor reuses
its existing dashboard panel and start/stop lifecycle. Record observes the
shared recording state and invokes the existing recording action. Screenshot,
Hotkeys, Notes, Quit and Settings expose explicit actions rather than blank
panes; editors needing another surface open that existing surface.

Tests use isolated preferences, fake providers/audio and unordered offscreen
windows. They cover fixed Add geometry with all tools, native drop lifecycle,
translation activity ownership/capture cancellation and compact renders. These
checks do not replace installed-app acceptance for pointer drag smoothness,
real provider requests or device permissions.
