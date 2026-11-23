---
id: keyboard-control-protection-override-2026-11-23
type: decision
title: Keyboard control names System & App Protection Override on macOS 27.3
summary: On macOS 27.3 and later the onboarding's Keyboard control step names the pane the Accessibility link opens, System & App Protection Override, and tells the person to add Whytap with +, because that list has no Whytap row until they do.
status: confirmed
tags: [onboarding, permissions, accessibility, macos-27]
canonical_for: [keyboard-control-pane-name]
verified_at: 2026-11-23
sources:
  - type: user-confirmed
    reference: On 2026-11-23 the owner went through the onboarding from cleared settings in build 1737 on macOS 27.3. Open System Settings showed a pane titled System & App Protection Override with no Whytap row, while the step said Privacy & Security › Accessibility.
    confirmed_at: 2026-11-23
  - type: url
    reference: https://mjtsai.com/blog/2026/11/17/system-app-protection-override/ and https://www.macrumors.com/2026/11/16/macos-27-3-full-desk-access/ (macOS 27.3 splits Device Control and Data Access into System & App Protection Override and Accessibility; apps are added with +)
    confirmed_at: 2026-11-23
  - type: repository
    reference: Sources/Sidekey/Onboarding/OnboardingAccessStage.swift
    confirmed_at: 2026-11-23
related: [2026-11-19-permission-request-before-settings.md, 2026-11-22-onboarding-journey.md]
---

# Context

On macOS 27.3 the `Privacy_Accessibility` link that Keyboard control opens lands
on a pane titled System & App Protection Override. Its rows read "Control your
entire Mac and all apps" or "Not Allowed". After the permissions were reset,
Whytap was not in the list, and the step still said "Turn on Whytap · Privacy &
Security › Accessibility". The owner did not know what to do there.

Reports on the 27.3 betas say Apple split Device Control and Data Access into
System & App Protection Override (apps that control other apps) and
Accessibility (assistive technologies). An app's request no longer adds its
row; the person adds it with +.

# Decision

- On macOS 27.3 and later, Keyboard control names the pane System & App
  Protection Override. Its waiting line reads "Click + under the list, add
  Whytap, then come back here.", and its not-on line names the same pane.
- The link is unchanged: `Privacy_Accessibility` already opens this pane.
- Allow and the request order of `2026-11-19-permission-request-before-settings.md`
  are unchanged. Only the system's own check moves the step on.
- Older macOS keeps "Accessibility" and "Turn on Whytap".

# Why

The step should name what the person actually sees. The version check reads the
running system, so one build tells both kinds of Mac the right thing.

# What was checked

- Unit test: with the flag off the step says Accessibility; with it on it says
  System & App Protection Override and "add with +"; the other panes are
  unchanged.
- Not checked: that granting System & App Protection Override makes
  `AXIsProcessTrusted` true for Whytap. No public documentation covers it yet;
  the owner's live step will show it. If it stays on Waiting, the separate
  Accessibility pane is the next thing to try.
- Not checked: whether 27.3's final release keeps the pane name of the beta
  reports. The owner's Mac runs 27.3 (build 26C5047e) and shows this name.

# Rejected

- Opening the pane on the first Allow: still the 2026-11-19 race on Macs where
  the request does register the app.
- Naming a button of the + dialog ("Override System Protections"): no source
  shows that dialog on the owner's build, and a wrong button name misleads more
  than none.

2026-11-23 · branch `feature/onboarding-accessibility-macos27`
