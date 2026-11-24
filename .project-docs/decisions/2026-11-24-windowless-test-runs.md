---
id: windowless-test-runs-2026-11-24
type: decision
title: Test runs put no window on the screen and never take focus
summary: A guard installed when the test bundle loads keeps every window order-in away from the window server while the code under test still sees its window as shown, does not perform app activation, fails a test that opens modal UI, a menu or another app, and after every test fails one that left a window in the window server's list.
status: confirmed
tags: [tests, windows, focus, appkit, guard]
canonical_for: [test-run-windows]
verified_at: 2026-11-24
sources:
  - type: user-confirmed
    reference: On 2026-11-24 the maintainer, working while the builder and feature sessions ran the suite, got Whytap Settings windows titled "xctest Settings" over his work (three at once in the screenshot, Hotkeys, Permissions and Meetings) and asked that nothing pop up during tests.
    confirmed_at: 2026-11-24
  - type: repository
    reference: Tests/SidekeyTests/Support/OnScreenWindowGuard.swift
    confirmed_at: 2026-11-24
  - type: repository
    reference: Tests/SidekeyTests/Support/OnScreenWindowGuardTests.swift
    confirmed_at: 2026-11-24
  - type: repository
    reference: Tests/SidekeyTestBootstrap/SidekeyTestBootstrap.m
    confirmed_at: 2026-11-24
related: [2026-11-23-silent-test-runs.md, ../processes/shared-app-development.md]
---

# Windowless test runs

## Context

The full suite runs many times a day on the maintainer's Mac (the builder
before every install and every feature session). Tests of window controllers
call the app's real `show()`, which ends in `makeKeyAndOrderFront` or
`orderFrontRegardless`. The Settings window is at status-bar level on every
Space, so it appeared over whatever the maintainer was doing, and tests that
did not close it left several on screen until the test process ended.

Measured on 2026-11-24, main at `b46ecbcf`, with the guard recording every
request (5,691 tests): 12 tests asked for 17 windows and 9 app activations.

| Tests | Window |
| --- | --- |
| `SettingsWindowControllerTests` (6 tests, 7 windows) | Whytap Settings, with `NSApp.activate` each time |
| `MeetingsWindowControllerTests` (2) | Meetings, with `NSApp.activate` |
| `SubtitleOverlayCloseTests` (4) | the Translate panel and a bare panel, placed 20,000 pt off screen |
| `ScreenshotHoverHintTests` (1 test, 3 windows) | the Shot hover-hint panel |
| `ToolboxTileInteractionTests.test_click_selects` (1) | a borderless window at zero opacity, 30,000 pt off screen |

No test reached `runModal`, an alert or panel sheet, `NSOpenPanel`, a menu
pop-up, `NSWorkspace.open` or `NSRunningApplication.activate`; onboarding,
the island, History, Case and Monitor tests already render off screen (their
fixtures assert `window.isVisible == false`).

Keyboard and mouse, read from the call paths on the same day (not measured at
run time): no test reaches `CGEvent.tapCreate` or `CGEvent.post`; tests inject
fake taps and posters. About thirteen `AgentControllerTests` and
`AgentControllerStreamingTests` open the answer panel with the default
`closeHotkeyFactory`, which registers the real Carbon hot key (⌥Q by default)
for the test process while the panel is open. This guard does not cover it;
see Limits.

## Decision

`OnScreenWindowGuard` (test target) is installed with `SystemSoundGuard` by
the `SidekeyTestBootstrap` constructor when the test bundle loads, so it
covers any `--filter`.

- **Windows.** Every AppKit order-in ends in `-[NSWindow _doOrderWindow:]`.
  The guard replaces it and the two public entries
  (`order(_:relativeTo:)`, `orderFrontRegardless`) and does not pass an
  order-in on, so the window never reaches the window server. It remembers
  the request: `isVisible` answers true until the window is ordered out or
  closed. A test of "show() shows the window" or "the second click hides it"
  checks the same thing as before; layout, drawing into a bitmap, first
  responder and events sent with `window.sendEvent` never needed the screen.
- **Focus.** `NSApp.activate` and `NSRunningApplication.activate` are recorded
  and not performed.
- **Modal UI, menus, other apps.** `NSApp.runModal(for:)`, `NSAlert.runModal`
  and its sheet, `NSSavePanel`/`NSOpenPanel` `runModal`, `begin` and sheet,
  `NSMenu.popUp`, `popUpContextMenu` and `NSWorkspace` `open`/`openApplication`
  are not performed, answer "cancelled" and **fail the test**. Unguarded, they
  stop the run with a window on screen or bring another app forward. Code that
  needs them takes an injected presenter or opener; a test that checks the
  request itself wraps it in `OnScreenWindowGuard.recording { }`.
