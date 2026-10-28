---
id: brightness-tool-2026-10-18
type: decision
title: Brightness is a catalog hover tool with a backlight slider and an Extra switch
summary: A short inline strip sets the island display's backlight and offers a fixed Extra EDR boost that survives automatic and external backlight changes; an explicit Whytap decrease or switch disables it, alongside existing display, thermal and boost-failure guards. Optional Brightness keys show the strip instead of the macOS indicator. Saved and default layouts are unchanged.
status: confirmed
tags: [hover, brightness, edr, gamma, battery, display, settings]
canonical_for: [brightness-tool]
verified_at: 2026-10-27
sources:
  - type: user-confirmed
    reference: On 2026-10-27 the user reported Extra turning off during ordinary work on a second Mac after an apparent one-step backlight decrease, then explicitly chose to keep Extra through automatic macOS brightness changes and switch it off only on a manual decrease. This supersedes the automatic-decrease lifetime rule of 2026-10-20.
    confirmed_at: 2026-10-27
  - type: user-confirmed
    reference: On 2026-10-21 the user requested removal of the battery indicator because it repeatedly displayed apparently random values. This supersedes the earlier battery charge and runtime requirements.
    confirmed_at: 2026-10-21
  - type: user-confirmed
    reference: On 2026-10-20 the user refined manual dimming so the first decrease with Extra on only disables Extra without changing the brightness slider. Subsequent manual adjustments lower the backlight normally.
    confirmed_at: 2026-10-20
  - type: user-confirmed
    reference: On 2026-10-20 the user requested that lowering brightness turn Extra off, and explicitly chose any decrease, including automatic brightness and idle dimming, over manual changes only. This supersedes the 2026-10-19 request to keep Extra through all backlight changes.
    confirmed_at: 2026-10-20
  - type: user-confirmed
    reference: On 2026-10-18 the user asked for a separate Brightness hover tool building on the earlier Vivid/XDR research, with a white slider continuing into a yellow extra-brightness zone, the expected runtime on battery and a plain strip opened from hover. The same day they replaced the yellow zone with a separate Extra switch.
    confirmed_at: 2026-10-18
  - type: user-confirmed
    reference: On 2026-10-19 the user reported the boost steady after the frame fix (the washed-out look they saw then came from Vivid running at the same time), then a dim moment on every ⌘Tab, even a quick tap without the switcher panel. They noted that Extra survived lowering the brightness through macOS but ended with Exodia's slider, and asked for Extra as a fixed addition to the brightness that ends only when switched off, reachable from Settings -> Toolbox as well as hover. They then asked for the brightness keys to show the hover strip instead of the macOS indicator, with two brightness-up presses at full brightness turning Extra on.
    confirmed_at: 2026-10-19
  - type: user-confirmed
    reference: Later on 2026-10-19, with installed build 1472, the user reported that Vivid looked brighter than Extra and that the brightness still blinked on every app switch, then that Vivid does not blink on ⌘Tab. They reported the drawer closing on a quick move up to the strip from the third row (waiting first worked), the strip's Extra switch drawn grey instead of blue, and asked for a smart battery estimate that follows the battery charge, the screen brightness and the average load of the last half hour or hour, recomputed on every change.
    confirmed_at: 2026-10-19
  - type: repository
    reference: Sources/Sidekey/Brightness/ScreenBrightnessController.swift
    confirmed_at: 2026-10-20
  - type: repository
    reference: Sources/Sidekey/Brightness/GammaBrightnessBoost.swift
    confirmed_at: 2026-10-20
  - type: repository
    reference: Sources/Sidekey/Brightness/BrightnessHeadroomTrigger.swift
    confirmed_at: 2026-10-20
  - type: url
    reference: https://github.com/AbsoluteMode/whytap/blob/4bc5e99899ee6562a7b8b450047148d92ba73fbf/Sources/Sidekey/Brightness/BatteryRuntime.swift (retired battery implementation)
    confirmed_at: 2026-10-20
  - type: repository
    reference: Sources/Sidekey/Brightness/IslandBrightnessStrip.swift
    confirmed_at: 2026-10-19
  - type: repository
    reference: Sources/Sidekey/Brightness/BrightnessKeys.swift
    confirmed_at: 2026-10-19
  - type: repository
    reference: Sources/Sidekey/Brightness/BrightnessKeyEventTap.swift
    confirmed_at: 2026-10-19
  - type: repository
    reference: Sources/Sidekey/Brightness/ToolboxDisplayPane.swift
    confirmed_at: 2026-10-19
  - type: repository
    reference: Sources/Sidekey/DynamicIsland/IslandView.swift
    confirmed_at: 2026-10-19
  - type: repository
    reference: Tests/SidekeyTests/Brightness/BrightnessKeysTests.swift
    confirmed_at: 2026-10-19
  - type: trace
    reference: Read-only battery probe on the developer's MacBook (macOS 27.2, on battery), nine samples over four minutes.
    confirmed_at: 2026-10-18
  - type: trace
    reference: Final local runs. Before merging main, focused hover, search, Monitor and Brightness filter 283 tests, 0 failures, and full swift test 3,015 tests, 8 skipped, 0 failures (51.123 s). After merging main f3f9174, full swift test 2,892 tests, 5 skipped, 0 failures (49.711 s), then the four Brightness suites 53 tests, 0 failures, no warnings. customize.py build exit 0 with the dev bundle signature verified both times; fourteen offscreen strip PNGs (seven states at 310 and 330 points).
    confirmed_at: 2026-10-19
  - type: trace
    reference: Live dev-build check, 2026-10-19 (MacBook Pro XDR, macOS 27.2). The user saw the screen blink with Extra on. WindowServer's display headroom hint fell from 2.67 to 1 within 0.07 s of Exodia losing key focus (18:31.588 -> 18:31.655) and 0.77 s after a keepalive frame without a focus change (19:02.354 -> 19:03.128); it rose to 2.67 0.05 s after the strip became key (18:21.946 -> 18:21.995).
    confirmed_at: 2026-10-19
  - type: trace
    reference: After the frame, title and restore fixes. Focused hover, search and Brightness filter 118 tests, 0 failures; full swift test 2,931 tests, 5 skipped, 0 failures (51.322 s); no warnings in the Brightness files. After the two fixes from Argon's review, the three Brightness suites 47 tests and full swift test 2,933 tests, 5 skipped, 0 failures (52.461 s), no warnings in the Brightness files.
    confirmed_at: 2026-10-19
  - type: trace
    reference: WindowServer, SkyLight and MenuBarAgent logs over nine app switches with Extra on (13:36-13:39, 2026-10-19). Backlight and headroom stayed unchanged (headroom 2.67, limit 1600 nits) from 13:36:32 until the dev build quit at 13:39:17, with Vivid already closed. All switches stayed on one Space; seven were ⌘Tab, four of them with the Dock's switcher panel for 0.7-2 s and three without it.
    confirmed_at: 2026-10-19
  - type: trace
    reference: After the fixed boost, the app-switch frames, Settings and Brightness keys. BrightnessKeysTests 38 and BrightnessHoverToolTests 16 tests, 0 failures; full swift test 2,977 tests, 5 skipped, 0 failures (56.562 s), no warnings in the Brightness, IslandView, AppDelegate or Settings pane files; fifteen offscreen Settings pane PNGs.
    confirmed_at: 2026-10-19
  - type: trace
    reference: Independent read-only reviews of PR #30 on 2026-10-19. Codex found the boost lost with focus, the restore target lost after a failed write and the first transparent frame; Argon (Gemini) agreed on the cause and found the stale origin within the settle window and frames requested from sleeping displays. Claims were checked against the code and by failing tests.
    confirmed_at: 2026-10-19
  - type: trace
    reference: Read-only observation of Vivid on the same MacBook Pro XDR panel, 2026-10-19, through public window, screen and Quartz reads only. Vivid keeps a 1x1 pt window at the display's top-right corner (bounds 1727,0) and a second 36x36 pt window of unknown purpose, both at layer 1000; the built-in display's transfer table (capacity 1024) was scaled linearly to 1.45 at white (0, 0.3629, 0.7257, 1.0886, 1.45) at a current EDR headroom of 2.6667 and a potential of 16. The headroom hint rose from 1.007 to 2.667 within about 0.7 s of Vivid starting (19:16:22.742 -> 23.441).
    confirmed_at: 2026-10-19
  - type: url
    reference: https://github.com/niklasr22/BrightIntosh (GPL, read for ideas only, no code copied) — a 1x1 trigger window one level above its full-screen overlay at the shielding level, presented five times a second, a brightness factor of 1 + 0.5 x min(headroom / 2.66, 1) on its list of 600-nit built-in panels (1 + 0.59 x min(headroom / 3.2, 1) on other built-in panels), suspension on screensaver, session and protected-data changes, and CGDisplayRestoreColorSyncSettings resetting every display's table.
    confirmed_at: 2026-10-19
  - type: trace
    reference: Local runs on 2026-10-19/20. Each fix was written test-first. GammaBrightnessBoostTests 25, ScreenBrightnessControllerTests 32, BrightnessBoostFrameTimerTests 9, BrightnessHoverToolTests 19, BrightnessKeysTests 44, BatteryRuntimeTests 27 and BatteryRuntimeMonitorTests 5; the Brightness, battery and Toolbox filter 177 tests, 0 failures. Four mutations of the table boost and eight of the battery estimate were each caught. After merging main 9b03696, full swift test 3,515 tests, 8 skipped, 0 failures (96.234 s). After Codex's six review findings were fixed test-first: GammaBrightnessBoostTests 34, ScreenBrightnessControllerTests 33, BatteryRuntimeTests 28, the seven suites 172 tests, 0 failures; eight mutations of the fixes each caught; after merging main 92a2aa3, full swift test 3,545 tests, 9 skipped, 0 failures (97.748 s).
    confirmed_at: 2026-10-20
  - type: url
    reference: https://developer.apple.com/videos/play/wwdc2022/10114/ (Display EDR content with Core Image, Metal, and SwiftUI)
    confirmed_at: 2026-10-19
