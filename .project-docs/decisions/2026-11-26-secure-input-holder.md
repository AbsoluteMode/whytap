---
id: secure-input-holder-2026-11-26
type: decision
title: Whytap points at the app holding Secure Input instead of letting shortcuts die silently
summary: While another app holds Secure Event Input, macOS drops Whytap's event-tap keys and Option-only Carbon shortcuts. Whytap cannot get around that and does not try. It watches modifier changes, which secure input does not block, and when a blocked shortcut's chord is pressed and nothing arrives it shakes the holder's logo to the right of the island. A background app that keeps secure input after Cmd-Tab gets a dimmed logo there until it lets go. The holder is tracked by Whytap itself, because macOS reports the frontmost app as the owner.
status: confirmed
tags: [hotkeys, secure-input, island, carbon, event-tap, accessibility]
canonical_for: [secure-input-holder-indicator]
verified_at: 2026-11-26
sources:
  - type: user-confirmed
    reference: The maintainer, in Dia on a password form, Cmd-Tabbed to another app and pressed the Shot shortcut (⌥F); nothing happened ("it held the keyboard again"). He asked that the logo of the app holding the keyboard shake in the right corner when a shortcut is tried.
    confirmed_at: 2026-11-26
  - type: repository
    reference: Sources/Sidekey/Hotkeys/SecureInputHolder.swift
    confirmed_at: 2026-11-26
  - type: repository
    reference: Sources/Sidekey/Hotkeys/SecureInputGuard.swift
    confirmed_at: 2026-11-26
  - type: repository
    reference: Sources/Sidekey/DynamicIsland/SecureInputHolderPanel.swift
    confirmed_at: 2026-11-26
  - type: repository
    reference: Tests/SidekeyTests/Hotkeys/SecureInputGuardTests.swift
    confirmed_at: 2026-11-26
related: []
---

# Whytap points at the app holding Secure Input

## Context

Secure Event Input is the macOS mode a password field turns on so that no
other process can read the keys typed into it. A browser (Dia here) sometimes
keeps it on after the person Cmd-Tabs away. From then on, every app's global
shortcuts die without any sign, and Whytap's looked broken: the maintainer
pressed ⌥F for Shot in another app and nothing happened.

## What was measured (macOS 27.3, 2026-11-26)

Test helpers in a scratch folder: a background holder process calling
`EnableSecureEventInput`, a listener with Carbon hotkeys on F19 under six
modifier sets, a listen-only session `CGEventTap` and an `NSEvent` global
monitor, and a separate poster sending synthetic F19 presses. Dia and other
apps were not automated.

| Mechanism | Secure input off | Secure input on (background holder) |
|---|---|---|
| `CGEventTap` keyDown (`SpaceHoldMonitor`: hold-Space Drop, hold-combo Drop) | 6/6 | **0/6** |
| `NSEvent` global keyDown | 6/6 | **0/6** |
| `flagsChanged` in the tap and in the global monitor (modifier-only shortcuts: Agent's Right ⌘, Google's Right ⌥) | arrive | **still arrive** |
| Carbon `RegisterEventHotKey`, synthetic keys, all modifier sets | fire | fire |

Synthetic keys cannot settle the Carbon case: they reached Option-only Carbon
hotkeys under secure input, yet the maintainer's real ⌥F did not, and users of
other launchers report the same split for real keys (Alfred's ⌥Space dead in a
browser password field while ⌘Space still opens Spotlight; Apple DTS calls the
Sequoia Option-only hotkey restriction a key-logger defence). The working rule
is: **under secure input, Carbon combos whose modifiers are only Option and/or
Shift (or none) are dropped; combos with Command or Control still fire.** This
is the one assumption the maintainer's acceptance check confirms.

`kCGSSessionSecureInputPID` (what `ioreg -l | grep SecureInput` prints) is not
the owner: with a background holder it reported the **frontmost** app, and it
followed the focus when the frontmost app changed. Trusting it would blame
the app the person switched to.

## Decision

1. **No workaround of the protection.** Shortcuts are not moved to IOHID or
   anything else that would read keys secure input withholds. There is
   nothing to move to: an Option-only combo has no surviving mechanism, and a
   hotkey with ⌘ or ⌃ already survives on Carbon. The hover label does not
   advertise that; the person learns which app to fix.
