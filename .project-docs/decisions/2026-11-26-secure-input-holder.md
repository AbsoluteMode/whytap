---
id: secure-input-holder-2026-11-26
type: decision
title: Whytap points at the app holding Secure Input instead of letting shortcuts die silently
summary: While another app holds Secure Event Input, macOS drops Whytap's event-tap keys and Option-only Carbon shortcuts. Whytap cannot get around that and does not try. A background app that keeps secure input after Cmd-Tab gets its dimmed logo to the right of the island until it lets go, and the logo shakes when a blocked shortcut's chord is pressed (an approximation, since the key is never seen). Nothing shakes while the frontmost app holds secure input. The holder is tracked by Whytap itself, because macOS reports the frontmost app as the owner.
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
   so `SecureInputAttemptDetector` takes "a chord of a blocked shortcut was
   held for at most 3 s and released" as a candidate, and 0.3 s after the
   release (Google's Right ⌥ tap fires up to 0.12 s after it) treats it as a
   possible failed attempt unless a Whytap shortcut arrived since the hold
   began, with 0.05 s of slack because two observers of one modifier event
   run in either order (see 5 for when it shakes). Blocked chords come from
   the saved configuration (`SecureInputBlockedShortcuts`): Option/Shift-only
   Carbon combos, plus any modifiers of a hold-combo Drop (event tap).
   `HotkeyFireRecorder` records an arrival from every Carbon and
   modifier-only shortcut, even when a gate then drops it, and from Right ⌘ /
   Right ⌥ only when the gesture state machine accepts a gesture (a Right ⌥
   cancelled by Shift records nothing). A bare key or Space produces no event
   at all and cannot be noticed; the dimmed logo below covers that case when
   the holder is in the background.
3. **Track the holder ourselves.** `SecureInputHolderTracker` remembers the
   app the person left when secure input was on while that app was still in
   front and still on 0.4 s after the switch (time for a well-behaved app to
   release). The only evidence of "while still in front" is a keyboard
   switch: secure input read when ⌘ went down with the old app in front and
   again when it came up, used once, for the next switch, if no click
   happened since ⌘ went down and the switch comes while ⌘ is held (⌘H) or
   at most 0.5 s after its release. Cmd-Tab commits on the release, so its
   activation normally arrives just after ⌘ up; both orders are accepted
   because the real order was not measured, and a long look at the switcher
   still counts. The click monitor notes only that a click happened and its
   event time (`NSEvent.timestamp`), never where: a click that physically
   happened before an activation was handled caused that switch, so it voids
   the evidence the switch captured even when the activation callback was
   delivered first; a later click in the new app does not. A remembered app
   that comes back to front is forgotten, since it may let go unseen while in
   front; leaving it again needs new evidence. A chord still in its 0.3 s
   window, like a switch still settling, belongs to the episode it began in:
   an OFF read in between discards it. A click or Dock
   switch, with or without ⌘ held, has no evidence, so nobody is named: an
   attempt shows the lock. Any OFF read (a modifier press or release, the
   settling read, the reads when an attempt is decided and resolved, the 1 s
   check) turns a held ⌘ reading into OFF, voids a switch still settling,
   forgets every remembered holder and dismisses every badge. So an app that
   turns secure input on as it comes forward after the old one let go
   (Terminal's Secure Keyboard Entry, a focused key field) never makes the
   app left behind look guilty. One case stays ambiguous and is accepted:
   Cmd-Tab from an app that holds secure input to one that turns it on at
   once, with no OFF in between that Whytap could read, names the app left.
   A second accepted limit: with Google on Right ⌥ (the default), Right ⌥+F
   under secure input looks exactly like a Right ⌥ tap, since the F is never
   seen; Google answers and nothing shakes. Left ⌥+F is unaffected. And
   arrivals are global: any Whytap shortcut arriving within the 0.3 s window
   (say a ⌃ shortcut right after) also keeps an ⌥ chord from shaking. A
   remembered app back in front is forgotten rather than polled.
   The frontmost app is the holder instead when its focused element is a
   password field (Accessibility role `AXSecureTextField`, both calls with a
   0.2 s timeout, asked on an attempt or a switch whenever a remembered or
   unknown owner is in question, never by the 1 s check; Whytap's own windows
   are read in-process), and then nothing remembered is kept; or when no
   switch happened since secure input came on.
4. **Show it next to the island.** A non-activating panel to the right of the
   island shows a black capsule with the holder's logo
   (`NSRunningApplication.icon`). The window is exactly the pill (a circle,
   growing rightward on hover to fit the label), because a window that
   accepts the mouse eats clicks wherever its content does not hit-test; the
   shake moves the window frame, as the login window does. A failed attempt
   plays the macOS wrong-password shake and brings it to full strength. The
   badge follows the island's display (screen-parameter and display-selection
   notifications, as the Notify panel) and the Settings screenshot-protection
   switch reaches it while it is up, as for `IslandPanel`.
5. **Shake only while the keyboard is stuck.** The key is never seen, so a
   bare ⌥ tap, ⌥ with an ordinary key and ⌥F look the same. While the
   frontmost app holds secure input the chord is most likely typing in its
   password field (⌥ letters, a ⌘ chord of a hold-combo Drop), so nothing
   shakes; that case stays silent, as before. While a background holder is
   named (its dimmed logo already up) or the holder is unknown, the chord
   shakes the badge, bare ⌥ taps included: the approximation only draws
   attention to a badge whose claim, "the keyboard is held", is true. A background holder keeps a
   dimmed logo there until secure input ends; a 1 s check runs only in that
   state. Hovering shows one line: "Dia holds secure input — close its
   password field". Reduce Motion replaces the shake with the brightness
   change alone. Screenshot protection applies to the panel like the
   notification panel.
6. **Whytap itself or nobody known.** When the holder is Whytap (its own key
   or Case password field), nothing is shown; only `secure_input_attempt
   holder=self` is logged, since its field releases secure input when it loses
   focus. When secure input is on but the remembered app has quit, the badge
   shows a lock and "Another app holds secure input — close its password
   field". When secure input is seen off, every badge leaves at once, a shaken
   or hovered one included; a shaken badge is watched by the 1 s check until it
   fades.

Logs carry the holder's bundle ID as private data and never keys or chords.

## Tested

`SecureInputGuardTests` (28 scenarios) and `SecureInputHolderPanelTests` (4): no secure input; background holder
after Cmd-Tab (dimmed logo, then shake); frontmost holder (no shake, no poll);
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
are fixed above and covered by the scenarios. The builder's synthetic probes
of that version (queue ticket #613) found: a mouse switch and an OFF read on a
modifier press could still name the wrong app; a bare ⌥ tap shook the logo
with no shortcut pressed; a shaken badge outlived secure input; a visible
badge missed the screenshot-protection switch and display changes. Points 3
to 6 above answer them, each with a scenario (mouse switch, OFF while a
modifier is down, bare ⌥ in the stuck state, front holder never shakes,
confirmed OFF removes a shaken lock, protection and display while up). Its
second pass (ticket #614) found a click within 1.5 s of an unrelated ⌘ press
still used as evidence, an OFF before the settle not voiding it, the unknown
owner skipping the front-field check (other apps and Whytap's own key field)
and an OFF read while resolving an attempt leaving the badge up; point 3 now
covers each, with a scenario apiece. Its third pass (ticket #615) found a click
or Dock activation while an unrelated ⌘ was held taken for Cmd-Tab, an OFF
read while ⌘ stayed down not voiding the held reading, and Right ⌘ / Right ⌥
recorded at modifier-down rather than on an accepted gesture (a Shift-
cancelled Right ⌥ hid a blocked ⌥⇧ shortcut; in the other observer order a
real Google tap still shook). Points 2 and 3 now cover these: clicks void
the evidence, OFF turns the held reading off, arrivals come from accepted
gestures and are judged 0.3 s after the release with 0.05 s of slack;
scenarios include the real gesture state machine. An independent review
before resubmitting found that Cmd-Tab commits on ⌘ release, so requiring ⌘
held at the switch would have lost the main case; the release window above
fixes it, and the test Cmd-Tab now releases ⌘ before the switch. The fourth
pass (ticket #617) found an activation delivered before the click that caused
it still using ⌘ evidence, a holder back in front kept across an unseen
release, and a chord queued before an OFF shaking the next episode; point 3
now covers all three with scenarios that fail on the previous head.

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