related: [../project.md, 2026-10-17-hover-tool-search.md, 2026-10-17-native-hover-glass.md, 2026-10-28-brightness-hold.md]
---

# Brightness tool

The optional backlight lock is specified separately in
[Brightness hold](2026-10-28-brightness-hold.md). Its target and lifetime do not
change the Extra boost contract below.

## Context

The user asked for brightness control as its own hover tool, building on the
earlier Vivid/XDR research: a white slider, extra (XDR) brightness and the
expected runtime on battery, opened as a plain strip from hover. They then
replaced the yellow Extra continuation of the slider with a separate switch.
After the first live checks they asked for Extra as a fixed boost that only
the switch ends, for the switch in Settings as well, and for the Mac's
brightness keys to show the strip instead of the macOS indicator. With build
1472 installed they found Vivid brighter than Extra and Extra blinking on
every app switch, which Vivid does not, the drawer closing on a quick move
from the third row and the switch drawn grey. They asked for a battery time
that follows the charge, the brightness and the last half hour's average load
and is recomputed on every change.
macOS has no public backlight API for Apple displays, and brightness above the
SDR maximum exists only as EDR headroom that apps fill with their own content.

## Decision

**Tool.** `HoverTool.brightness` is an `.inlinePanel` resolved to
`.openPanel(.brightness)`. It is offered from the Toolbox catalog and search
(brightness, display, vivid, xdr, plus the Russian aliases);
`HoverLayoutStore.defaultSlots` and saved layouts are unchanged. Its capsule
title is Display. Hover capsules draw no status captions; its VoiceOver label
adds NN% or Extra, and nothing for an unreadable display.