2. **Notice the failed attempt from modifiers.** `flagsChanged` still arrives,
   so `SecureInputAttemptDetector` treats "a chord of a blocked shortcut was
   held for at most 3 s and released, and no Whytap shortcut arrived
   meanwhile" as a failed attempt. Blocked chords come from the saved
   configuration (`SecureInputBlockedShortcuts`): Option/Shift-only Carbon
   combos, plus any modifiers of a hold-combo Drop (event tap). Every Carbon
   and modifier-only shortcut records its arrival in `HotkeyFireRecorder`, even
   when a gate then drops it, so a shortcut that worked is never blamed.
   A bare key or Space produces no event at all and cannot be noticed; the
   dimmed logo below covers that case when the holder is in the background.
3. **Track the holder ourselves.** `SecureInputHolderTracker` remembers the
   app the person left when secure input was on while that app was still in
   front and still on 0.4 s after the switch (time for a well-behaved app to
   release). "While still in front" comes from the modifier change that
   starts Cmd-Tab (⌘ goes down before the switch); a mouse switch uses the
   reading at activation. So an app that turns secure input on as it comes
   forward (Terminal's Secure Keyboard Entry, a focused key field) never makes
   the app left behind look guilty. The frontmost app is the holder instead
   when its focused element is a password field (Accessibility role
   `AXSecureTextField`, both calls with a 0.2 s timeout, asked only on an
   attempt or a switch and never by the 1 s check; Whytap's own windows are
   read in-process), and then the remembered app is forgotten; or when no
   switch happened since secure input came on.
4. **Show it next to the island.** A non-activating panel to the right of the
   island shows a black capsule with the holder's logo
   (`NSRunningApplication.icon`). The window is exactly the pill (a circle,
   growing rightward on hover to fit the label), because a window that
   accepts the mouse eats clicks wherever its content does not hit-test; the
   shake moves the window frame, as the login window does. A failed attempt
   plays the macOS wrong-password shake and brings it to full strength; when
   the holder is the frontmost app the badge fades after 2.8 s. Typing in the
   frontmost app's own password field (⌥ letters, a ⌘ chord of a hold-combo
   Drop) shakes nothing. A background holder keeps a
   dimmed logo there until secure input ends; a 1 s check runs only in that
   state. Hovering shows one line: "Dia holds secure input — close its
   password field". Reduce Motion replaces the shake with the brightness
   change alone. Screenshot protection applies to the panel like the
   notification panel.
5. **Whytap itself or nobody known.** When the holder is Whytap (its own key
   or Case password field), nothing is shown; only `secure_input_attempt
   holder=self` is logged, since its field releases secure input when it loses
   focus. When secure input is on but the remembered app has quit, the badge
   shows a lock and "Another app holds secure input — close its password
   field". When secure input ends, the badge leaves.

Logs carry the holder's bundle ID as private data and never keys or chords.

## Tested

`SecureInputGuardTests` (23 scenarios): no secure input; background holder
after Cmd-Tab (dimmed logo, then shake); frontmost holder (shake, no poll);
password field in the frontmost app wins over the remembered one and the 1 s
check keeps that verdict; typing in the front password field never shakes;
an app turning secure input on as it comes forward does not blame the app
left; Accessibility asked only on attempts and switches, never by the 1 s
check; no 1 s check for a holder that quit; holder releases (poll and on a
modifier press); holder quits while secure input stays (lock); an app that
releases while being left is never blamed; switching back to the holder;
Whytap's own field, in front and remembered; a shortcut that arrived; ⌘/⌃
chords; long holds; shake throttling; blocked chords from the configuration
including a hold-combo Drop; chord conversions; Carbon arrival recorded even
when suppressed. An independent review of the first version found the
click-eating panel margin, the blame of the app left behind, the 1 s check
undoing the Accessibility verdict and shakes while typing a password; all four
are fixed above and covered by the scenarios.

## Rejected

- `kCGSSessionSecureInputPID` / `ioreg` as the owner: names the frontmost app.
- Reading keys through IOHID while secure input is on: that is the bypass the
  protection exists to stop.
- Moving Option-only shortcuts to ⌃⌥ automatically: changes the person's
  shortcuts without asking (invariant: nothing switches on its own).
- Shaking on every Option press while secure input is on: blames normal
  typing in the frontmost password field and in other apps; the detector
  requires a blocked chord, a short hold and no arrival.
- A permanent polling timer: the 1 s check runs only while a background
  holder is remembered.

2026-11-26 · PR: see the commit that adds this file.
