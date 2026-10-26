---
id: whytap-first-launch-permissions
type: decision
title: Show permission setup on a new Mac
summary: Open the existing Permissions screen once per Mac when access is missing and request Screen Recording through ScreenCaptureKit before its system settings fallback.
status: confirmed
tags: [permissions, first-launch, screen-recording, setup, restore]
canonical_for: [first-launch-permission-setup]
verified_at: 2026-10-26
sources:
  - type: user-confirmed
    reference: On 2026-10-26 the user tested a second Mac, reported Whytap missing from the screen-recording list after Allow, and explicitly chose showing Permissions immediately at first launch.
    confirmed_at: 2026-10-26
  - type: repository
    reference: Sources/Sidekey/Permissions/FirstLaunchPermissions.swift
    confirmed_at: 2026-10-26
  - type: repository
    reference: Sources/Sidekey/PermissionsHelper.swift
    confirmed_at: 2026-10-26
related: [../project.md, 2026-10-17-local-workspace.md, 2026-10-20-screenshot-toolbar.md]
---

# Decision

Keep the island available immediately and open the existing Settings → Permissions
screen once on the first GUI launch on a Mac if a listed permission is missing.
Do not interrupt an already authorized Mac on upgrade or reopen a dismissed screen
on every launch. The presentation marker is installation state, excluded from
portable settings; restoring another Mac's configuration does not suppress setup.
Showing this screen requests no permissions automatically. Each Allow button is
still the explicit permission action. No onboarding wizard is added.

The Screen Recording Allow button makes an asynchronous ScreenCaptureKit content
request, discards the returned metadata and captures no image or audio. If that
request fails and access is still missing, open the system screen-recording pane
after it completes. A pending native request shows a small progress indicator in
the existing action slot and cannot be repeated. Refresh and activation stay
passive. Screen access remains optional for voice and launch readiness.

# Verification boundary

Fake permission providers cover request order, denial fallback, already-granted
access, a grant followed by an enumeration error, and duplicate pending actions.
Temporary defaults cover one-time presentation and backup exclusion. These checks
do not prove native TCC registration on a clean Mac; the signed installed app's
Allow action and system list require acceptance on the second Mac.
