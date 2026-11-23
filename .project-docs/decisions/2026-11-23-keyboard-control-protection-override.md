---
id: keyboard-control-protection-override-2026-11-23
type: decision
title: First-launch permissions and saved keys on macOS 27.3 beta 2
summary: Where macOS 27.3 beta refuses a new app's keyboard control or Screen Recording request without a dialog, Whytap says so plainly and lets the person continue; it never opens a pane whose only way in is the Add (+) button. Drop is not reworked for the beta.
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
    reference: https://developer.apple.com/news/?id=oqng0zjk
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
  - type: repository
    reference: Sources/Sidekey/Permissions/PermissionRequestRefusals.swift
    confirmed_at: 2026-11-23
  - type: repository
    reference: Sources/Sidekey/Onboarding/OnboardingFinaleStages.swift
    confirmed_at: 2026-11-23
  - type: repository
    reference: Sources/Sidekey/Permissions/PermissionRepairView.swift
    confirmed_at: 2026-11-23
  - type: repository
    reference: Sources/Sidekey/Settings/SettingsPermissionsView.swift
    confirmed_at: 2026-11-23
  - type: user-confirmed
    reference: On 2026-11-23 (onboarding specification 38 revision 76) the owner chose not to rework Drop for the beta, and asked that the refused steps say so in plain words and offer one Continue button, detected by the refused request rather than by a version number where possible.
    confirmed_at: 2026-11-23
  - type: url
    reference: https://support.apple.com/en-us/149699
    confirmed_at: 2026-11-23
  - type: trace
    reference: Independent throwaway consent, HIToolbox and InputMethodKit probes on build 26C5047e. Results and execution context are recorded below.
    confirmed_at: 2026-11-23
related: [2026-11-19-permission-request-before-settings.md, 2026-11-22-onboarding-journey.md]
---

# Decision

The owner requires that a new user never presses Add (+) in a privacy pane. On macOS 27.3 beta 2 a new app cannot get keyboard control or Screen Recording any other way, and Apple says known apps are not affected and entitlement details will follow. The owner chose (revision 76) not to rework Drop for a beta. So:

- Where macOS shows its own dialog (every macOS before 27.3, and 27.3 if Apple lifts the limit), the steps behave as before.
- Where the request is refused without a dialog, the keyboard step and the Screen & system audio step say "This macOS beta doesn't let new apps ask yet. Apple's temporary limit. Whytap asks again after an update." with one Continue button. They never open System & App Protection Override or the screen pane, and never sit on Waiting.
- Try Drop then says in its field that Drop needs keyboard control which this beta doesn't give new apps yet, and Continue is enabled. Settings → Permissions and Drop's repair window show "Not available yet" with the same line instead of a button that would lead to "+".

## How a refusal is detected

By what happened, not by the version number alone (`PermissionRequestRefusals`):

1. The request is sent (the AX prompt call, or the ScreenCaptureKit request).
2. For 2.5 seconds Whytap watches for a new on-screen window of the agents that show permission dialogs (universalAccessAuthWarn, UserNotificationCenter, SecurityAgent) or of System Settings. Only window owners and numbers are read, which needs no Screen Recording.
3. No new window and still no access means refused. Access during the wait, or any dialog, means not refused.

The check runs only where the old Accessibility pane is gone (27.3 and later). On older macOS a request that shows no second dialog is normal (macOS asks once), and would otherwise be taken for a refusal. A refusal is stored with the macOS build (`sidekey.permissions.refusedRequests.v1`), so a relaunch or a Quit & Reopen shows it at once without asking again, and an OS update asks again. A later grant, however it came, clears it. On 27.3 the keyboard button never opens the Override pane, even after a dialog: it asks macOS again.

Rejected: a pure version check (would stay wrong when Apple lifts the limit within 27.3); reading the TCC database or the unified log (needs privileges an app doesn't have); the CGPreflight results (they only say access is off, not whether macOS asked); opening the pane with instructions for "+" (the owner's hard rule).

Not verified live: the detector against the real dialogs on this build and on an older macOS, and the activation guard below. Unit tests cover the refused, dialog, grant-during-wait, per-build memory and older-macOS cases with injected checks.

