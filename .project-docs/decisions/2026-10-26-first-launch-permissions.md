---
id: whytap-first-launch-permissions
type: decision
title: Screen Recording request, and the former first-launch Permissions screen
summary: Screen Recording is requested through ScreenCaptureKit from its Allow button; since 2026-11-21 the first launch opens the onboarding instead of this screen and Screen Recording is asked at first use, not on the first launch.
status: confirmed
tags: [permissions, first-launch, screen-recording, setup, restore]
canonical_for: [screen-recording-permission-request]
verified_at: 2026-11-21
sources:
  - type: user-confirmed
    reference: On 2026-11-21 the maintainer chose an onboarding in place of this first-launch screen and asked to remove Screen Recording from the first launch, asking for it at the first screenshot or Agent screen capture instead.
    confirmed_at: 2026-11-21
  - type: user-confirmed
    reference: On 2026-10-26 the user tested a second Mac, reported Whytap missing from the screen-recording list after Allow, and explicitly chose showing Permissions immediately at first launch.
    confirmed_at: 2026-10-26
  - type: repository
    reference: Sources/Sidekey/Onboarding/OnboardingFlow.swift
    confirmed_at: 2026-11-21
  - type: repository
    reference: Sources/Sidekey/PermissionsHelper.swift
    confirmed_at: 2026-10-26
related: [2026-11-21-first-launch-onboarding.md, ../project.md, 2026-10-17-local-workspace.md, 2026-10-20-screenshot-toolbar.md, 2026-11-19-permission-request-before-settings.md, 2026-11-22-shot-single-permission-prompt.md]
---

# Decision

**Changed 2026-11-21** (`2026-11-21-first-launch-onboarding.md`): the first GUI
launch on a Mac opens the onboarding instead of Settings -> Permissions, and the
onboarding asks only for Microphone and Keyboard control. Screen Recording is no
longer part of the first launch: it is asked by the first screenshot or Agent
screen capture, or from its Allow button in Settings -> Permissions. The marker
`sidekey.permissions.firstLaunchPresented.v1` keeps its meaning ("this Mac ran
Whytap"), stays on the Mac and is excluded from portable settings, so updated
Macs see neither the onboarding nor this screen.

What follows is the original 2026-10-26 decision as far as it still holds.
The first launch opened the existing Settings → Permissions screen once on a
Mac where a listed permission was missing (Screen Recording included), and
never on an already authorized Mac or after a dismissal. Showing a screen
requests no permissions automatically; each Allow button is the explicit
permission action.

The Screen Recording Allow button makes an asynchronous ScreenCaptureKit content
request, discards the returned metadata and captures no image or audio. Opening
the system pane after a failed request was replaced on 2026-11-19 by
`2026-11-19-permission-request-before-settings.md`: the pane is a later press. A pending native request shows a small progress indicator in
the existing action slot and cannot be repeated. Refresh and activation stay
passive. Screen access remains optional for voice and launch readiness.

# Verification boundary

Fake permission providers cover request order, denial fallback, already-granted
access, a grant followed by an enumeration error, and duplicate pending actions.
Temporary defaults cover one-time presentation and backup exclusion (since
2026-11-21 in `OnboardingTests`). These checks
do not prove native TCC registration on a clean Mac; the signed installed app's
Allow action and system list require acceptance on the second Mac.
