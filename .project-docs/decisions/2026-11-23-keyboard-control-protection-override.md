---
id: keyboard-control-protection-override-2026-11-23
type: decision
title: Keyboard control on macOS 27.3 opens System & App Protection Override and says what to press
summary: On macOS 27.3 an app without Apple's assistive-technology entitlement cannot make the system list it for Accessibility, so the first Allow of Keyboard control also opens System & App Protection Override and the step says "Click +, choose Whytap, then Override System Protections". Key steps name every provider whose key is already in the Keychain.
status: confirmed
tags: [onboarding, permissions, accessibility, macos-27, keys]
canonical_for: [keyboard-control-pane-name, onboarding-saved-keys-line]
verified_at: 2026-11-23
sources:
  - type: user-confirmed
    reference: On 2026-11-23 the owner went through the onboarding from cleared settings and reset permissions in build 1737 on macOS 27.3 (26C5047e). Open System Settings showed System & App Protection Override with no Whytap row; adding Whytap with + did not move the step; the owner asked twice for provider keys by hand.
    confirmed_at: 2026-11-23
  - type: trace
    reference: Unified log on the owner's Mac, 2026-11-23 15:03-15:09, subsystem com.apple.accessibility.per-app-access and process tccd (read only)
    confirmed_at: 2026-11-23
  - type: trace
    reference: macOS 27.3 system files /System/Library/ExtensionKit/Extensions/SecurityPrivacyExtension.appex (English strings ACCESSIBILITY, ACCESSIBILITY_APPS, ACCESSIBILITY_ADD_BYPASS, ACCESSIBILITY_APPS_PANE_FOOTER; anchors Privacy_Accessibility and Privacy_AccessibilityApps) and universalAccessAuthWarn (com.apple.developer.assistive-technology)
    confirmed_at: 2026-11-23
  - type: url
    reference: https://mjtsai.com/blog/2026/11/17/system-app-protection-override/ and https://www.macrumors.com/2026/11/16/macos-27-3-full-desk-access/
    confirmed_at: 2026-11-23
  - type: repository
    reference: Sources/Sidekey/PermissionsHelper.swift
    confirmed_at: 2026-11-23
  - type: repository
    reference: Sources/Sidekey/Permissions/PermissionsSettingsViewModel.swift
    confirmed_at: 2026-11-23
  - type: repository
    reference: Sources/Sidekey/Onboarding/OnboardingAccessStage.swift
    confirmed_at: 2026-11-23
  - type: repository
    reference: Sources/Sidekey/Onboarding/OnboardingWireframe.swift
    confirmed_at: 2026-11-23
related: [2026-11-19-permission-request-before-settings.md, 2026-11-22-onboarding-journey.md]
---

# Context

On macOS 27.3, from cleared settings and a `tccutil reset`, Keyboard control
waited forever. What the system log on that Mac showed:

- Allow called `AXIsProcessTrustedWithOptions` with the prompt option. The
  per-app-access client sent `display=forceShow` to universalAccessAuthWarn,
  which answered `phase=notEntitled`. No dialog appeared and tccd wrote no
  record, so Whytap had no row.
- `Privacy_Accessibility` opens the pane whose English title is "System & App
  Protection Override" (string key `ACCESSIBILITY`). The separate
  "Accessibility" pane (`Privacy_AccessibilityApps`) is "Only apps with an
  Accessibility designation, such as screen readers and voice control tools".
  The designation is the `com.apple.developer.assistive-technology`
  entitlement, which universalAccessAuthWarn checks.
- After the person's + at 15:08:41, tccd modified kTCCServiceAccessibility and
  kTCCServiceAccessibilityPerTarget for Whytap. Whytap's check right after
  returned `result=0 access=none`. At 15:08:56 both records were deleted. The
  row never got the global grant.
- Every process that the log shows as trusted has `result=1 access=global`
  (Claude, Raycast, and Whytap before the reset). The global grant is the "+ →
  Override System Protections" path (`ACCESSIBILITY_ADD_BYPASS`); "Choose Apps"
  gives per-app control only.

