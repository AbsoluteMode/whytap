---
id: silent-test-runs-2026-11-23
type: decision
title: Test runs play no system sound, and a key nobody takes fails the test
summary: A guard installed when the test bundle loads turns the AppKit alert off for the test process, records which test asked for a sound and fails a test whose key reaches the end of a window's responder chain or that plays a sound file; a key sent to the app without a key window is only reported.
status: confirmed
tags: [tests, sound, appkit, guard]
canonical_for: [test-run-sounds]
verified_at: 2026-11-23
sources:
  - type: user-confirmed
    reference: On 2026-11-23 the maintainer heard series of system alert sounds while doing nothing; full test runs by the builder and feature sessions were going on, and the task asked for a silent `swift test` with the sources found.
    confirmed_at: 2026-11-23
  - type: repository
    reference: Tests/SidekeyTests/Support/SystemSoundGuard.swift
    confirmed_at: 2026-11-23
  - type: repository
    reference: Tests/SidekeyTestBootstrap/SidekeyTestBootstrap.m
    confirmed_at: 2026-11-23
  - type: repository
    reference: Tests/SidekeyTests/Support/SystemSoundGuardTests.swift
    confirmed_at: 2026-11-23
related: [../processes/shared-app-development.md, 2026-11-24-windowless-test-runs.md]
---

# Silent test runs

## Context

The full suite runs dozens of times a day on the maintainer's Mac (the
builder and every feature session). Each run played the system alert sound
twelve times.

Measured on 2026-11-23, main at `83b8f643`. `NSBeep` ends in
`AudioServicesPlayAlertSound(0x1000)`, and CoreAudio logs every such call with
the client process (`log stream --level debug --predicate 'subsystem ==
"com.apple.coreaudio" AND category == "ssc"'`, line `systemSoundID = 4096`).
Five full runs in a row (one of this task, four of other sessions) logged
exactly twelve alerts each, in two bursts of six. Both bursts are in
`OnboardingPreviewTests`:
`testSpaceInThePreviewWindowDictatesIntoTheField` and
`testSpaceInTheWholeWindowNeverTypesIntoTryDrop`. They send Space through
`NSApp.sendEvent`. A test process has no key window, and
`-[NSApplication sendEvent:]` then calls `NSBeep` directly for a key no event
monitor took (seen in its disassembly: `routeKeyEquivalent`, then `NSBeep`).
That is an artifact of the test: an app without a key window gets no keys.
The app has no `NSBeep`, `NSSound.beep()` or `AudioServicesPlay…` call of its
own. No test on main sends a key that falls off a window's responder chain,
and none plays a sound file.

## Decision

`SystemSoundGuard` (test target) is installed when the test bundle loads, by
the constructor in the Objective-C target `SidekeyTestBootstrap`, so it covers
any `--filter`.

- The AppKit alert is turned off for the test process with
  `+[NSSound _setAlertType:]` (0: no sound, no flash). Every AppKit path to
  `NSBeep` is then silent, including ones nobody listed.
- A key that reaches `noResponder(for: keyDown:)` on a window is recorded and
  **fails the test**. The same key makes the app beep for the user, so the
  test found a product defect (History, the Agent card and the onboarding
  each had one). A test whose point is that a key is passed on wraps the call
  in `SystemSoundGuard.expectingSound { }`.
- `NSSound.play()` is not played and fails the test the same way.
- A key sent with `NSApp.sendEvent` while there is no key window is recorded
  as a test artifact and never fails: it says nothing about the app.
- The run ends with a report on stderr (which test, what, how often);
  `WHYTAP_TEST_SOUND_REPORT=<path>` also writes it to a file.

## Why fail and not only report

A report at the end of 5,700 tests is read by nobody; the suite stayed
audible for weeks for that reason. A failure reaches the author of the test
while the cause is in front of them, and the remedy is one of two short
things: make the app take the key, or state that the sound is intended. The
failing kind is deterministic (the event is delivered to a window
synchronously), so it adds no flakiness; the kind that depends on the state
of the test process (no key window) is the one that only reports. On main
nothing fails today, so the rule costs existing branches nothing.

## What was tested

- A bare window sent an unhandled key: recorded with the test, nothing in the
  CoreAudio log.
- `NSApp.sendEvent` without a key window, `NSSound.beep()` and
  `NSSound.play()`: no CoreAudio log line for the test process.
- Full `swift test` with the guard: zero `systemSoundID` lines for its
  process, twelve recorded artifacts in the two tests above, no unexpected
  sound.

## Rejected

- A local event monitor installed first, swallowing keys when there is no key
  window: AppKit's monitor order is not "newest first" across different event
  masks; the guard's monitor ran before the onboarding stand-in's and two
  tests failed.
- Lending a key window during `sendEvent`: AppKit does not read
  `NSApp.keyWindow` there, and making a real window key posts
  resign-key notifications the code under test listens to.
- Interposing `NSBeep` or `AudioServicesPlayAlertSound`: calls inside the
  shared cache cannot be rebound from a test bundle, and `DYLD_INSERT_LIBRARIES`
  would change everyone's `swift test` command.
- A debugger breakpoint: Developer Mode is off on the build Mac.
- Changing the user's alert volume or sound settings: tests do not touch the
  user's settings.

## Limits

`_setAlertType:` is private AppKit API; the guard checks that it exists. If a
future macOS drops it, alerts from paths the guard does not replace become
audible again, and `SystemSoundGuardTests` plus the CoreAudio log line above
are the way to see it. Sounds played through other APIs (`AVAudioPlayer`,
`AudioServicesPlaySystemSound` called by the app itself) are not covered;
the app has none in tested code today.

2026-11-23.
