---
id: hover-tool-search-2026-10-17
type: decision
title: Search all hover tools without pinning them
summary: Keep frequent tools in the saved grid and find occasional tools through catalog search in the hover drawer.
status: confirmed
tags: [hover, search, keyboard, customization]
canonical_for: [hover-tool-search]
verified_at: 2026-10-18
sources:
  - type: user-confirmed
    reference: On 2026-10-18 the user tested installed Exodia 2.2.7, opened Monitor, returned with Tools and confirmed the search loupe was fully visible.
    confirmed_at: 2026-10-18
  - type: url
    reference: https://github.com/AbsoluteMode/exodia/releases/tag/v2.2.7
    confirmed_at: 2026-10-18
  - type: trace
    reference: /tmp/exodia-public-release-2.2.7-verification.log, independent public latest/source/feed, both DMG hashes/sizes, Ed25519 signatures, read-only app metadata/universal architectures/installation checks passed.
    confirmed_at: 2026-10-18
  - type: trace
    reference: /tmp/exodia-search-loupe-integrated-full-tests.log, final integrated full suite of 2953 tests, 8 skipped, 0 failures in 51.673 seconds.
    confirmed_at: 2026-10-18
  - type: url
    reference: https://developer.apple.com/documentation/appkit/nsbuttoncell/istransparent
    confirmed_at: 2026-10-18
  - type: user-confirmed
    reference: Live user feedback on 2026-10-18 confirmed the search loupe was still cropped after Monitor -> Back in the locally installed 2.2.6 candidate, despite the native field-height correction.
    confirmed_at: 2026-10-18
  - type: user-confirmed
    reference: User reported on 2026-10-18 that the search loupe was clipped after returning from Monitor to the normal hover controls.
    confirmed_at: 2026-10-18
  - type: user-confirmed
    reference: User request on 2026-10-17 for hover search to find Output Lang without keeping it among frequent tools.
    confirmed_at: 2026-10-17
  - type: repository
    reference: Sources/Sidekey/DynamicIsland/IslandHoverToolSearch.swift
    confirmed_at: 2026-10-17
  - type: repository
    reference: Sources/Sidekey/DynamicIsland/IslandView.swift
    confirmed_at: 2026-10-17
related: [../project.md, 2026-10-17-native-hover-glass.md, 2026-10-18-brightness-tool.md, 2026-10-20-whytap-links.md, 2026-11-22-shot-hover-hints.md]
---

# Hover catalog search

The controls drawer places a search field above the user's selected tools.
An empty query shows the saved three-column capsule grid, with at most four
visible rows and scrolling for additional selected tools. A nonempty query searches the full catalog
by title, description and English/Russian aliases, prioritizing title matches.
Results replace the grid area and can scroll; the drawer keeps its current
height. A query with no matches shows an empty-state message.

Choosing a result invokes the same tool effect as its tile and does not add,
remove or reorder saved tools. In particular, Output Lang remains discoverable
when absent from the saved grid and retains the existing Smart-mode requirement.
Monitor results open the inline dashboard picker in the same hover drawer, just
like its capsule and positional hotkey; they do not launch a separate window.

Clicking the search field explicitly acquires keyboard focus. Merely hovering
does not take focus from the user's app. Up/Down navigate results, Return opens
the selection and Escape first clears the query, then releases focus. Opening
an inline tool transfers the open state from search focus to the existing
programmatic expansion policy. AppKit receives the full expansion state so
the resulting picker remains clickable while the pointer is outside the pill.
An internal `controlTextDidEndEditing` transition does not resign the key window
between a result's mouse-down and mouse-up. Captured activation or actual window
resignation releases text-entry focus.

Tile and search-result pointer activation uses `IslandHoverHitBridge` with
measured, visible NSView frames. Scrolled-out rows cannot cover the search field
or footer. The same unchanged target must own down and up; leaving it, changing
context or closing the panel cancels the activation. Geometry reporters remain
passive. See [hover material and interaction policy](2026-10-17-native-hover-glass.md).

The controls height includes the 42-point search band for rendering and hit
testing. Settings stays pinned last; the first five saved positions retain
their positional shortcuts. Search is a launcher for occasional tools, not an
alternative persistence format.

## Native field height and subsequent live feedback

The 2.2.6 search `NSViewRepresentable` explicitly returns the declared 30-point field
height in `sizeThatFits`, instead of accepting AppKit's 24-point intrinsic
height. With a 24-point hosted view, the native search/cancel button rectangle
was measured at y=1 with height 24, overflowing by one point. At the declared
30-point height it sits at y=4 with height 24, fully inside the view. The native
cell still calculates text, search and cancel rectangles from the actual bounds;
its transparent interior drawing is unchanged, and no replacement loupe was
introduced by that height-only change.

