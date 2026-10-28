# Add or change a hover tool

The user chooses any number of tools in **Settings, Toolbox**. Selected tools wrap
into rows of three compact capsules, 52 points high. The drawer has exactly the
same width as the compact island, using its actual notch-derived `compactWidth`.
Each cell width is `(panelWidth - 24 - 16) / 3`: 90 points for a 310-point island,
or about 90.67 for 312 points. Each shows an icon and title inside,
with a current status when the tool has state. Settings stays last and cannot
be removed. The Settings editor keeps Add and Settings fixed in its header;
saved tools scroll horizontally while the catalog scrolls vertically below.
Click Add to choose a tool, or drag a tile onto it. Already pinned catalog tiles
remain usable and draggable. The right pane hosts mini apps; its header and
context menu can add/remove a tool. The live hover grid shows the selected tools. The search
field above it searches the full catalog and launches a tool without pinning it.
At most four rows are visible in a 312-point grid viewport; the thirteenth
and later selections scroll without being removed. New-install defaults have six
tools, two rows and a 243-point host band; existing selections persist. Every catalog tool can have an optional named shortcut in Settings → Hotkeys,
independent of whether it is selected or where it appears.

## Source map

All paths below start at `Sources/Sidekey/`.

| Responsibility | Source |
| --- | --- |
| Persisted identity, title, icon, description and kind | `Settings/HoverTool.swift` (`HoverToolRegistry` is in the same file) |
| User selection, reorder, insertion, removal and column count | `Settings/HoverLayoutStore.swift` |
| Tool to activation effect, inline panel requests | `DynamicIsland/HoverSlotRouter.swift` |
| Action closures and preview defaults | `DynamicIsland/IslandActions.swift` |
| Capsule icon/title/status and explicit feedback | `DynamicIsland/IslandHoverPanelControl.swift`, `DynamicIsland/HoverToolPresentation.swift` |
| Inline views, shared three-column geometry and bounded scrolling | `DynamicIsland/IslandView.swift`, `DynamicIsland/IslandDropModeControl.swift` |
| Floating text translation and system-audio subtitles | `Translation/TranslationWindowController.swift`, `Translation/LiveSubtitleModel.swift` |
| Inline monitoring, picker and refresh lifecycle | `Monitor/MonitorHoverPanel.swift`, `Monitor/MonitorStore.swift` |
| Inline brightness strip, backlight hold, Extra boost (display table + EDR trigger) | `Brightness/IslandBrightnessStrip.swift`, `Brightness/ScreenBrightnessController.swift`, `Brightness/GammaBrightnessBoost.swift`, `Brightness/BrightnessHeadroomTrigger.swift` |
| Brightness keys (event tap, steps, Extra gesture) and the Settings -> Toolbox -> Display pane | `Brightness/BrightnessKeys.swift`, `Brightness/BrightnessKeyEventTap.swift`, `Brightness/ToolboxDisplayPane.swift` |
| Measured pointer targets, viewport clipping and down/up ownership | `DynamicIsland/IslandHoverHitBridge.swift`, `DynamicIsland/IslandPanel.swift` |
| Catalog search, aliases, AppKit search field and keyboard commands | `DynamicIsland/IslandHoverToolSearch.swift` |
| Drag/drop catalog, fixed Add and selected layout | `Settings/ToolboxSettingsView.swift` |
| Embedded History, Record and translation panels | `Settings/ToolboxMiniApps.swift` |
| App services and hotkey dispatch | `AppDelegate.swift` (`onToolHotkeyActivated`) |
| Feature hotkey labels and hints | `Hotkeys/HotkeysSettingsView.swift`, `HelpWindowController.swift` |
| Inline To-do and daily Calendar | `Planner/TodoHoverView.swift`, `Planner/CalendarHoverView.swift`, `Planner/CalendarConnectView.swift` |

## Tool contract

1. Give the tool a stable camelCase `HoverTool` case. `rawValue` is persisted in
   UserDefaults: do not rename or recycle an existing ID.
2. Add registry metadata. Choose `.action`, `.inlinePanel`, or `.navigate` to a
   Settings destination. Prefer an existing destination when it already fits.
3. Extend `HoverSlotRouter.effect(for:)`. For an action, add the matching
   `IslandActions` closure with a harmless preview default and a real production
   handler in `AppDelegate`. For an inline panel, also add its panel state and
   view in `IslandView`.
4. Update exhaustive switches in the live hover, Toolbox, search aliases and any
   navigation surfaces. Search results, tile clicks and feature hotkeys must
   cause the same effect. Search results must not mutate the saved layout.