**Strip.** 68 points: Back, a white Control Center style capsule slider with the
sun at its start and the Extra switch. A status line appears only for an
orange notice or unavailable brightness. Healthy states have a single
centered control row. The band remains 76 points, 126 with music, preserving
room for notices and the existing hover hit zone. The mode takes keyboard
focus like Monitor, so the slider and switch receive clicks. The switch is
`MacSwitch` at its compact 30x18-point size, in the accent color when on even
though the island's window is never the active app's key window. Opened from
a lower tile, the band keeps the previous height as transparent hover space
under the top-aligned drawer until the pointer is over the drawer's final
frame (`IslandView.releasesHeldHoverZone`), including while the drawer is
still shrinking to it.

**Backlight.** `DisplayServicesGetBrightness` and `DisplayServicesSetBrightness`
are resolved with `dlopen` from the private DisplayServices framework, for the
island display chosen by `IslandScreenResolver`. An unreadable display gets a
disabled slider, a one-line explanation and no switch. Opening the strip only
reads. While it is visible or Extra is on the controller polls every 0.5 seconds; after a
write, readings from that display are ignored for 0.75 seconds, because the
panel can still report the earlier level, so key presses in a row step from
the written level. A pinned capsule reads the level once when hover opens.

**Extra.** Offered when `maximumPotentialExtendedDynamicRangeColorComponentValue`
exceeds 1.01. Turning it on never writes the backlight. As Vivid does, Extra
scales the display's transfer table into the EDR headroom that a trigger keeps
raised; the display applies the table after WindowServer has composited the
desktop.

`BrightnessHeadroomTrigger` is a click-through, non-activating 1x1-point panel
in the display's top-right corner, where a built-in display's rounded corner
hides it, at `CGShieldingWindowLevel` on all Spaces and over full-screen apps,
with `sharingType = .none`. Its `rgba16Float` extended-linear sRGB Metal layer
wants EDR content and clears to 2.0. The panel becomes visible after its first
rendered frame; a failed frame or four missed drawables in a row end Extra.
`BrightnessBoostFrameTimer` presents a frame every 0.2 seconds while the
trigger exists, with the strip open or closed, whenever its window is visible
(and until the first frame succeeds), and then lets the boost check the table,
also while the window is not visible. Nothing happens between
`screensDidSleep` and `screensDidWake`, `willSleep` and `didWake`, or
`sessionDidResignActive` and `sessionDidBecomeActive`; each pause ends only
with its own notification.

`GammaBrightnessBoost` writes nothing until the current EDR headroom exceeds
1.05; if it does not within 5 seconds of frames, Extra ends with the Extra
notice. It
then reads the display's own table (`CGGetDisplayTransferByTable`, up to 256
entries) and writes it scaled by `min(1.45, 1.055 x headroom^(1/2.4) - 0.055)`,
the headroom in the sRGB encoding the table holds. From a headroom of about
2.35 the factor stays at 1.45, about 2.35 times SDR light at white. While the
headroom first rises, each step is followed at once. Any other change is
written once the table has differed from it for 1.5 seconds; without headroom
the display gets exactly its own table while Extra stays on (a factor within
0.005 of none counts as none), and returning headroom rises at once again.
Frames come every 0.2 seconds, so a gap of more than a second between two
means they paused (sleep, another session): it restarts the 5-second wait and
the 1.5-second hold instead of counting toward them. After every frame the
boost compares each channel's white with the boosted table it wrote, within
0.003 because Quartz may resample a table. Without a boost there is nothing
to compare: the display's current neutral table, a new profile's included,
simply becomes the one boosted when the headroom returns. A table that already ends above 1.01
belongs to another booster such as Vivid: at the start or later, Extra ends
with "Another app is adjusting this display." and leaves that table alone. A
table back at SDR white is a reset, such as a display reconfiguration or a
profile change: it becomes the display's own table and is boosted again, and
a third reset within 10 seconds also counts as another app. An unreadable
table or a refused write ends Extra with the Extra notice. While another
user's session is active the display has its own table, and Extra engages
again when the session returns. Ending Extra, or another session, writes the
display's own table back before the trigger closes, but only while the display
still has the boosted table: one written since the last frame by macOS or
another app stays, or restores every display's ColorSync table if
Quartz refuses that write; Quartz also gives the displays their own tables
back when the process exits.

**Lifetime.** Extra is a fixed boost on top of the current backlight. Automatic
brightness, battery dimming, idle dimming and other external backlight changes
keep it enabled. Readback provides the level, not the user's intent, so native
macOS keys and controls also keep Extra when Brightness keys interception is off.
The first manual Whytap slider decrease, accessibility decrement or intercepted
brightness-down press only ends Extra without writing the backlight or changing
the slider. The whole first drag or held key press is consumed; the next
adjustment lowers the backlight normally. Increasing or leaving the level
unchanged keeps Extra on. Native macOS changes are detected every 0.5 seconds while Extra is on, even
with the strip closed. A write's 0.75-second settle window and Float round-off
(up to 0.000001) are ignored. Enabling Extra reads a fresh baseline, so a
decrease made before enabling it does not end it on the next poll. Increasing
brightness never turns Extra back on. Closing the strip, sleep, a session
switch, a lower backlight read on wake and loss of current headroom alone do not
end it. It also ends when the user switches it off in the strip or
in Settings, and on a serious
or critical thermal state (the cooling notice, which also blocks turning it
on), a display change, a display that no longer offers EDR or cannot be read,
another app's table (the other-app notice), a boost failure (the Extra notice)
and app quit. Ending it gives the display its own table back and leaves the
backlight where it is. Extra is never saved and never comes back by itself
after relaunch. Each notice fits one line of a 310-point island.