Live user feedback on 2026-10-18 confirmed that the locally installed 2.2.6
candidate still cropped the loupe after Monitor -> Back. Its 30-point fit is a
partial correction, not completed visual acceptance. Publication was stopped;
GitHub v2.2.6 remained a draft with no publication timestamp. The new glyph
candidate has separate drawing/action checks below; installed-app user
acceptance is still required before a confirmed live visual-fix claim. Earlier
successful offscreen checks do not override the live report.

Offscreen hosted remounts at the earlier 352-point Monitor band and matched
243-point band did not reproduce the physical top slice in the user's image.
This change removes a concrete sizing/clipping risk; it does not prove the exact
desktop-compositor cause of that report. Nine focused hosted-search tests passed
with 0 failures in 3.901 seconds. That historical source-matched proof contains 40
native-field snapshots with hidden-host resize/remount across 310/312 points,
empty/query states and earlier/matched Monitor heights; no window became visible
or key. It verifies in-bounds native rectangles and stable render bytes without
autofocusing the field. The 2.2.6 results and precise limits are
recorded in [the hover decision](2026-10-17-native-hover-glass.md); previous
search proofs below cover their stated earlier scopes.

## Explicit loupe paint with the original native button

The 2.2.7 candidate keeps the 30-point native-field fit. On the macOS 26 glass
cell path, `IslandHoverSearchNativeField` retains the original `searchButtonCell`
and sets its `isTransparent=true`: native button identity, image metadata,
target/action and `searchButtonRect` geometry stay intact. Native text/cancel
layout and recents behavior remain. Apple's [isTransparent documentation](https://developer.apple.com/documentation/appkit/nsbuttoncell/istransparent)
states that transparent buttons retain mouse tracking and action dispatch while
omitting paint. Focused tests also check the original button's `performClick`
action and native hit testing.

A separate `IslandHoverSearchGlyphView: NSImageView` draws the public SF Symbol
`magnifyingglass` at 13 points in a maximum 14-point square centered inside
`searchButtonRect(forBounds:)`. Its `hitTest` returns nil and its accessibility
element flag is false, so input and accessibility remain with the labelled
native search field and button. Setup runs only during init/layout, acquires no
focus and does not alter the parent transition. Older fallback is unchanged.

Ten focused tests passed with 0 failures in 3.933 seconds. Sixty source-matched
offscreen native/transparent/explicit-glyph comparisons cover the retained
button contracts and independent glyph drawing with all windows invisible and
non-key. The original physical top slice was not reproduced offscreen, so these
fixtures do not establish its exact compositor cause. On 2026-10-18 the user
separately confirmed the loupe was fully visible in installed Exodia 2.2.7 after
Monitor -> Tools. Public 2.2.7 build 1459 passed independent source/feed,
archive/signature and read-only packaged-app verification. Full integrated
results, source identity and proof limits are in the
[hover decision](2026-10-17-native-hover-glass.md).

## Earlier verification

Before the subsequent user-reported hover regression, on 2026-10-17, the separate Exodia Beta development bundle accepted `output`
and `output lang` in the real hover field. Return and a pointer click each
opened the output-language picker while Output Lang was absent from the saved
grid. Escape closed the picker without changing the selected language. Native
NSSearchField bezel/insets keep the query clear of its search and cancel icons.
The 180 focused hover/search tests passed; full private Control Center optical
equality is outside this functional check.

## Regression follow-up

The later click/focus regression changes measured pointer routing and the
field-editor transition policy described above. The unique v3 native component
fixture verified Settings, Monitor and Case pointer activation with no duplicate
SwiftUI fallback activation while remaining non-key. See the precise checks and
limits in [the hover-glass decision](2026-10-17-native-hover-glass.md). This does
not repeat full search or hover acceptance in the installed production app; the
earlier search check and the component fixture cover different verification scopes.

Historical 2.2.3 capsule/inline-Monitor verification passed 2,947 tests (8 skipped, 0
failures), with 21 offscreen layout/text renders. These do not prove native
pointer, physical keyboard input or real Monitor-button interaction. Earlier
narrow-grid fixtures cover a different layout; production acceptance stays
separate. Use offscreen checks only, without displaying test windows over the
user's work.

The later user-confirmed equal-width correction keeps three smaller capsules per
row and gives search the actual compact island width. The historical 2.2.4 candidate
passed 69 focused tests and the full 2,947-test suite (8 skipped, 0 failures).
Eighteen source-matched offscreen capsule/search-layout renders cover 310/312
points without visible/key windows. These use an empty native-field layout,
not the production search-result switch, and do not prove real pointer,
physical input/focus or the native compositor. The earlier results above cover
the previous geometry. See the canonical
[hover-glass decision](2026-10-17-native-hover-glass.md).
