---
id: toolbox-drag-feedback-2026-10-18
type: decision
title: Toolbox drop targets match insertion positions and show immediate feedback
summary: The permanent Add target matches insertion geometry; native AppKit drop preparation removes its preview before the committed tool is drawn.
status: confirmed
tags: [toolbox, hover, drag-and-drop, animation, accessibility]
canonical_for: [toolbox-drag-feedback]
verified_at: 2026-10-18
sources:
  - type: user-confirmed
    reference: On 2026-10-18 the user confirmed that installed Exodia 2.2.10 no longer duplicates the cursor and inserted icons when dropping into Add.
    confirmed_at: 2026-10-18
  - type: trace
    reference: /tmp/exodia-toolbox-handoff-focused-tests.log, 33 focused tests with 0 failures in 2.110 seconds for native handoff and actual hosted geometry.
    confirmed_at: 2026-10-18
  - type: trace
    reference: /tmp/exodia-toolbox-handoff-proof/manifest.json, two source hashes and 14 actual native-hosted editor/card/Add PNGs with no visible/key windows.
    confirmed_at: 2026-10-18
  - type: user-confirmed
    reference: On 2026-10-18 the user initially accepted the installed 2.2.8 placement improvements, then reported simultaneous native cursor preview and inserted icon after release; this supersedes seamless-handoff acceptance.
    confirmed_at: 2026-10-18
  - type: repository
    reference: Sources/Sidekey/Settings/ToolboxNativeDropTarget.swift
    confirmed_at: 2026-10-18
  - type: repository
    reference: Tests/SidekeyTests/Settings/ToolboxNativeDropTargetTests.swift
    confirmed_at: 2026-10-18
  - type: url
    reference: https://developer.apple.com/documentation/appkit/nsdragginginfo/animatestodestination
    confirmed_at: 2026-10-18
  - type: url
    reference: https://developer.apple.com/documentation/appkit/nsdraggingdestination/performdragoperation(_:)
    confirmed_at: 2026-10-18
  - type: user-confirmed
    reference: On 2026-10-18 the user reported delayed placeholder filling and apparent freezing while dragging tools into the hover registry in Settings, then approved trying the two reviewed fixes.
    confirmed_at: 2026-10-18
  - type: repository
    reference: Sources/Sidekey/Settings/ToolboxSettingsView.swift
    confirmed_at: 2026-10-18
  - type: repository
    reference: Tests/SidekeyTests/Settings/ToolboxHoverEditorTests.swift
    confirmed_at: 2026-10-18
  - type: trace
    reference: /tmp/exodia-toolbox-drag-focused-tests.log, 28 focused tests with 0 failures in 2.289 seconds.
    confirmed_at: 2026-10-18
  - type: trace
    reference: /tmp/exodia-toolbox-drag-proof/manifest.json, 14 actual editor/card/Add PNGs and source hash, unordered non-key windows with isolated preferences.
    confirmed_at: 2026-10-18
related: [../project.md, 2026-10-18-clipboard-retention.md, 2026-10-20-toolbox-mini-apps.md, 2026-11-22-toolbox-tool-hotkey.md]
---

# Toolbox drag feedback

## Context

The editor previously drew Add after Settings but inserted new tools before
Settings. With six saved tools, releasing a new tool over Add placed it in
the preceding row; Settings moved into the released cell and Add moved again.
The targets had no drag-entry feedback and the grid did not animate changes.

An isolated production-store probe returned from mutation plus UserDefaults
set in a median 0.058 ms (2,000 mutations). This excludes UI subscribers,
native dragging, payload loading, frame rendering and durable disk flush; it
does not establish the cause or duration of a physical UI pause.

## Decision

`ToolboxHoverEditor` owns the grid separately from the tool configuration
panels. Its stable item identities are the tool IDs and one permanent Add ID.
It draws editable tools, Add, then pinned Settings. A new tool therefore fills
the previous Add position, including when insertion crosses a row boundary.
Settings remains last in the saved layout and the editor and has no drop
target. Valid self/end drops with no order change are accepted without a
preference write, avoiding failed-drop return feedback.

Native destination callbacks update only transient highlighting. The accent overlay does not
change layout, intercept events or add accessibility elements. Late exit events
clear only their own target. Highlighting uses 0.1 seconds and committed grid
changes use 0.18-second easing with an opacity insertion/removal transition.
Reduce Motion disables both animations.

Only the accepted native `performDragOperation` calls `HoverLayoutStore.placeTool`. Its target
index is resolved from the current tool identity rather than a captured grid
index. Drag entry and cancellation do not persist layout changes. The store,
raw IDs, positional hotkeys and plain-view draggable source remain unchanged.

## Native preview handoff

The installed 2.2.8 build 1460 improved placement, but the user then reported
two simultaneous representations after release: the native drag image by the
pointer and the already inserted tool. PR #23 had merged, but its publisher
was never started; this candidate was not publicly released.

`ToolboxDropTargetView` hosts each actual SwiftUI card in a normal registered
NSHostingView destination. It preserves source `.draggable(String)`, forwards
environment/transaction values and has the existing 56x88-point footprint.
Settings has no registered drop types. Ordinary native hit testing is retained;
there is no transparent hit-test overlay, empty preview or custom mouse loop.

The destination registers `.string`, matching String's public UTF-8 text
transfer representation. Entry/update validate and cache only transient data.
Prepare refreshes and validates the current payload, then sets
`NSDraggingInfo.animatesToDestination=false`. AppKit inspects this flag between
prepare and perform and removes its image without a destination animation.
Only then does perform revalidate the prepared sequence/payload and commit the
layout. Cancel, invalid data, stale sessions and exit do not save preferences.
The application's existing grid animation remains; no fixed-delay timer or
manual drag-image replacement participates in the handoff.

## Alternatives

Reordering saved preferences on every drag-entry event was rejected: an
aborted drag would then need rollback and moving targets could cause jitter.
Animating or changing the live island was outside this Settings-only fix.

## Verification boundary

Earlier 2.2.8 checks passed 28 focused tests and captured 14 before/after PNGs,
but did not establish native preview handoff. The later user counterexample
remains authoritative for that installed candidate.

The native handoff candidate passed 33 focused tests. Hosted checks use an
isolated defaults suite and the actual native editor in an unordered offscreen
window, without initializing Case/Vocab/provider stores. Fourteen before/after
PNGs were captured and the five-tool pair was inspected. Tests measure native
cell bounds, registered drop types and hit testing, Add-to-tool coordinates
across row boundaries, removal and settled reorder positions with both Reduce
Motion inputs. The original 2.2.8 leaf transaction probe cannot measure parent
layout motion across the new hosting roots; current tests do not assert
optical animation frames.

Native lifecycle tests use fake dragging info and isolated pasteboards,
verifying the flag is set before any commit, plus cancellation, validation,
stale-session and configuration cleanup. They do not render a real native
drag preview. No GUI test window may appear over the user's work. Native
pointer dragging, absence of the double icon and perceived smoothness require
installed-app acceptance; hidden checks do not prove an NSDragging latency fix.

On 2026-10-18 the user performed the installed 2.2.10 native drop check and
confirmed there is no duplicate image. This supplies the separate physical
handoff acceptance; it does not expand the hidden fixtures' measurement scope.

The unchanged native handoff ships in public 2.2.11 build1463. Installed
restart and public archive/feed verification are recorded in the
[clipboard retention decision](2026-10-18-clipboard-retention.md). The user
accepted duplicate-image absence in installed 2.2.10; no later handoff source
change was made for the twenty-copy feed or BYOK-only base integration.