**Settings.** Settings -> Toolbox -> Display (`ToolboxDisplayPane`) is a card
with the Extra switch, when the island display offers it, and the Brightness
keys switch, without a slider. It reads the display when it appears and then
follows the controller's display notifications; it never polls. A display
without Extra shows one grey line instead of its row. While macOS refuses the
keys, their row's description reads "Needs Accessibility. Allow it in
Permissions.", and showing the pane retries the tap. Every state fits the
188-point area under the tool header.

**Brightness keys.** Off by default; the switch is in Settings -> Toolbox ->
Display and is saved. While it is on, a session event tap (head insert, not
listen-only) on its own thread receives only system-defined events and takes
the brightness key presses (aux control subtype 8, key types 2 and 3) from
macOS, so the system indicator does not appear. A press moves the island
display's backlight to the next sixteenth of the range, or sixty-fourth with
Option-Shift, at least a quarter step away. A brightness-up press at the
maximum followed by another within 1.5 seconds turns Extra on; the press that
reaches the maximum does not count, and repeats from holding the key neither
count nor cancel. The window uses the time the tap saw each press, not the
time a busy main thread handled it. A brightness-down step ends Extra. Each
press shows the strip as a glance: it closes after 2 seconds instead of the 4
of a tool hotkey and leaves keyboard focus with the user's app. A glance
replaces the tools or the strip itself; it never opens over another panel
under the pointer or a search being typed, which leave the level changed
without it. Under the pointer the strip opens as from its tile, with focus,
and a pointer that reaches a glance from below holds the drawer and takes
focus. While a meeting suggestion, a recording or the agent blocks expansion,
the level changes without the strip. The keys stay with macOS while hover
widgets are hidden, while the island display is not adjustable, and with
Command, Control, Option or Shift other than Option-Shift; Fn and Caps Lock do
not matter. A press belongs to whoever received its first event, Whytap or
macOS, and its repeats and release follow it; a press Whytap did not see
begin, such as one held while the tap is installed, stays with macOS. The
presses outlive each tap, so one held while the hotkeys are rebuilt keeps its
owner. After more than 0.1 seconds without a tap, or once macOS disabled it, a
press may have ended and another begun unseen, so the presses in progress
finish with macOS. Turning the setting off removes the tap at once; the rest
of a held press goes to macOS. The tap is installed again with the hotkeys
(wake, an Accessibility change) and given up when macOS disables it a fourth
time in a row without an event, or at once without Accessibility. Drop's
permission repair starts the keys again every second while Drop is not
installed; the first key handler stays, so the gesture keeps its first press.

**Battery removal (2026-10-21).** The user rejected the indicator because its
values appeared random. Remove the whole charge/runtime line, its catalog
copy and search aliases, the estimator, IOKit battery reader, background
sampling and display-load helpers. Keep brightness controls, Extra, notices,
brightness keys and saved layouts. There is no replacement battery indicator
or retained battery history. This supersedes the earlier battery requirements
and the battery-specific rationale and checks below.

**Retired battery model (historical).** IOKit power sources gave the percentage, power state and macOS's
time to empty. AppleSmartBattery gives the remaining charge
(`AppleRawCurrentCapacity` x `Voltage`) and the load accumulators in
`PowerTelemetryData`. `BatteryRuntimeMonitor` reads them once a minute from
launch on a Mac with a battery, and every 5 seconds while the strip is
visible. A sample is the system load that the accumulators average
between two readings 30 to 180 seconds apart, with the built-in display's
light averaged over the same span (`ScreenBrightnessScale.displayLoad`): the
level squared, times the light of the table factor Extra currently applies to
that display (2.35 at 1.45, 1 while it waits for headroom or has none), and 0
with the lid closed. A factor that changes on its own, with the headroom, is
counted at the next reading: 5 seconds with the strip open, a minute without. A longer gap such as sleep, a counter reset or a clock change starts
a new span without a sample; an empty history starts from the latest instant
load, and loads under 0.5 W are dropped. The estimate uses the last 30
minutes: the load's least-squares slope over the light, drawn toward a prior
of 5 W per unit of light with the weight of one unit of spread and bounded to
1-15 W and so that the display takes at most 80 % of the mean load at the
mean light, moves the display's
share from the history's mean light to the current one, for a load of at
least 0.5 W. While the strip is visible, every level or Extra change it sees
recomputes the line at once without reading the battery; with the strip
closed, a change enters the light average at the next reading. On battery
macOS's estimate comes first while fewer than five samples exist or the
history gives no time, adjusted by the same slope from the light of the
minute before its reading to the current one: macOS follows the battery's
average current, about the last minute (an assumption), so a refreshed
estimate already has an older change of brightness; otherwise the history gives the time. On power the
history shows "N h if unplugged", otherwise "On power" or "Charging". Times
are at most 24 hours and round to 5 minutes under an hour, then to 10.

The history stays in memory. Battery readings, their half hour of samples and
brightness key events are never written to disk, logged or sent; only the
Brightness keys switch is saved. The strip and Extra need no permission;
Brightness keys need the Accessibility permission the hotkeys use.

## Why

- The separate switch is the user's correction: one explicit on/off instead of
  a slider zone whose meaning changes past the end.
- The fixed boost is the user's correction of 2026-10-19: Extra survived the
  Mac's own keys but ended with the strip's slider. Without a level to restore,
  there is no restore that can fail and no write of a backlight level the user
  did not choose. On 2026-10-20 the user changed the lifetime rule to end Extra
  on any decrease. On 2026-10-27 the user replaced that rule after unwanted
  shutdowns on the second Mac: automatic and other external changes now keep
  Extra, while Whytap's explicit slider and intercepted keys still end it.
  Polling follows the current level and display support with the strip closed;
  no new event tap, permission or write to the backlight is needed.