- **Check after every test.** A teardown block added to each test asks the
  window server (`CGWindowListCopyWindowInfo`, on-screen windows of this
  process) and `NSRunningApplication.current.isActive`. Anything found fails
  that test and is ordered out. This is the part that does not depend on
  knowing every AppKit entry.
- **One real window, on request.** SwiftUI delivers a gesture only in a window
  the window server has ordered in. `orderInBeyondEveryDisplay(_:)` orders one
  for real at zero opacity, ignoring the mouse, without a closing animation,
  30,000 pt outside every display, and refuses if AppKit moved it onto a
  display. `ToolboxTileInteractionTests.test_click_selects` is the only user.
- The run ends with one summary line on stderr and one line per failing
  request; `WHYTAP_TEST_WINDOW_REPORT=<path>` writes every request by test.

## Why remember the request instead of only blocking it

A blocked window that reported `isVisible == false` would break the app's own
branches ("if the window is visible, hide it") inside tests and turn every
test of `show()` into a test of nothing. Remembering the request keeps those
checks without a pixel on screen.

## Why modal UI fails and a window does not

Showing its window is what a window controller is for, so the request is
normal and only kept off screen. A modal call in a test has no user to answer
it: without the guard the suite stops until someone clicks, on the
maintainer's screen. No test does this today, so the rule costs existing
branches nothing.

## What was tested

- Each public way to show a window (`makeKeyAndOrderFront`, `orderFront`,
  `orderFrontRegardless`, `orderBack`, `order(.above)`, `setIsVisible`,
  `showWindow`), panels and sheets: nothing listed by the window server,
  `isVisible` true, false again after order-out and close.
- The list reader against a process that has windows, and against this
  process with the one really ordered window (listed, alpha 0, intersecting
  no display, gone after order-out).
- The check after a test: while the closing animation of a really ordered
  window was still on, it failed the test that left the window and the next
  ones, naming the window number and size.
- Full `swift test` with a separate process polling the window server every
  50 ms for windows of any `xctest` process: see Result.

## Result

Full `swift test` on 2026-11-24 with the guard, 5,692 tests, 57 skipped, no
failure, 335 s. The poller took 6,885 samples: no sample had an `xctest`
window over a display. One window was listed in 8 samples (about 0.4 s): the
96×128 window of `test_click_selects`, alpha 0, at x −30,000. The guard kept
17 windows of 12 existing tests off screen and did not perform 9 activations.
The run before the last fix had the same poller result with every order-in
blocked (6,994 samples, no `xctest` window at all).

## Rejected

- Really ordering every window at zero opacity or off screen: it still is in
  the window server's list, at status-bar level, and each test would have to
  be trusted to restore opacity and position; one forgotten window is on the
  maintainer's screen again.
- Rewriting the twelve tests to not call `show()`: a one-off cleanup. The
  next window-controller test brings the windows back.
- A source-text test that forbids `makeKeyAndOrderFront` in `Tests/`: the
  calls are in the app's code, reached through `controller.show()`.
- Telling SwiftUI the remembered window is unoccluded (`occlusionState`,
  `didChangeOcclusionStateNotification`): gestures still were not delivered,
  hence the one really ordered window.
- Running `swift test` outside the GUI session: changes everyone's command
  and removes the screens that layout tests read.

## Limits

- `_doOrderWindow:` is private AppKit API. Without it the two public hooks
  still hold and only sheets pass; `OnScreenWindowGuardTests` compares the
  list of installed hooks, and the check after every test does not depend on
  any hook.
- A window that is shown and hidden inside one test by a path no hook knows
  is not seen by the check after the test.
- A sheet is not attached under the guard (`attachedSheet` stays nil; AppKit
  attaches sheets only to a window that is really on screen). The completion
  handler still runs on `endSheet`.
- Windows of other processes a test starts, and the test target
  `WhytapCaseKitTests` (no AppKit), are not covered.
- The check costs one window-server query per test.
- Global hot keys are not windows and are not covered: the Agent tests named
  in Context register a real Carbon hot key during the test. `RegisterEventHotKey`
  is a C function a test bundle cannot replace; closing this needs a
  process-wide seam in `CarbonHotkeyMonitor` and is a separate change.
- `NativeAgentTests.testDetachedOutputCannotKeepCommandWaitingAfterLeaderExit`
  failed once in the first full run. It has a 250 ms deadline and failed 1 of
  8 isolated runs with the guard and 1 of 8 without it: load, not this change.

2026-11-24.