## Keyboard control

Apple changed Device Control and Data Access in [macOS 27.3 beta 2, build 26C5047e](https://developer.apple.com/news/releases/?id=11162026c). Prior grants survive an OS update. Apple distinguishes designated assistive technologies and already known apps. A program cannot infer how another app obtained permission by looking at its row. [Apple Developer announcement](https://developer.apple.com/news/?id=oqng0zjk)

A person selects the requesting app in System Settings. For scoped control, Choose Apps identifies individual targets, with Ask First or At Any Time for each. The broader option includes control across apps and requires explicit acknowledgments and authentication. Apple gives no public call in these instructions for an ordinary app to add itself or preselect itself in the pane. The public AX trust call has a prompt option and returns current trust immediately. Any prompt is asynchronous and cannot change that return value. [Apple Support](https://support.apple.com/en-us/149699) · [AX trust check](https://developer.apple.com/documentation/applicationservices/1459186-axisprocesstrustedwithoptions)

The prior capture of the installed Whytap's request recorded `phase=notEntitled` from the accessibility authorization flow. At 15:08:41 TCC modified Accessibility and AccessibilityPerTarget records for Whytap, the next trust check returned `result=0 access=none`, and at 15:08:56 the records were deleted. The screenshots show a different app, Whytap-Beta-dev, with global access. None records the user's choice in the subsequent confirmation sheet. This explains Waiting. It does not establish who removed the records, a cancelled click, or a missed timer tick.

Independently inspected on the same OS: the system pane resources identify System & App Protection Override and the designated Accessibility list. Apple's authorization helper contains the entitlement name `com.apple.developer.assistive-technology`. The installed production bundle has a Developer ID designated requirement and the Accessibility usage description. Its signed entitlements do not contain that designation. These facts support an eligibility failure in the AX prompt path. Apple's eligibility decision for Whytap, the internal cause of record deletion and a public per-target prompt API remain unverified. The settings URL is an observed route on this build, not a documented Apple API contract. [Apple DTS on 27.3 event taps and settings URLs](https://developer.apple.com/forums/thread/857997)

The current Drop checks AX trust, monitors a key down and up with an active event tap, checks whether the target accepts text, and delivers the transcript using its paste path. Input Monitoring may help authorize an event tap. It cannot establish permission to post a paste to an arbitrary app. A scoped grant does not meet the current global readiness check. See `SpaceHoldMonitor`, `PermissionsHelper` and `AutoPasteEngine`.

Apple DTS distinguishes listen-only taps from posting events and flags a PostEvent bug in 27.3 beta 2. Its linked report concerns device-management removal (FB25626409). The owner’s trace already stops at the AX trust check. It does not show this PostEvent bug occurring. Verify both the trust state and an actual hold and insertion before declaring Drop ready. [DTS on event taps](https://developer.apple.com/forums/thread/857997) · [DTS on the reported bug](https://developer.apple.com/forums/thread/858535?answerId=917678022)

## Independent probe limits

All probes used temporary binaries, with no real provider credentials, clipboard data or production permission resets.

| Experiment on 26C5047e | Result |
| --- | --- |
| Ad-hoc signed consent bundle, directly invoked in the coding session | Recognized its own bundle ID. Passive AX, ListenEvent, PostEvent and ScreenCapture checks were false. Microphone status was denied. These values describe the sandboxed process. |
| Launch the same bundle through LaunchServices | Returned -10827. The executable exists, codesign verified, and Foundation resolved its executable URL. The session could not resolve Finder, saw zero screens, and had no console session. The standalone prompt path, including Whytap's actual ScreenCaptureKit request, could not be measured. |
| Build a hold probe and a separate text-field app, with a fixed insertion marker addressed only to the test field app | Both bundles compiled and signed. The hold probe returned 2 on its graphical-session check before installing an event tap. No cross-app insertion was observed. |
| Register an unused modified K and a modified F19 with Carbon, then unregister on success | Both returned -9868 (eventInternalErr) without a hotkey reference in this session. No physical key was delivered to the probe and no text was posted to a live app. |
| Build an InputMethodKit input method with a real IMKServer and an IMKInputController calling IMKTextInput.insertText for a fixed test marker | Built and signed. TISRegisterInputSource on the temporary bundle returned 0, but input-source enumeration returned nil with an invalid HIServices connection. There was no source to enable or select. The SDK requires a bundle in a user or system Library/Input Methods directory. The temporary bundle was outside those directories. |
| Activate the IME and type a marker into Chrome, Slack, Terminal and Claude | All four remain untested. No input source was selected or installed in the owner's login. Registration status alone cannot prove active-client insertion, layout compatibility or preservation of ordinary Space. |

The earlier independently identified local-signature probe reported no dialog for CGRequestPostEventAccess, CGRequestListenEventAccess or CGRequestScreenCaptureAccess, and a native microphone prompt. Those were different calls from Whytap's ScreenCaptureKit request. The historical unified log cannot be re-read from the coding sandbox.

## Screen, system audio and microphone

The current Shot enumerates displays and captures a still per display before drawing its region editor. It requires screen access in that implementation. Apple offers system-scoped selection with SCContentSharingPicker. A Shot alternative would start at the picker, use its returned filter, and open the region editor for the chosen display. The picker cannot authorize a different enumeration of every display or establish a persistent grant for the Agent. Cancellation and multiple monitors need acceptance. [Apple on picker consent](https://developer.apple.com/videos/play/wwdc2023/10053/?time=344)

Meeting Notes and Subtitles use CoreAudioSystemAudioSource. An audio-only recording grant is sufficient for their system-audio path. Meeting microphone capture has its own permission. The lower audio-only switch can remain on after resetting ScreenCapture. When a Core Audio tap is part of an aggregate device, Apple says first recording from that device prompts for system audio. A display-only picker probe built successfully. The coding process had no console display on which to present it or obtain a filter. The screen preflight proves nothing about the result of that prompt. Whytap asks for microphone access with AVFoundation, with a settings action after denial. [Apple screen and audio settings](https://support.apple.com/guide/mac-help/mchld6aa7d23/mac) · [Apple Core Audio engineer](https://developer.apple.com/forums/thread/771864) · [AVFoundation authorization](https://developer.apple.com/documentation/avfoundation/avcapturedevice/requestaccess(for:completionhandler:))

## Comparable products

- Raycast documents Accessibility for direct insertion and an alternative clipboard output. Wispr Flow documents separate Microphone and Accessibility grants and advances a card after a grant. Superwhisper documents an auto-paste option and clipboard recovery. [Raycast Dictation](https://manual.raycast.com/ai/dictation) · [Wispr installation](https://docs.wisprflow.ai/articles/7682075140-how-to-install-wispr-flow-on-mac) · [Superwhisper changelog](https://superwhisper.com/changelog)
- Hammerspoon documents manual Accessibility approval. OBS distinguishes screen capture, microphone and background shortcut access. Loom publishes Mac setup instructions, and CleanShot records permission-dialog fixes. None of those instructions establishes that a previously unknown bundle can obtain global control in one click on 26C5047e. No competitor's real permissions were reset. [Hammerspoon FAQ](https://www.hammerspoon.org/faq/) · [OBS permissions](https://obsproject.com/kb/macos-permissions-guide) · [Loom setup](https://support.atlassian.com/loom/docs/get-started-with-loom-for-macos/) · [CleanShot changelog](https://cleanshot.com/changelog)

## Draft behavior and outstanding acceptance

The language choice comes first. A sole saved key is offered on its provider's tab. Multiple saved keys remain available by name, with no route change until the user accepts. While the onboarding window is open, Whytap enters the app switcher, brings the visible window forward on activation unless another Whytap window (Settings) was made key, and preserves the pending step across an application quit. A permission step continues checking for a grant while it is on screen, so a grant that arrives later still moves it on. Older versions retain their request-first behavior.

The preview uses simulated permissions and in-memory keys. Its native window renders and model transitions exercise the owner-facing screens. It cannot verify the app switcher in the user's login, a real Quit & Reopen, a provider transcription or real permissions. Those gates require a separate interactive test login with a recognized test bundle. Product alternatives for Drop are the existing trusted event tap, an active input method, or an explicit registered shortcut with a manual paste. None is certified as the requested clean flow yet.