- Catalog-only follows the Toolbox contract: a new tool does not replace the
  user's selections or change the default layout.
- The table follows the user's report that Vivid, which scales the table, does
  not blink on ⌘Tab. The display applies the table after WindowServer
  composites the desktop, so recompositing on an app switch cannot dim it. The
  former multiply overlay dimmed on every switch, with or without the switcher
  panel, while WindowServer kept the headroom and the backlight through nine
  switches (sources), and build 1472 still dimmed with an app-switch burst of
  60-hertz overlay frames. That recompositing caused the dim moment is the
  leading explanation, not yet confirmed on the panel.
- 1.45 is the white of Vivid's table on the same panel at a headroom of 2.67
  (sources). In linear light it is about 2.35 times SDR white, where the
  multiply overlay gave 2.0, which fits the user's report that Vivid looked
  brighter. Below a headroom of about 2.35 the factor is the headroom itself
  in the table's sRGB encoding, so the boosted white never asks for more than
  the panel can show.
- Nothing is written before the headroom exceeds 1.05: a table above SDR white
  without headroom clips the bright end. Vivid's headroom rose within about
  0.7 seconds; 5 seconds leaves room for a slow start.
- The first rise and a return are followed at once so Extra comes up with the
  headroom. Other changes wait 1.5 seconds, because stepping the table down and back up for a brief
  dip would itself blink; without headroom the display's own table avoids a
  clipped white.
- Another app's table is left alone: scaling Vivid's table again would clip,
  and writing ours over it would fight the other app frame by frame. A table
  back at SDR white is macOS resetting it, as a reconfiguration or a profile
  change does; three resets within 10 seconds mean another app keeps writing it.
- Only white is compared, because Quartz may resample a table and an exact
  comparison of the curve could take its own resampling for another app. A
  profile that keeps SDR white and changes the curve below it is therefore
  invisible while boosting; without a boost the current table is taken as the
  display's own, so a profile change during a headroom loss is not undone.
  Codex's review of #63 found the old curve coming back.
