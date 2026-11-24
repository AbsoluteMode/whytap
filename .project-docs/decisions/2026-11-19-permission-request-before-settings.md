---
id: permission-request-before-settings-2026-11-19
type: decision
title: Ask macOS first, open System Settings on the next press
summary: The first Allow for Keyboard control or Screen Recording only makes the system request; the same button then becomes Open Settings, so Whytap never opens the privacy pane in the action that asks macOS.
status: confirmed
tags: [permissions, accessibility, screen-recording, settings, first-launch]
canonical_for: [permission-request-order]
verified_at: 2026-11-19
sources:
  - type: user-confirmed
    reference: On 2026-11-19 the user reported a person with a factory-reset MacBook Air M2 on macOS 27 and Whytap 2.2.24. Allow sent them to System Settings, Whytap was in neither the Accessibility nor the Screen Recording list, and they added it by hand in both.
    confirmed_at: 2026-11-19
  - type: repository
    reference: Sources/Sidekey/Permissions/PermissionsSettingsViewModel.swift
    confirmed_at: 2026-11-19
  - type: repository
    reference: Sources/Sidekey/PermissionsHelper.swift
    confirmed_at: 2026-11-19
  - type: repository
    reference: Tests/SidekeyTests/PermissionsSettingsViewModelTests.swift
    confirmed_at: 2026-11-19
related: [2026-10-26-first-launch-permissions.md, 2026-11-21-first-launch-onboarding.md, 2026-11-22-shot-single-permission-prompt.md, 2026-11-23-keyboard-control-protection-override.md]
---

# Context

On a Mac without any earlier grant, Allow in Settings → Permissions opened System
Settings at once and the list had no Whytap row, for Keyboard control and for
Screen Recording. Both actions asked macOS and opened the privacy pane in the
same click:

- Keyboard control called `AXIsProcessTrustedWithOptions` with the prompt option,
  which returns immediately, and then opened the Accessibility pane.
- Screen Recording awaited a ScreenCaptureKit content request and opened the
  pane when it failed. The request fails while the system dialog is still on
  screen, so the pane opened beside the dialog as well.

# Decision

Never open the privacy pane in the action that makes the system request.

- The first Allow of a launch only asks macOS. Its dialog has its own button to
  System Settings, which opens the pane after the app is registered.
- The row's button then reads Open Settings and opens the pane on every later
  press. macOS shows its dialog once, so the button must not go dead.
- A granted permission neither asks nor opens anything.
- The "already asked" state lives in memory only. A stored flag would skip the
  request on a Mac whose permissions were reset, which is the failure above.

This replaces the "open the system pane after a failed request" sentence of
`2026-10-26-first-launch-permissions.md`. Requesting nothing until Allow is
unchanged; since 2026-11-21 the first launch shows the onboarding, whose
permissions page follows the same order (`2026-11-21-first-launch-onboarding.md`).

# Why

The 2026-10-26 fix for Screen Recording removed the same pattern (`request, else
open the pane`) after the same report on a second Mac, but its error path still
opened the pane next to the dialog, and Keyboard control was not changed. Three
independent readings of the code (Claude, Codex, Gemini) arrived at this order
as the common cause.

# What was checked

- Fake providers: first press requests without opening the pane; later presses
  open it; a grant stops both; a failed ScreenCaptureKit request is not an error.
- Not checked: that macOS 27 lists Whytap after this change. No test can read the
  system lists. Acceptance needs an app identity without earlier grants.
- Not proven: why the pane opened beside the request lacks the row (pane loaded
  before the registration, or the dialog hidden behind it). Only the order was
  confirmed.

# Rejected

- Waiting ~300 ms and looking for the `universalaccessAuthWarn` process: depends
  on a private agent's name and a guessed delay.
- Opening the pane after a fixed delay: still a race, only less often.
- Requesting permissions at first launch without a click: a product change, and
  it does not remove the race.
- Changing the Input Monitoring button in the Drop status block: same order
  there, but nobody reported it and it is a lazy fallback; left as is.

2026-11-19 · branch `claude/app-permissions-macos-issue-be8fce`