The key steps offered a saved key only as the faint placeholder of the
provider tab that was open: Soniox by default for speech. A key kept for
another provider (ElevenLabs on the owner's Mac) needed a click on its mark,
which nothing told the person to make.

# Decision

- On macOS 27.3 and later (`PermissionsHelper.accessibilityIsAddedByHand`):
  - The first Allow asks macOS and opens the pane in the same press.
  - The step names System & App Protection Override.
  - The waiting line reads "Click +, choose Whytap, then Override System
    Protections."
  - Polling and the return to the app still move the step on once
    `AXIsProcessTrusted` is true.
- Older macOS keeps the 2026-11-19 order (ask first, pane on the next press)
  and the "Accessibility" wording.
- Key steps name every provider of the step whose key is in the Keychain
  under an empty field: "Saved in your Keychain: Soniox · ElevenLabs". A name
  picks its tab, whose placeholder then says "press Return to use it".

# Why

- Nothing can race the pane on 27.3: the request registers nothing. Leaving
  the person in Waiting with a quiet link was the failure.
- The minimum macOS itself requires on 27.3, for an app without the
  entitlement, is:
  1. + in that pane;
  2. pick Whytap;
  3. Override System Protections;
  4. the system's password or Touch ID confirmation.
- The app cannot do any of these steps for the person.
- Naming the saved providers costs one line and removes the guess about which
  mark hides a key.

# What was checked

- Unit tests:
  - first Allow on 27.3 asks and opens the pane; later presses open the pane; a
    grant stops both;
  - older macOS is unchanged;
  - the pane name and lines follow the flag.
- Offscreen renders: the waiting and not-on lines fit at 520 pt; the saved
  keys line under the speech key field with Soniox and ElevenLabs saved.
- Not checked on a Mac:
  - that the four steps above end with the step moving on. The log shows global
    access is what makes other apps trusted, but no one has finished that path
    for Whytap yet;
  - Microphone, Screen Recording and Input Monitoring for Whytap itself
    after a reset on 27.3: the owner's pass stopped before them.
- A probe app with its own bundle id (`dev.claudeprobe.tcc27`, signed with a
  local identity, registered with LaunchServices) on the same Mac:
  - the Microphone request shows the system dialog;
  - `CGRequestPostEventAccess`, `CGRequestListenEventAccess` and
    `CGRequestScreenCaptureAccess` show nothing; tccd logs "does not allow
    prompting; returning denied";
  - nothing is added to the lists.
  The probe was removed afterwards.
- The owner then required that a person never press + (2026-11-23). No
  27.3 path without + was found for Keyboard control. The keyboard part of
  this change waits for the owner's choice; the pull request is a draft.
- Saved keys (model test with test keys):
  - the speech step names Soniox and ElevenLabs;
  - a mark without a key keeps the list, and Return checks nothing;
  - a click on ElevenLabs, then Return, routes Drop to ElevenLabs.

# Screen, system audio and relaunch (REV 73)

- On macOS 27.3 `CGRequestScreenCaptureAccess` shows no dialog (the probe
  above). The first Allow now opens the pane once the request returned, so
  Whytap is registered before the pane loads.
- The pane has been called "Screen & System Audio Recording" since macOS 15,
  with a second list, "System Audio Recording Only" (`kTCCServiceAudioCapture`).
  Whytap records the Mac's audio with a CoreAudio process tap; that service is
  separate from `kTCCServiceScreenCapture`. A `tccutil reset ScreenCapture`
  leaves it alone, which is why the owner's audio switch was still on. On a new
  Mac it is asked when a process tap is first created. That prompt is not
  verified on 27.3.
- The step is named "Screen & system audio." and says what each part is for.
- System Settings' Quit & Reopen sends a Quit Apple Event. The log on the
  owner's Mac showed the relaunched process with no window: the window's close
  during the quit had cleared `sidekey.onboarding.pending.v1`. A quit no longer
  finishes the onboarding, and the shown step is kept in
  `sidekey.onboarding.step.v1`. The relaunch opens there, or at the next step
  still on the way.

# Rejected

- Asking for `com.apple.developer.assistive-technology`: Apple limits it to
  assistive technologies and has not published how to request it; Whytap is
  not one.
- Sending people to the Accessibility pane: it lists only apps with that
  entitlement.
- Picking a speech tab from Keychain item dates: a guess about which provider
  the person wants.

2026-11-23 · branch `feature/onboarding-accessibility-macos27`