- A table goes back only while the display still has the boosted one: another
  booster or macOS may write between two frames, and giving the older table
  back would undo it (Codex, #63).
- Time without frames is not the headroom's: only the trigger's frames raise
  it, so a display that slept past the 5-second wait would otherwise end Extra
  at wake, and a dip that began before sleep would step the table down at once
  (Codex, #63).
- The table belongs to the display, not to the session, so another user's
  session gets the display's own table.
- The trigger is 1x1 point in the top-right corner, as Vivid places its own,
  where a built-in display's rounded corner hides it. Any white above SDR
  engages the panel's whole headroom: the former full-screen layer drew 2.0
  and WindowServer still raised the headroom to the panel's 2.67.
- Without focus, WindowServer keeps a layer's EDR headroom only about 0.8
  seconds after its last frame. Redrawing on change plus a 2-second keepalive,
  and only while the strip was open, made the boost blink: the headroom hint
  fell to 1 when the app lost focus and between keepalive frames. Five frames a
  second, BrightIntosh's rate for its trigger, fit three frames in that hold.
  Frames pause while the window is not visible, while the displays or the Mac
  sleep and during another user's session: a sleeping display does not consume
  them, and waiting for a drawable would block the main thread for up to a
  second. The notifications make the pause independent of when the occlusion
  state changes. The table is still checked while the window is not visible,
  because a hidden trigger loses the headroom too.
- Display replaces the Brightness capsule title, which wrapped to two lines in
  the 43-point text column of a 310-point island (the user's screenshot).
- `MacSwitch` replaces the system switch, which draws its on state grey in a
  window that is not the active app's key window, and the island never is
  (the user's screenshot).
- The height hold keeps the drawer open: the strip is much shorter than the
  grid, and a pointer left on a lower tile would otherwise fall outside it.
  The hold ends only over the drawer's final frame because a quick move from
  the third row entered the drawer while it was still shrinking, ended the
  hold there and closed the drawer under the pointer (the user's report:
  waiting first worked).
- Extra costs power and heat, so heat ends it and nothing turns it on without
  the user.
- Brightness keys are off by default because they take keys from macOS and
  need Accessibility.
- A press follows its first event so macOS never receives half of one Whytap
  took and Whytap never takes the rest of one macOS began. Codex found both
  halves broken at a tap boundary (round 3).
- The presses survive 0.1 seconds without a tap because the hotkeys' rebuild
  installs the next tap within milliseconds. A longer gap or a disabled tap
  can hide a release and a new press, and the old owner would then take a
  press macOS began, for example one with Option.
- Turning Brightness keys off does not wait for a held key: the switch gives
  the keys back to macOS.
- The gesture is timed at the tap because a busy main thread hands presses
  over late and together; two presses 2 seconds apart then counted as one
  gesture.
- Combinations stay with macOS because they are its own shortcuts (Option
  opens Displays settings); Option-Shift is the Mac's fine step.
- A glance takes no keyboard focus so a key press while typing leaves the text
  field focused, and it does not replace a panel the user is using.
- The keys have no Help window row, `HotkeyHintView` or `HotkeyConfiguration`
  entry: they are the Mac's own keys, not a Whytap hotkey.
- The Settings pane has no description above its card so every state fits the
  Toolbox area without the window changing height.
- The backlight is polled while the strip is visible or Extra is on, so an
  outside change updates its level with the strip closed while Extra stays on. Otherwise there is no
  backlight timer. With Extra on, the trigger presents five frames a second
  with a table read after each. Battery sampling was removed on 2026-10-21.
- Historical battery rationale (superseded on 2026-10-21): the battery line follows the user's request of 2026-10-19: the charge, the
  brightness and the average load of the last half hour, recomputed on every
  change. The display is the one large load the strip controls, so its share
  moves with the slider and Extra.
- The display's watts per unit of light are learnt from the history because
  panels and workloads differ. While the brightness has barely changed the
  history shows no slope, so an assumed 5 W prior carries the estimate; the
  bounds keep one noisy half hour from giving most of the load to the display.
- The light is the level squared, an assumption about how DisplayServices'
  level maps to backlight power rather than a measurement; 2.35 for Extra is
  exact at white only and overstates darker content.
- macOS's estimate comes first until five samples exist, about five minutes
  after launch, because one or two samples swing with a single reading.
  Adjusting it for the brightness keeps the line moving with the slider
  meanwhile.
- A span longer than 180 seconds, such as sleep, adds no sample because the
  light and the load during it are unknown. The display's own sleep is not
  detected: a display sleeps with an idle Mac, and counting its light as 0
  would credit the idle Mac's lower load to the display.
- The history stays in memory, so nothing about usage is written to disk;
  after a relaunch macOS's estimate covers the first minutes.
- The settle is per display, so another display's reading stays current after
  a switch.
- `powerplug.fill` is used because `powerplug.portrait.fill` needs macOS 15.

## What was tested

The 2026-10-20 decrease rule passed 183 focused Brightness and battery tests,
with fake devices only. New coverage includes slider and normal/fine key
decreases, native readback with the strip closed, actual background timer
delivery, no automatic re-enable, a fresh baseline on enabling, delayed
write readback, Float round-off and failed writes. The app was not launched
and real display brightness was not changed during this validation.

- `ScreenBrightnessControllerTests` (32) with fake devices: read-only opening,
  per-display settle, Extra starting the boost without a backlight write,
  switching it off leaving the backlight as it is, the slider and outside
  changes keeping it at any level, sleep and a session switch keeping it, a
  display change ending it and reading the new display at once, a failed or
  unavailable boost ending it with the Extra notice, another app's table
  ending it with its own notice, a late end from a closed boost, an
  unreadable display that is never written and has no switch, thermal
  pressure blocking Extra and pausing only an active one, and the built-in
  display's light for the battery (the level squared, Extra only on that
  display, 0 without one, none when unreadable, the slider's level while the
  reading settles). The six fixed-boost tests failed first against the
  earlier model, for example `["write 1 1.0", "overlay 1"]` instead of
  `["overlay 1"]`; six tests of the earlier restore model were removed with it.
- `GammaBrightnessBoostTests` (25) with a fake `DisplayGammaAccess`, never a
  real display: no write before the headroom exceeds 1.05 and the Extra notice
  after 5 seconds without it, the scaled table once engaged and its first
  rise followed at once, the factor matching Vivid's 1.45 and never exceeding the
  headroom, a lower headroom followed only once it holds, a brief dip keeping
  the table, lost headroom giving the table back until it returns, another
  booster's table never stacked at the start and left alone later, a reset
  boosted again from the new table, resets far apart each boosted and a third
  within 10 seconds ending as another app, unreadable tables and refused
  writes (the table given back, ColorSync when that write fails too), ends
  reported once, close in every phase, and another session suspending and
  resuming the boost.
- `BrightnessBoostFrameTimerTests` (9), written before the timer existed:
  frames arrive without calls from the strip, none while the trigger cannot
  present (the table is still checked), while the displays or the Mac sleep
  or during another session, and again only after every pause has ended; none
  after stop or release; three frames fit in the measured 0.77-second hold.
  The display-sleep test failed first (the timer had no sleep state). The
  app-switch burst and its four tests were removed with the overlay.
- `BrightnessKeysTests` (44), written before the keys existed (the first run
  failed with 65 assertion failures): press and release parsing, other system
  keys left alone, Option-Shift and the other modifiers, sixteenth and fine
  steps to the next mark and at both ends, the two-press gesture (the press
  reaching the maximum, holding, other presses, the window), a press kept or
  left whole across interception changes, stray releases, the two keys apart,
  steps from the last written level or a level changed elsewhere, Extra on the
  second press, brightness down ending it (updated 2026-10-20), no headroom, the setting (off by
  default, remembered, the tap kept on a second start, removed when off, keys
  left to macOS while hover is hidden or the display is not adjustable, a
  refused tap retried on start and only a refused one when Settings opens, a
  tap macOS stops, quit keeping the setting) and the glance (no focus, which
  panels it replaces, 2 seconds, the pointer holding it from below, which
  failed first). Seven mutations of the parsing, filter, handler and setting
  were each caught.
- `BatteryRuntimeTests` (27) and `BatteryRuntimeMonitorTests` (5) with recorded
  snapshots, never the real battery or display: macOS's estimate first on
  battery and with few samples, adjusted for a brightness change and kept as
  is without watt-hours; the history's time without macOS's estimate and on
  power; the accumulators averaged between updates, unchanged accumulators and
  close readings adding no sample, a counter reset, a gap such as sleep, the
  half-hour window, an empty history starting from the latest load, tiny
  loads, the display's light averaged over each span and an unknown light
  keeping the last known one; the display's share learnt from brightness
  changes and kept plausible, a lower brightness giving more time and Extra
  taking time; clamps, rounding and symbols available on macOS 14; and the
  monitor publishing only changes, recomputing on a display change without
  reading the battery, recording from launch without a strip and recording
  nothing without a battery.
- `BrightnessHoverToolTests` (19): catalog-only registration, search aliases, a
  capsule title that fits one line at 310 points (it failed with Brightness),
  capsule status, band heights and the hold released only over the drawer's
  final frame, key focus, slider mapping, every text and notice at 310 points,
  the switch in the accent color only when on in an inactive window, the time
  left following the slider, the real strip in an unordered offscreen window
  at 310 and 330 points in seven states, and polling only while it is shown.
  This test caught a false pass: with `sizingOptions = []` the hosting view
  reports a zero `fittingSize`, so the first height check measured nothing. It
  now compares the ideal height exactly (68 points, 44 without a status line).
  The Settings pane reads the display without polling, retries a refused tap
  when shown (failed first) and fits 188 points in five display states with
  each of three key states; with a description above the card and a separate
  orange line it measured 215.5 to 285.5 points and failed 11 assertions.
- Fourteen offscreen strip PNGs and fifteen Settings pane PNGs were inspected:
  text fits, nothing is truncated and the unavailable state has no switch.
- Battery probe: the first sample read 75 %, 62.6 Wh and a 20.8 W load, and
  macOS estimated 123 minutes ("75% · 2 h left"; pmset "2:03 remaining"). Over
  four minutes the accumulator estimate read 178, 161, 149, 153 and 162 minutes
  while macOS read 133, 149, 142, 162 and 172 minutes.
- Before merging main: the focused hover, search, Monitor and Brightness filter
  passed 283 tests with 0 failures; the full `swift test` executed 3,015 tests,
  8 skipped, 0 failures (51.123 s). After merging main f3f9174, which deleted
  25 test files since the base: 2,892 tests, 5 skipped, 0 failures (49.711 s),
  then the four Brightness suites passed 53 tests with 0 failures and no
  warnings. `customize.py build` built the dev bundle and its signature
  verified both times.
- Live dev build on 2026-10-19: the user reported blinking with Extra on.
  WindowServer and SkyLight logs tied every drop of the headroom hint to
  Exodia losing key focus or to a gap after the last frame (sources). After the
  fixes the focused filter passed 118 tests and the full `swift test` 2,931
  tests, 5 skipped, 0 failures (51.322 s); after Argon's two fixes, 2,933
  tests, 5 skipped, 0 failures (52.461 s). After the fixed boost, the
  app-switch frames, Settings and Brightness keys: 2,977 tests, 5 skipped, 0
  failures (56.562 s).
- After merging main 6670612 (Projects removed, Drop's permission repair): a
  test that starts the keys between the two presses at the top failed first
  (Extra stayed off), then the Brightness, battery and hover filter passed 189
  tests and the full `swift test` 3,044 tests, 5 skipped, 0 failures
  (60.299 s).
- After merging main 983e613 (Notify: a new hover tool and panel, quit and
  privacy changes), keeping both sides: the full `swift test` 3,061 tests,
  6 skipped, 0 failures (68.987 s).
- Codex review round 3 (static, at 539689e) reported four defects in press
  ownership and timing. Three were reproduced by tests that failed first: a
  repeat of a press the tap did not see begin was taken (3 assertions), the
  presses in progress kept their owner after a longer gap and after macOS
  disabled the tap (4 assertions), and two presses 2 seconds apart handed
  over together turned Extra on. The fourth, stopping the tap during a press,
  is now covered for the rebuild: a press held through a 50-millisecond gap
  keeps its owner (this test guards the gap and passed before the change).
  The presses moved from each tap session to the tap object; the tap itself
  has no unit test because tests install no real tap. Turning the setting off
  during a press still gives its rest to macOS, by design. The Brightness keys
  and hover filter passed 60 tests (44 + 16) and the full `swift test` 3,066
  tests, 6 skipped, 0 failures (69.548 s).
- Table boost, hover release, switch and battery model (2026-10-19/20), each
  written test-first. The gamma, frame, hover-release and battery tests first
  failed to build, because the code they call did not exist yet; the switch
  test failed on the grey on state. The Brightness, battery and Toolbox filter
  then passed 177 tests with 0 failures. Four mutations of the table boost
  were each caught by 6 tests with 7 failures: stacking another booster's
  table, following every headroom change at once, checking the table only
  while a frame can be presented and reporting every end as unavailable.
  Eight mutations of the battery model were each caught by 1 to 5 tests: no
  recompute from the strip, Extra on any display counting for the built-in
  one, no settle for the light, no five-sample minimum, no cap on the
  display's share, no light averaged over a span, macOS's estimate not
  adjusted for the light and no gap check. After the table boost, before the
  battery model, the full `swift test` executed 3,446 tests, 7 skipped, with 3
  failures, all in `PackagingRebrandTests`, whose child-process pipe main
  fixed in #57; that suite then passed 17 tests with 0 failures on its own. After merging
  main 9b03696, the full `swift test` on the merge executed 3,515 tests,
  8 skipped, 0 failures (96.234 s), with no build warnings in the Brightness
  files, `IslandView` or `MacSwitch`.
- Codex's read-only review of #63 (2026-10-20) reported six findings, five
  medium and one low, all confirmed by reading the code and fixed test-first:
  close and another session overwrote a table written since the last frame;
  a curve change behind an unchanged white came back after a headroom loss;
  time without frames counted toward the 5-second wait and the 1.5-second
  hold; a refreshed macOS estimate was adjusted again for an older brightness
  (549 minutes instead of 384); the battery light counted Extra's full 2.35
  while the display had its own table; and the privacy note left out the
  background backlight reads. The nine new engine and battery tests and the
  load test first failed for those reasons. Eight mutations of the fixes (no
  factor guard or no table check when giving back, no snap to the display's
  own table, no pause gap, no adoption of the unboosted table, an applied
  factor that ignores the phase, the estimate's light from the history and a
  load that ignores the applied factor) were each caught by 1 to 3 tests.
  The seven Brightness and battery suites then passed 172 tests with 0
  failures, and after merging main 92a2aa3 the full `swift test` executed
  3,545 tests, 9 skipped, 0 failures (97.748 s), with no build warnings in the
  Brightness files.

## Rejected alternatives

- A yellow Extra continuation of the slider: replaced by the user on 2026-10-18.
- Writing the backlight maximum when Extra turns on and restoring the earlier
  level when it ends (the first design): replaced by the user's fixed boost
  on 2026-10-19. Ending it on a decrease was requested again on 2026-10-20.
- Ending Extra on sleep or a session switch alone (the first design): frames
  pause instead; a lower backlight read on wake also keeps Extra.
- Ending Extra on every external backlight decrease (2026-10-20): superseded
  by the user's manual-only choice on 2026-10-27 because automatic dimming
  unexpectedly switched Extra off during ordinary work.
- Brightness in the default slots (an earlier draft): it would change new
  installations' layout; the catalog and search cover discovery.
- A full-screen multiply overlay (the Extra of builds up to 1472): WindowServer
  composites it with the desktop, the user saw it dim on every app switch, and
  it reached 2.0 times SDR white against Vivid's 2.35.
- An app-switch burst of a frame at once and 15 more at 1/60 second: build 1472
  had it and still dimmed on every ⌘Tab.
- A scaled table without an EDR trigger: without headroom a table above SDR
  white clips instead of brightening.
- Scaling another app's table, or writing ours over it: Vivid's table already
  ends at 1.45, so ours would clip it or fight it frame by frame.
- Following every headroom change at once: a brief dip would step the table
  down and back up, itself a blink.
- A full-screen trigger or drawable: one pixel engages the whole headroom.
- One global settle after writes: it would hide another display's level.
- Resuming Extra after relaunch: the screen would brighten unasked.
- macOS's estimate always first on battery, with an EMA (weight 0.5) of the
  per-update load as the fallback (the earlier battery model): it followed
  neither the brightness nor the last half hour, which the user asked for.
- A fixed display wattage instead of a learnt one: panels and brightness curves
  differ; the prior covers only the start.
- Keeping the battery history across launches: it would write usage to disk,
  and macOS's estimate covers the first minutes.
- Counting a sleeping display as dark: a display sleeps with an idle Mac, so
  the idle load would be credited to the display.
- Drawing only while the strip is open: the boost blinked once the app lost focus.
- `preferredDynamicRange = .high` with `contentsHeadroom` for the overlay
  (Codex's proposal): the overlay itself was replaced, and the change would not
  explain the drop 0.77 seconds after a frame without a focus change.
- Ending Extra on HDR suppression notifications: Extra would end whenever
  another app is in front, the opposite of the feature.
- Two frames a second (Argon's proposal): 0.5 seconds leaves 0.27 seconds under
  the measured 0.77-second hold, so one late main-thread tick would blink again.
- Skipping frames while a command buffer is in flight (Argon's proposal): GPU
  completion does not return the drawable, which the compositor keeps until it
  shows a newer frame, so it would not prevent the wait on a sleeping display.
- A listen-only tap or an `NSEvent` global monitor for the keys: neither can
  keep the macOS indicator from showing.
- Taking brightness key combinations with modifiers: they are macOS's own.
- A glance with keyboard focus, or over any open panel: a key press would take
  focus from typing or replace the panel in use.
- A separate orange line for refused keys in Settings: the pane no longer fit
  its 188 points.

## Verification boundary

Checked live on 2026-10-19 in the dev build, not the installed app: the first
Extra wrote the backlight maximum on the user's XDR panel and raised the
headroom hint to 2.67 (about 1600 nits), then blinked as described above.
After five frames a second the user reported the boost steady, apart from a
dim moment on every ⌘Tab, which installed build 1472 still showed. Not
verified: real pointer movement and the height hold, the power and heat of
Extra, whether ScreenCaptureKit honours `sharingType = .none` on current
macOS, and the on-power line with a charger connected. macOS's own estimate
moves from minute to minute.

Pending the user's live check in the next build, with Vivid off: Extra through
the table on ⌘Tab, a quick tap and with the switcher panel; Extra coming up
without a step; the boost at a low backlight and through sleep, including
whether macOS resets the table three times within 10 seconds after wake,
which would end Extra as another app; Night Shift, True Tone and f.lux with
Extra on; whether the 1x1 trigger shows in the square corner of an external
display; the quick move from the third row; the blue switch; and the time left
moving with the slider and Extra. Still pending from the earlier round: Extra
from Settings and a click on either Settings switch (offscreen tests render
the switches but do not click them), the Brightness keys (no macOS indicator,
the glance, two presses at the maximum, Option-Shift steps and the tap after
wake), a slider drag that drifts below the strip (Argon expects the drawer to
close mid-drag) and the Display capsule on one line. The battery model rests
on assumptions: the level squared as the display's light, the 5 W prior and
2.35 for Extra, exact at white only; a change made outside the strip enters
the light average at the next minute's reading. The 2026-10-20 lifetime
correction is pending a live check: first lower the slider or use an intercepted
brightness-down press with Extra on; Extra should turn off while the whole
drag or held press leaves the slider unchanged. A second action lowers it.
The 2026-10-27 lifetime correction supersedes the external-change checks:
native macOS brightness changes with the strip closed, automatic brightness,
battery dimming and idle dimming should now keep Extra enabled. Sleep or a
session switch and a lower reading on wake should also keep it. The next
explicit Whytap slider decrement or intercepted brightness-down press should
still consume Extra before lowering the current backlight. A live Extra check brightens the
user's screen and needs their consent.

2026-10-19 · [AbsoluteMode/exodia#30](https://github.com/AbsoluteMode/exodia/pull/30), branch `claude/brightness-tool-battery-587fda`.
2026-10-20 · table boost, hover release, switch and battery model: [AbsoluteMode/whytap#63](https://github.com/AbsoluteMode/whytap/pull/63), branch `claude/display-extra-gamma-587fda`.
