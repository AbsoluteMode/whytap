---
id: shot-single-permission-prompt-2026-11-22
type: decision
title: The first Screenshot press without access shows only the macOS dialog
summary: Screenshot asked macOS with CGRequestScreenCaptureAccess and opened Whytap's own "Allow screenshots" alert in the same press, so two Screen Recording windows appeared at once; the first press now only makes the Settings ScreenCaptureKit request, and Whytap's help is a later press.
status: confirmed
tags: [permissions, screen-recording, screenshots, first-use]
canonical_for: [screenshot-permission-request]
verified_at: 2026-11-22
sources:
  - type: user-confirmed
    reference: On 2026-11-21 the user tried Screenshot on a newly installed Whytap on a relative's Mac (macOS 14 or 15, judged by History without macOS 26 glass). Two different Screen Recording windows opened at once. Access was then granted, so the windows cannot be reproduced or captured.
    confirmed_at: 2026-11-21
  - type: repository
    reference: Sources/Sidekey/Permissions/ScreenRecordingAccess.swift
    confirmed_at: 2026-11-22
  - type: repository
    reference: Sources/Sidekey/Screenshots/ScreenshotPermissionGate.swift
    confirmed_at: 2026-11-22
  - type: repository
    reference: Sources/Sidekey/Screenshots/ScreenshotCoordinator.swift
    confirmed_at: 2026-11-22
  - type: repository
    reference: Tests/SidekeyTests/Screenshots/ScreenshotPermissionPromptTests.swift
    confirmed_at: 2026-11-22
related: [2026-11-19-permission-request-before-settings.md, 2026-10-26-first-launch-permissions.md, 2026-10-20-screenshot-toolbar.md, 2026-11-21-first-launch-onboarding.md]
---

# Context

Without Screen Recording access, `ScreenshotCoordinator.start()` ran
`CGPreflightScreenCaptureAccess() || CGRequestScreenCaptureAccess()`. The request
does not wait for the answer: on first use it puts up the system dialog and
returns `false` at once. The `false` branch then cancelled the capture and ran
Whytap's own modal `NSAlert` ("Allow screenshots", Open System Settings). Both
windows talk about Screen Recording and appeared together, which matches the
report. It is the same pattern `2026-11-19-permission-request-before-settings.md`
removed from the Settings button, left in the Screenshot path.

The other candidates were checked in the code and ruled out for this press:

- Two processes or bundle IDs: only the app captures the screen
  (`ScreenshotCoordinator`, `AgentScreenCapture`, the Settings request). The
  bundled `whytap` helper and plugins never call a capture API.
- System Audio Recording: the CoreAudio process tap belongs to Meeting Notes
  and Subtitles and is never created by Screenshot.
- The macOS 15 "bypass the system private window picker" alert concerns apps
  that already have access; the old code returned before any ScreenCaptureKit
  call when access was missing, so it could not fire on this press.

# Decision

Surfaces that ask at first use call one function,
`ScreenRecordingAccess.shared.requestOnce()`: it makes the ScreenCaptureKit
request that Settings → Permissions uses (`ScreenRecordingPermissionRequest`)
at most once per launch, remembers that in memory, and returns `granted`,
`requested` or `alreadyRequested`. After `requested` the caller shows nothing of
its own; after `alreadyRequested` it shows its help or opens System Settings.
Screenshot and the onboarding's optional Screen Recording row share this
instance, so whichever asks first, the other never asks again.

`ScreenshotPermissionGate` decides each press before a capture session starts:

- Access granted: capture as before.
- First press of a launch without access (`requestOnce()` returned
  `requested`): show nothing of Whytap's. No capture session, activity or Hover hold.
- A press within 1 s of that request: a repeat of the same press (held
  shortcut, double delivery) and does nothing.
- Any later press without access: Whytap's help alert with Open System
  Settings, never a second request. Presses while that help is pending show it
  once.

The "asked" state lives in memory, per launch, as in the Settings button. The
coordinator no longer calls `CGRequestScreenCaptureAccess` or
`CGPreflightScreenCaptureAccess` directly; a source test guards this.

# Why

macOS shows its dialog once, and its own button opens System Settings after the
app is registered, so the first press needs nothing more. One request API for
Settings and Screenshot keeps one system dialog text and one registration path.
The 1 s window only separates repeats of one press from a deliberate second
press; it is not a guess about when the dialog closes.

# What was checked

- `ScreenshotPermissionPromptTests` with fake gates: no access → one request, no
  help, no session; granted → capture without a request; denied → help on the
  next press, one request in total; repeats within 1 s → nothing; later presses
  with the dialog unanswered → one request and one help; grant after the
  request → capture on the next press; the gate forgets the request per launch;
  another surface asking first makes Shot show help without a second request;
  `requestOnce()` asks at most once.
- `swift build`, focused permission/screenshot suites and the full `swift test`.
- Not checked: the real dialogs on macOS 14/15. Whytap was not launched and
  permissions were not reset on the maintainer's Mac. Acceptance needs a Mac or
  app identity without a Screen Recording grant.
- Not proven: the exact text of the two windows; the code path explains two
  windows, and no other request exists on that press.

# Rejected

- Keeping `CGRequestScreenCaptureAccess` and only dropping the alert: would leave
  two request APIs with different dialog texts between Settings and Screenshot.
- Waiting for the dialog to close before showing help: macOS offers no signal;
  watching a private agent process was rejected on 2026-11-19.
- Asking for Screen Recording in the onboarding: a product change; Screen
  Recording is asked at first use since 2026-11-21.
- Changing `AgentScreenCapture`: it reports a tool error and shows no Whytap
  window beside the request, so it opens one window only.

2026-11-22 · branch `claude/shot-screen-permission-0afda7`
