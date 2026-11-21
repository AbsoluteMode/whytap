---
id: native-hover-glass-2026-10-17
type: decision
title: Native Apple Liquid Glass for hover surfaces
summary: Match hover to the compact island width with three icon-and-title capsules per row and one independent Regular backdrop; recording lights the icon.
status: confirmed
tags: [macos, hover, liquid-glass, swiftui, accessibility]
canonical_for: [hover-glass-material]
verified_at: 2026-10-19
sources:
  - type: user-confirmed
    reference: On 2026-10-19 the user requested removing small tile captions and lighting the Record icon during recording, since the right wing already shows recording status.
    confirmed_at: 2026-10-19
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
  - type: trace
    reference: /tmp/exodia-search-loupe-explicit-tests.log, 10 focused tests with 0 failures in 3.933 seconds for the explicit native-button-aligned glyph candidate.
    confirmed_at: 2026-10-18
  - type: trace
    reference: /tmp/exodia-search-loupe-explicit-full-tests.log, full 2950 tests with 8 skipped and 0 failures in 47.511 seconds.
    confirmed_at: 2026-10-18
  - type: trace
    reference: /tmp/exodia-search-loupe-explicit-proof/manifest.json, 60 source-matched native/transparent/explicit-glyph comparison PNGs with no visible/key windows.
    confirmed_at: 2026-10-18
  - type: user-confirmed
    reference: Live user feedback on 2026-10-18 confirmed the search loupe remained cropped after Monitor -> Back in the locally installed 2.2.6 candidate.
    confirmed_at: 2026-10-18
  - type: trace
    reference: gh release view v2.2.6 --repo AbsoluteMode/exodia reported isDraft=true and publishedAt=null on 2026-10-18 after publication was stopped.
    confirmed_at: 2026-10-18
  - type: trace
    reference: /tmp/exodia-monitor-search-final-tests.log, full 2949 tests with 8 skipped and 0 failures in 45.711 seconds for the Monitor layout/search return candidate.
    confirmed_at: 2026-10-18
  - type: trace
    reference: /tmp/exodia-search-return-focused-tests.log, 9 focused hosted-search tests with 0 failures in 3.901 seconds.
    confirmed_at: 2026-10-18
  - type: trace
    reference: /tmp/exodia-monitor-layout-offscreen/render-manifest.json and source-manifest.json, 16 source-matched production-layout fixtures with 20 current PNGs and no visible/key windows.
    confirmed_at: 2026-10-18
  - type: trace
    reference: /tmp/exodia-search-return-proof/manifest.json, 40 source-matched offscreen native-search snapshots and hosted resize/remount geometry with no visible/key windows.
    confirmed_at: 2026-10-18
  - type: user-confirmed
    reference: User clarified on 2026-10-18 that the Monitor heading must remain and be precisely centered, its panel must match the normal controls height and long dashboard lists must scroll vertically.
    confirmed_at: 2026-10-18
  - type: repository
    reference: Tests/SidekeyTests/DynamicIsland/IslandHoverPanelControlTests.swift
    confirmed_at: 2026-10-18
  - type: trace
    reference: /tmp/exodia-hover-icons-focused-tests.log, 101 focused tests with 0 failures for the larger-icon refinement.
    confirmed_at: 2026-10-18
  - type: trace
    reference: /tmp/exodia-hover-icon-proportions-offscreen/render-manifest.json and source-manifest.json, 18 source-matched offscreen layout renders with no visible or key windows.
    confirmed_at: 2026-10-18
  - type: user-confirmed
    reference: User feedback on 2026-10-18 reported that the compact hover icons looked too small after the equal-width change.
    confirmed_at: 2026-10-18
  - type: user-confirmed
    reference: User request on 2026-10-17 to delegate Apple Liquid Glass hover styling to the Argon agent, with a Control Center reference image.
    confirmed_at: 2026-10-17
  - type: user-confirmed
    reference: User feedback on 2026-10-17 reported flat gray glass, off-center buttons, missing hover feedback and unreliable clicks; the supplied LiquidButton reference requested a transparent lens with a bright edge and inner shine.
    confirmed_at: 2026-10-17
  - type: user-confirmed
    reference: User feedback after the 2.2.1 publication on 2026-10-17 reported black search and History surfaces and insufficient white-foreground contrast when focused Clear glass was shown over a white background.
    confirmed_at: 2026-10-17
  - type: user-confirmed
    reference: User requested on 2026-10-17 that test windows never appear over their work again; subsequent visual checks must remain offscreen.
    confirmed_at: 2026-10-17
  - type: trace
    reference: build/visual-reference/exodia-search-v4-query-white.png and exodia-search-v4-pattern.png, local CUA-inspected actual-field fixture screenshots on 2026-10-17; bitmaps are not committed.
    confirmed_at: 2026-10-17
  - type: trace
    reference: /tmp/exodia-hover-panels-focused-tests.log, 109 focused tests with 0 failures for the Regular/search/History candidate.
    confirmed_at: 2026-10-17
  - type: user-confirmed
    reference: User selected three horizontal capsules per row with icon, title and current status inside on 2026-10-17, and requested Monitor dashboards inside hover.
    confirmed_at: 2026-10-17
  - type: user-confirmed
    reference: User clarified on 2026-10-17 that hover must have the same width as the island and confirmed three smaller capsules per row; this supersedes the earlier wider drawer.
    confirmed_at: 2026-10-17
  - type: trace
    reference: /tmp/exodia-matched-width-focused-tests.log, 69 focused tests with 0 failures for the compact-width candidate.
    confirmed_at: 2026-10-17
  - type: trace
    reference: /tmp/exodia-matched-width-full-tests.log, full 2947 tests with 8 skipped and 0 failures in 45.315 seconds for the compact-width candidate.
    confirmed_at: 2026-10-17
  - type: trace
    reference: /tmp/exodia-compact-hover-offscreen/render-manifest.json and source-manifest.json, 18 actual-component offscreen renders at 310/312 points with source-hash match and no visible/key windows.
    confirmed_at: 2026-10-17
  - type: trace
    reference: /tmp/exodia-capsules-final-tests.log, final 2947 tests with 8 skipped and 0 failures after the inline legacy callback and functional-test migration.
    confirmed_at: 2026-10-17
  - type: trace
    reference: /tmp/exodia-capsule-offscreen-proof/render-manifest.json and source-manifest.json, 21 actual-component offscreen renders with no visible or key windows.
    confirmed_at: 2026-10-17
  - type: repository
    reference: Sources/Sidekey/DynamicIsland/IslandHoverPanelControl.swift
    confirmed_at: 2026-10-17
  - type: repository
    reference: Sources/Sidekey/DynamicIsland/HoverToolPresentation.swift
    confirmed_at: 2026-10-17
  - type: repository
    reference: Sources/Sidekey/Monitor/MonitorHoverPanel.swift
    confirmed_at: 2026-10-17
  - type: repository
    reference: Sources/Sidekey/DynamicIsland/IslandHoverToolSearch.swift
    confirmed_at: 2026-10-17
  - type: repository
    reference: Sources/Sidekey/History/HistoryHoverView.swift
    confirmed_at: 2026-10-17
  - type: repository
    reference: Sources/Sidekey/History/HistoryHoverPreview.swift
    confirmed_at: 2026-10-17
  - type: repository
    reference: Sources/Sidekey/DynamicIsland/IslandHoverGlass.swift
    confirmed_at: 2026-10-17
  - type: repository
    reference: Sources/Sidekey/DynamicIsland/IslandView.swift
    confirmed_at: 2026-10-17
  - type: repository
    reference: Sources/Sidekey/DynamicIsland/IslandHoverHitBridge.swift
    confirmed_at: 2026-10-17
  - type: repository
    reference: Sources/Sidekey/DynamicIsland/IslandDropModeControl.swift
    confirmed_at: 2026-10-17
  - type: trace
    reference: build/visual-reference/exodia-hover-lenses-v3.png, local native fixture screenshot inspected on 2026-10-17; the bitmap is not committed.
    confirmed_at: 2026-10-17
  - type: trace
    reference: /tmp/exodia-hover-fix-full-tests.log, 2928 tests with 8 skipped and 0 failures before the final presentation-only background modifier.
    confirmed_at: 2026-10-17
  - type: trace
    reference: /tmp/exodia-hover-v3-focused-tests.log, 94 focused tests with 0 failures after the final background modifier.
    confirmed_at: 2026-10-17
  - type: url
    reference: https://developer.apple.com/videos/play/wwdc2025/323/
    confirmed_at: 2026-10-17
  - type: url
    reference: https://developer.apple.com/documentation/swiftui/environmentvalues/appearsactive
    confirmed_at: 2026-10-17
  - type: url
    reference: https://github.com/i-am-logger/macos-liquid-glass/blob/ccf01c88648400562c55a1366151f6f0c8b6f663/examples/common/mod.rs#L654-L671
    confirmed_at: 2026-10-17
  - type: url
    reference: https://developer.apple.com/documentation/swiftui/applying-liquid-glass-to-custom-views
    confirmed_at: 2026-10-17