5. Keep `HoverLayoutStore.columns` and the shared height calculation aligned. A
   new row must resize the AppKit panel and its hit region, not just the SwiftUI
   contents. `IslandHoverControlsLayout` centers fixed-height buttons; shortcut
   hints overlay the top edge without moving them. Keep native hit zones in sync
   with the drawer, compact pill and music at the actual `compactWidth`. Derive
   every capsule's width from that same value; never restore a fixed wide drawer.
   Preserve scroll content beyond four visible rows; do not fill or truncate saved layouts.
6. Preserve Settings as the final selected tool. A new tool belongs in the catalog;
   adding it does not authorize replacing the user's existing selections.
7. Use `HoverToolPresentation` for real mode/language/recording status, not a
   store read inside the control or an invented Enabled status for navigation.
   Monitor is `.inlinePanel` / `.openPanel(.monitor)` for every hover launcher;
   keep its dashboard picker and Back flow inside the drawer. Brightness is
   `.inlinePanel` / `.openPanel(.brightness)`, offered from the catalog and
   search only, with the capsule title Display. Its strip is shorter than the
   tools, so the band keeps the
   previous height until the pointer is over the drawer's final frame, also on
   a quick move. Settings -> Toolbox ->
   Display offers Hold brightness, Extra and Brightness keys without the island; a
   brightness key opens the strip as a glance without keyboard focus.

`scaffold-hover` creates an isolated view and checklist, not a registered feature.
The native app has no executable plugin loader. Integrate the requested source
change and rebuild it with the canonical development script.

## Checks

```bash
python3 scripts/customize.py test --filter 'HoverToolTests|HoverLayoutStoreTests|HoverSlotRouterTests|HoverHotkeyTests|IslandHoverPanelControlTests|IslandHoverToolSearchTests|IslandHoverHitBridgeTests|HoverToolPresentationTests|IslandHoverPanelHitZoneTests|MonitorDashboardTests|BrightnessHoverToolTests|ScreenBrightnessControllerTests|GammaBrightnessBoostTests|BrightnessBoostFrameTimerTests|BrightnessKeysTests'
python3 scripts/customize.py build
```

Inspect one row and multiple rows, add/reorder/remove, Settings locking, relaunch
persistence and keyboard activation of the first five positions. Verify that
scrolling preserves and reaches tool 13+, all drawer/search/inline-panel native
hit regions match the compact island width, and music uses that same width.
Cover 310-point and 312-point examples, including fractional capsule widths;
History's 300-point reservation must fit its 280-point preview plus eight-point
gap with zero drawer overhang. Check pure status updates and Monitor picker -> dashboard -> Back in the same drawer.
Open Display (Brightness) from a lower row and check that the drawer stays open while the
pointer moves up to the strip, also quickly from the third row. Fake devices and
a fake display table cover the backlight and Extra in tests, and a fake tap covers
Brightness keys; tests never write a real display table or install a real event tap.
A live Extra check needs the user's consent, because it brightens their screen.
Use offscreen checks; do not open GUI test windows over the user's work.
Search for an unpinned Output Lang, verify keyboard and pointer activation,
clear with Escape, and check that clicking outside releases text focus. Ordinary
hover must not take focus from another app. In Vocab, typing and Enter keep the
drawer open even when the pointer is hidden or leaves it. Escape releases editing
focus without saving the draft; clicking another window also releases focus.

## Diagnose hover regressions

For a lost or misplaced click, inspect the measured target and viewport in
`IslandHoverHitBridge`, rather than adding a mouse-catching overlay. Down and up
must refer to the same unchanged control; dragging out, changing context or
closing the panel cancels activation. Internal search editing transitions must
not resign the key window before the result receives its owned mouse-up.

For flat glass or missing hover feedback, read the current
[native-glass and interaction decision](../../.project-docs/decisions/2026-10-17-native-hover-glass.md).
The native path uses one adaptive Regular backdrop on an independent background
shape per
card, with foreground capsules and passive highlights. It does
not wrap the foreground in glass or add nested native glass effects.
The search field and History use transparent foreground lenses, not black
surfaces; the native search cell keeps its geometry while omitting the bezel
paint. Active visual treatment leaves focus unchanged; explicit motion respects
Reduce Motion. Record macOS, backdrop and accessibility settings with the visual
evidence. Do not show test or fixture windows over the user's work; further
checks must remain offscreen. State that offscreen output does not verify the
external-desktop compositor, and do not change accessibility settings as an
incidental fix.