related: [../project.md, 2026-10-17-hover-tool-search.md, 2026-10-18-brightness-tool.md, 2026-11-21-history-backdrop-always.md]
---

# Native hover glass

## Context

The first native-glass change used Regular material and delegated pointer
feedback to the native interactive effect. The user subsequently reported flat
gray glass, buttons displaced from the center, lost hover feedback and unreliable
clicks. Their LiquidButton reference requested a transparent lens with a bright
edge and inner shine. These reports supersede the earlier visual and interaction
policy; they are not a claim that every macOS backdrop renders identically.

The released 2.2.1 then received production feedback: search and History still
looked black, while focused Clear glass over a white background lost contrast
with the white controls. The 2.2.2 refinement addressed those surfaces;
its actual-field v4 check is separate from the earlier v3 fixture. The 2.2.3
candidate added three-column capsules and inline Monitor. After seeing that
layout, the user clarified on 2026-10-17 that hover should match the island's
width and confirmed three smaller capsules per row. That correction governs the
2.2.4 layout. On 2026-10-18 the user reported that its icons looked too small.
The next refinement enlarged only the icon presentation within the same capsules.
On 2026-10-18 the user then clarified the Monitor layout: retain and precisely
center its heading, keep the normal controls height and scroll long dashboard
lists vertically. Live feedback on the locally installed 2.2.6 candidate then
confirmed that Monitor -> Back still cropped the search loupe. The merged Monitor
layout and explicit native field-height correction remain valid partial changes;
they did not complete the reported visual fix. Publication was stopped, and
GitHub v2.2.6 remained a draft with `publishedAt=null` on 2026-10-18.

## Decision

On macOS 26 and later, apply one SwiftUI `glassEffect(.regular, in:)` backdrop per
drawer or music-strip card, on an independent transparent rounded rectangle
inside `content.background`. Do not apply the material modifier to the whole
foreground hierarchy: the lens gradient, rim and icon keep their independent
colors, matching the user's separate-layer reference. The current controls are
compact horizontal capsules in `IslandHoverPanelControl.swift`, defaulting to
90x52 points with a 30-point left icon disk, 17-point blue standard glyph, normal-case
11-point title inside. The 2026-10-19 user correction removes the small status
captions from every tile; actual current values remain in VoiceOver. Record
uses a red icon and soft glow while recording, with no second text line; the
existing right-wing recording indicator remains. Each grid instance receives
the width calculated from the actual compact island width. They are foreground
gradient/rim lenses without
a child native glass effect. `HoverToolPresentation` derives actual mode,
language and recording status; stateless navigation tools have no status. Apple's [WWDC25 session 323](https://developer.apple.com/videos/play/wwdc2025/323/)
explains that glass does not sample other glass. Avoid layering independent
native backdrops on top of the parent card. The existing controls container
remains, with explicit centered layout. Set `appearsActive=true` on the optical
background's environment without making the utility panel key. Apple's [appearsActive documentation](https://developer.apple.com/documentation/swiftui/environmentvalues/appearsactive)
controls preferred active styling; acquiring keyboard focus is a separate action.

Regular replaces Clear for adaptive contrast over white backgrounds, including
when search makes the panel key. Keep the independent backdrop and foreground
rims/lenses; do not restore an opaque black surface or nested native glass.
On macOS 26+, a custom `NSSearchFieldCell` draws its interior without the black
bezel, preserving native geometry and button tracking. Its shared field editor
is transparent; a foreground gradient/rim supplies the input lens. The native
search representable explicitly returns its declared 30-point height through
`sizeThatFits`, avoiding the 24-point intrinsic-height proposal that left the
native 24-point button rect one point outside the hosted field. Native cell
text/search/cancel geometry and transparent drawing remain unchanged. Offscreen
Monitor -> Back remounts did not reproduce the top slice reported by the user;
the 30-point fit corrects that measured sizing risk, but live 2.2.6 feedback
confirmed that it did not resolve the reported cropping. The exact desktop-
compositor cause remains unproved. The new candidate retains that 30-point fit
and original native button, makes its paint transparent, and draws a separate
non-hitting/non-accessibility loupe inside its native button rectangle on the
macOS 26 glass path. Native button action/geometry and older fallback remain;
see the precise [search contract](2026-10-17-hover-tool-search.md).
History uses
the common drawer backdrop, translucent row/hint lenses and an independent
preview backdrop. Existing transparent Case/Vocab/Filler panels are retained.
On macOS 14/15 History now also uses the drawer's legacy backdrop
([2026-11-21 decision](2026-11-21-history-backdrop-always.md)).

Add `IslandHoverGlassRim` as a thin specular edge and inner highlight, preserving
the native backdrop. The overlay uses `allowsHitTesting(false)` and never routes
a click. This is an original native implementation guided by the user's visual
reference; no third-party source was copied or dependency added. The
[pinned MIT upstream example](https://github.com/i-am-logger/macos-liquid-glass/blob/ccf01c88648400562c55a1366151f6f0c8b6f663/examples/common/mod.rs#L654-L671)
selects Clear rather than Regular and describes its own observed opacity
contrast. It is a reference, not proof of Whytap's visual result.

Restore explicit magnetic movement and hover/pressed scale feedback on both the
native and legacy paths. Reduce Motion suppresses translation, scaling and their
spring animations. The native material does not replace the control's explicit
feedback contract.

`HoverLayoutStore.columns` remains three. `IslandHoverControlsLayout` calculates
capsule width as `(panelWidth - 24 - 16) / 3`: three 90-point capsules fit a
310-point island, while a 312-point island gives each capsule about 90.67 points.
It centers 52-point targets in 68-point rows with a 76-point row stride,
eight-point row/column spacing and 12-point horizontal insets. New-install
defaults have six tools, two rows and a 243-point host band; existing selections
persist. Only four rows are visible, in a 312-point grid viewport. Thirteen
tools retain 388 points of full scroll content without removing anything from
the saved layout. Settings remains last and the first five positional hotkeys
are independent of the column count. Hints overlay stable targets.

The drawer, search, detached inline panels, music and native hit zones all use
the actual notch-derived `compactWidth`, rather than a fixed wider drawer.
History preview uses `leftHostReservation(compactWidth:)` with the original
300-point reservation and zero drawer overhang. A 280-point preview plus an
eight-point gap still leaves twelve points of padding, without shifting the
compact island's right/top anchors. Reserved capacity is not an extra
mouse-active area.

Monitor launches inline from capsules, search and positional hotkeys through
`.openPanel(.monitor)`, with a dashboard picker, Server status/custom content,
Refresh and Back navigation. The current heading stays visible and is precisely
centered between equal 88-point navigation/refresh slots. The controls and
Monitor modes share `controlsHoverPanelHeight(toolCount:)`: six selected tools
produce a 243-point host band and 235-point content; three tools produce
167/159 points. An active music strip adds 50 points to the host band for its
strip and gap. Monitor no longer uses an independent 344-point content height.
Its bounded vertical `ScrollView`/`LazyVStack` keeps additional dashboards
reachable without making the panel taller. Setup instructions and local path
text are omitted from this user-facing picker; the source customization guide
keeps that information.
The inline route enables `compactPresentation`: server metrics stack vertically
and custom widgets use one flexible column, fitting the compact drawer while
the legacy window retains its existing layout. It starts/stops the existing
MonitorStore with view visibility, without opening
a separate window or duplicating collectors. The standalone window remains for
compatibility as a class only. The production legacy `openMonitor` callback
also publishes an inline Monitor request with programmatic expansion; see
[dashboard contracts](../../docs/customization/dashboards.md).

Pointer dispatch belongs to `IslandHoverHitBridge` at `NSWindow.sendEvent`, using
measured target NSView frames clipped to visible scroll and region bounds. An
activation requires mouse-down and mouse-up on the same unchanged control.
Leaving a captured target cancels activation even if the pointer returns.
Context/geometry changes and Escape also cancel it while retaining ownership of
the eventual mouse-up. Hiding the panel discards the pending sequence without
activation. Geometry reporters never intercept clicks themselves.
Search focus is released by captured activation or actual window resignation,
not by an internal field-editor transition between down and up.

## Alternatives and supersession

The current Regular background supersedes Clear after the production white-
background contrast report. This is distinct from the first whole-content
Regular treatment: the background remains separate from foreground lenses.
The earlier same-day policy used `regular.interactive()` and restricted manual
motion and painted rims to older macOS. An intermediate Clear variant still put
native glass on both parent cards and child circles; the current refinement
replaces those child effects with foreground lenses. These earlier approaches
are superseded by the user's regression feedback and transparent-lens reference.
The prior requirement to apply native glass to the actual foreground content
for integrated vibrancy is also superseded: the optical backdrop is independent
of the foreground lenses and their colors. Merely increasing blur or making the
window key would not address the requested feedback and non-activating behavior.

The user's later equal-width correction supersedes the 2.2.3 457-point drawer
and 139x64-point capsule geometry. It retains three columns, icon/title/status,
inline Monitor and existing persistence; it does not request one long row or a
wider compact island.

The icon refinement keeps the equal-width geometry, three columns and 90x52
click targets. Disk size rises from 24 to 30 points and standard glyphs from
12 to 17 points; language text is 11 points and flag/ring presentations scale
with the disk. Title/status fonts stay at 11/10 points. This addresses the user
feedback without changing native material or interaction routing.

The older layered material remains the fallback for runtimes before macOS 26
and older toolchains. Availability guards preserve the macOS 14.2 deployment
floor. This decision does not restore the June fixed opaque wash to the native
path or flatten live glass into an offscreen bitmap.

## Explicit loupe candidate verification

The 2.2.7 candidate passed 10 focused tests with 0 failures in 3.933 seconds and
the full 2,950-test suite with 8 skipped and 0 failures in 47.511 seconds. Tests
verify the original transparent button's target/action through `performClick`
and its native hit testing, along with retained geometry and separate glyph
placement. They do not use a replacement click target.

The current source-matched proof contains 60 native/transparent/explicit-glyph
comparison PNGs across 310/312-point widths and earlier/matched Monitor heights,
with hidden-host removal/remount and the existing opacity/scale transition.
Explicit 310-point matched-height return and query images were inspected with
complete glyphs. Every proof window stayed invisible and non-key; the flat
backing and Monitor-labelled fixture are test-only, with no live MonitorStore
or user configuration access.

The exact physical clipping remains unreproduced offscreen. The fixtures verify
new drawing/geometry/action contracts and do not establish the private
compositor's cause. On 2026-10-18 the user separately tested installed Exodia
2.2.7, opened Monitor, returned with Tools and confirmed the loupe was fully
visible. The final integrated source passed 2,953 tests with 8 skipped and
0 failures in 51.673 seconds, including the current silent-meeting changes.

Public 2.2.7 build 1459 was published from sealed source
`a35ca9d5778c65e9dbb861535178696c887293ee`. Independent verification passed for
the public latest tag/feed, both immutable and latest DMG hashes/sizes,
Ed25519 signatures against repository and embedded keys, read-only mounted app
metadata, ad-hoc integrity, arm64/x86_64 architectures and installation checks.
The stopped 2.2.6 draft and its earlier proof remain separate.

## Historical 2.2.6 Monitor layout and search-return verification

The 2.2.6 candidate passed the full 2,949-test suite with 8 skipped and 0
failures in 45.711 seconds. Nine focused hosted-search tests passed with 0
failures in 3.901 seconds. These results cover the earlier height-only search
implementation. Subsequent live feedback reported continued loupe cropping;
they do not establish visual acceptance for that report or verify a later glyph
change. The 2.2.6 publication was stopped and remained a draft; these checks
do not establish a public 2.2.6 release. The historical 2.2.5/2.2.4 results below
cover earlier candidates.

Monitor proof contains 16 production-layout fixtures and 20 current PNGs across
310/312-point widths and 159/235-point content heights, with 1/21 dashboards,
selected-server and long-title headers, and programmatic scrolling to dashboard
20. The native scroll viewport is bounded at 92/168 points. The one-dashboard
picker, 21-dashboard bottom position and long-title header were inspected.
Only manifest-listed current fixtures count; older files in the output directory
are excluded. Synthetic no-op stores and dashboard-detail placeholders avoid
collectors, network calls and local user data.

Search proof contains 40 native-field snapshots across 310/312-point widths,
empty/query states and earlier/matched Monitor heights, with actual hidden-host
resize, field removal/remount and opacity/scale transition. The native 24-point
button rect fits inside the fixed 30-point field, identical bounds retain the
same native cell geometry, and full native render bytes remain stable across
remount. Fixed 310-point matched-height return and 312-point earlier-height
query outputs were inspected with complete icons. The tests do not autofocus
the field.

Both proof manifests matched that candidate's production sources and record invisible,
non-key windows with prohibited activation. Dark/flat backing is test-only. The
exact top slice in the user's image was not reproduced in the offscreen
baseline. The tests proved the native field-height correction, while later
live feedback showed the loupe still cropped. They do not establish the exact
desktop-compositor cause. Native glass, real pointer/physical focus, live
Monitor collectors/buttons and installed-app acceptance remain separate.

## Historical 2.2.5 icon refinement verification

The 2.2.5 candidate passed 101 focused layout, presentation, search and pointer
routing tests with 0 failures. Eighteen source-matched offscreen renders at
310/312 points covered standard tools, long language statuses and 13 selected
tools; all windows remained invisible and non-key. Standard and long-language
text-audit images were inspected. The explicit dark audit backing is test-only;
these images do not prove native screen glass, real pointer/focus behavior or
installed-app acceptance. No new GUI test window may appear over the user's work.

## Historical 2.2.4 compact candidate verification

The 2.2.4 candidate passed 69 focused tests with 0 failures and the full
2,947-test suite with 8 skipped and 0 failures in 45.315 seconds. The matching
source produced 18 actual capsule/search-layout offscreen renders at both
310-point and 312-point widths; the render/source manifests record matching
source hashes, no visible windows and no key windows. Standard and long-language
text-audit outputs were inspected. The dark audit backing is test-only.

These are geometry/text checks with synthetic states and an empty native-field
layout; they do not render the production search-result switch. They do not
prove the native compositor, real pointer activation, physical keyboard
input/focus or live Monitor-button interaction. Production acceptance and release
publication remain separate. None of the earlier fixtures or 2.2.3 results
establishes acceptance for this smaller layout. Do not display GUI test windows
over the user's work.

## Historical 2.2.3 candidate verification

The final suite passed 2,947 tests with 8 skipped and 0 failures in 42.184 seconds,
after the legacy callback was made inline and obsolete source-pattern checks
were replaced with functional routing, effect, spy and AX-state contracts.

The offscreen proof contains 21 PNGs plus render/source manifests for the actual
139x64 capsules and three-column 457-point grid. Its manifest records no visible
or key windows. Six-tool and thirteen-tool text audits covered long-status
ellipsis and layout fit without overflow. The deliberate black test backing is
not a rendered native-glass result. Native compositor output, real pointer
activation, keyboard focus and live Monitor-button interaction were not proved
by these offscreen checks; production acceptance remains separate.

That earlier wider drawer used `leftHostReservation(compactWidth:)` with a
300-point reservation plus 73.5 points of overhang for a 310-point island. Those
values describe the superseded 2.2.3 geometry, not the current compact candidate.

The earlier fixture results below predate this capsule/inline-Monitor change.
No new test windows may appear over the user's work.

The earlier Clear v3 native fixture was visually inspected through CUA on
2026-10-17, before the subsequent 2.2.1 production feedback.
White foreground edges and translucent lenses were visible, and the one-row and
two-row layouts were centered. A Settings click set the one-row Native counter
to 1; Monitor and Case clicks set the cumulative two-row Native counter to 1
and then 2. Each click activated once, SwiftUI fallback stayed 0, and the utility
remained non-key (`liveKey=false`). The local
screenshot is `build/visual-reference/exodia-hover-lenses-v3.png`; the bitmap is
not committed.

This verifies the component fixture over its controlled checkerboard backdrop.
It does not establish installed production-app behavior, sampling of the user's
external desktop, complete hover/accessibility acceptance or optical equality to
Control Center. Those checks must be reported separately; fixture results do not
establish a public release or successful production installation.

The Regular/search/History v4 fixture was checked through CUA on white and
patterned backdrops. Clicking the actual search field set `liveKey=true` and
`searchFocused=true`. AX `setValue` to `output` updated the delegate-bound query
and showed the native cancel button. First Escape cleared the query while the
window stayed key; second Escape released focus and key status. The card,
buttons and History row remained visible over both backgrounds. The 109 focused
tests passed with 0 failures.

These checks establish controlled editor appearance and delegate binding.
Automated typeText/paste did not verify physical keypress input and caused focus
loss, so no physical-typing claim is made. Installed production hover acceptance
and the external-desktop compositor remain separate checks. The local screenshots
are `exodia-search-v4-query-white.png` and `exodia-search-v4-pattern.png` under
`build/visual-reference/`; bitmaps are not committed.

The fixture was closed after inspection. At the user's explicit request,
subsequent checks must stay offscreen and must not show test windows over their
work. Offscreen results do not establish external-desktop optical behavior.

For the earlier Clear candidate, the full suite passed 2,928 tests with 8 skipped
and 0 failures before the final
presentation-only move of Clear glass onto its independent background shape.
Focused tests cover target identity, drag cancellation, viewport clipping, row
geometry and search field-editor transitions. The final focused run passed 94
tests with 0 failures after that last modifier; the earlier full run is not
presented as a rerun after it.

## Sources

The dated user requests and feedback, current native source files, Apple's
public API documentation and the pinned MIT example establish the decision.
The upstream reference explains the material choice; Whytap's own implementation
and live inspection determine its behavior.
