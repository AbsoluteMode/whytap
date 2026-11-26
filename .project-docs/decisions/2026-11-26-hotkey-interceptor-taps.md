---
id: hotkey-interceptor-taps-2026-11-26
type: decision
title: Whytap names the app whose event tap swallows a modifier shortcut
summary: An app such as Punto Switcher bound to Right Option swallows the press with its own event tap and Whytap's Google search silently does nothing. A HID-level probe (flagsChanged only, Accessibility, passes every event) sees the physical press; when Whytap's NSEvent shortcut monitors never see that key held, the press was lost in between. Only then the public tap list names the other app's enabled active flagsChanged filter, and its logo shakes beside the island in the Secure Input badge. Never Whytap, never Apple, never a listen-only tap. The logo leaves when that filter goes or the key reaches Whytap again.
status: confirmed
tags: [hotkeys, event-tap, island, punto-switcher, accessibility]
canonical_for: [hotkey-interceptor-indicator]
verified_at: 2026-11-26
sources:
  - type: user-confirmed
    reference: The maintainer's Google search on Right Option silently did nothing; the cause was Punto Switcher intercepting Right Option. He asked that the Secure Input indicator also point at apps intercepting Whytap's hotkeys with their own taps (orchestrator task 45).
    confirmed_at: 2026-11-26
  - type: trace
    reference: CGGetEventTapList and CGEvent.tapCreate probes run from an untrusted helper on the maintainer's Mac (macOS 27.3), 2026-11-26; results in the Measured section.
    confirmed_at: 2026-11-26
  - type: repository
    reference: Sources/Sidekey/Hotkeys/HotkeyInterception.swift
    confirmed_at: 2026-11-26
  - type: repository
    reference: Sources/Sidekey/Hotkeys/HotkeyInterceptionGuard.swift
    confirmed_at: 2026-11-26
  - type: repository
    reference: Sources/Sidekey/Hotkeys/HotkeyPressProbe.swift
    confirmed_at: 2026-11-26
  - type: repository
    reference: Sources/Sidekey/DynamicIsland/HotkeyBlockerBadgeStack.swift
    confirmed_at: 2026-11-26
  - type: repository
    reference: Tests/SidekeyTests/Hotkeys/HotkeyInterceptionTests.swift
    confirmed_at: 2026-11-26
related: [2026-11-26-secure-input-holder.md]
---

# Whytap names the app whose event tap swallows a modifier shortcut

## Context

The maintainer's Google search (Right Option tap/hold) did nothing, with no
sign why. Punto Switcher, the layout switcher, was intercepting Right Option.
The Secure Input badge ([decision](2026-11-26-secure-input-holder.md)) cannot
catch it: secure input was off, and the key never reached Whytap at all.

## Measured (macOS 27.3, 2026-11-26)

- **`CGGetEventTapList`** needs no permission and returns, per tap: id,
  location (`HID`, `Session`, `AnnotatedSession`), options (`default` = active
  filter that may drop or rewrite, `listenOnly`), `enabled`, the tapping pid,
  the tapped pid (0 = all events), the `eventsOfInterest` mask and
  min/avg/max latency. On this Mac: Raycast holds an active **HID** filter on
  keyDown only; Siri and SiriNCService hold active session filters on keyDown,
  keyUp and flagsChanged; ViewBridgeAuxiliary and an unbundled process hold
  listen-only taps; Whytap holds its own. The latency fields stayed at
  implausible constants (2.1·10⁷ to 3.9·10⁹ µs) and say nothing about whether
  a tap handles events now; they are not used. Ids are not ordered.
- **What the list cannot say:** what a filter does with an event, or which
  keys it cares about inside its mask. A layout switcher needs keyDown for
  its own features, so "app X has an active keyboard filter" alone would
  blame Raycast, BetterTouchTool or Alfred for every miss.
- **Permissions** (untrusted helper): an active filter tap fails to create
  at HID and at session level without Accessibility; a listen-only tap is
  created but disabled (Input Monitoring). Whytap's `SpaceHoldMonitor` and
  Brightness keys already run active session taps on Accessibility.
- **Order:** HID taps run before session taps; within a location a
  head-inserted tap runs first, so a later head insertion goes in front of
  it. Every Whytap modifier shortcut (`RightCmdGestureMonitor`,
  `ModifierOnlyHotkeyMonitor`) listens through `NSEvent` monitors, which see
  an event only after all taps.
- **Punto Switcher 2.1.5** (`ru.yandex.desktop.PuntoSwitcher`) imports
  `CGEventTapCreate`, `CGEventSetFlags`, `CGEventPost` and
  `TISSelectInputSource`: it can drop a modifier press, rewrite its flags or
  post its own events. It was not running during the measurement, so its tap
  location and mask were not observed; the design below does not depend on
  them.

## Decision

1. **Exact signal, not a guess.** `HotkeyPressProbe` is an active HID tap,
   head-inserted, on `flagsChanged` only, on its own thread, which returns
   every event untouched. It reads only which modifiers are down and the
   posting pid, to skip Whytap's own posted events. It runs on
   Accessibility, as the other taps do; no Input Monitoring request. It
   exists only while a modifier key is bound to a switched-on shortcut
   (Right ⌘ Agent, Right ⌥ Google, a modifier Drop or tool).
2. **Lost press.** `HotkeyInterceptionDetector` compares, per watched key,
   the press the probe saw with the `NSEvent` view: if Whytap's monitors
   never saw that key held (dropped, or its right-side flag rewritten), the
   press was lost between the two. Each side records system uptime when it
   handled the event; the probe runs first, so the order on the main thread
   does not matter. A tap is judged 0.3 s after its release, a hold 0.5 s
   after the press; a judgement that runs late because the main thread was
   busy waits again (up to three times), since the delivered event may still
   be queued.
3. **Name the interceptor only on that signal.** On a lost press the tap
   list is read: candidates are enabled active filters with flagsChanged in
   their mask, owned by another process, global or filtering the frontmost
   app. Whytap's own and Apple's processes (`com.apple.*`, `/System`,
   `/usr`) are never named; Siri keeps such a filter on every Mac. HID
   filters come first. No candidate: nothing shown, one log line. On a locked
   screen or another console session nothing is judged.
4. **Show it in the Secure Input badge.** The interceptor's logo appears to
   the right of the island and shakes; hovering reads "Punto Switcher is
   intercepting Right Option — change the key in one of the apps" (two
   candidates: "A or B", more: "A or another app"). It stays dimmed, with a
   2 s check of the tap list while it is up, until that app has no such
   filter, the key reaches Whytap again (the person moved one of the keys) or
   the key stops being a Whytap shortcut. Shakes are at least 0.6 s apart.
   `HotkeyBlockerBadgeStack` lets both guards share the one panel: the latest
   badge shows, and when it leaves, the other guard's persistent badge comes
   back dimmed; neither guard dismisses the other's badge.
5. **Keep the probe in front.** A HID filter installed after the probe runs
   before it and could hide the press from it. After any app launches
   (3 s later) and on every 2 s check, a new HID modifier filter of another
   process reinstalls the probe at the head.

Logs carry the interceptor's bundle ID as private data and never a key or a
flag.

## Cannot be detected

- A remap below the taps (Karabiner-Elements' virtual keyboard, `hidutil`):
  the probe already sees the remapped key, so no Right ⌥ was pressed as far
  as macOS is concerned.
- Carbon combos (⌥F) and hold-Space: catching their loss needs keyDown in
  the HID probe, which would read every key typed on the Mac; rejected.
- An app that lets Right ⌥ through but posts its own events that cancel the
  gesture (as a layout switcher might): the key arrives, so nothing is lost.
- A HID filter installed after the probe by a process that never posts a
  launch notification, until the next 2 s check while a logo is up.
- Which key an app is configured to take (Punto's switch key): its settings
  are not read.

## Tested

`HotkeyInterceptionTests` (28) and `HotkeyBlockerBadgeStackTests` (5), with fake tap
lists, probe, clock and presenter: tap-list parsing and classification (own,
Apple, listen-only, disabled, keyDown-only, per-process taps, HID first, one
entry per app, the measured tap list of this Mac stays silent); detector
(delivered, swallowed, rewritten flags, delivery handled first, a stale
delivery, a long hold, an unwatched key); guard (Punto swallowing Right ⌥
shakes its named logo, a delivered press or benign taps or a locked screen
show nothing, the logo leaves when Punto's tap goes, when the key arrives
again or when Google is switched off, the probe stops without modifier
shortcuts, is retried 30 s after failing and moves back to the head, a busy
main thread defers the verdict, shake throttling, a hold is judged while
held); badge stack (no window until a badge, the covered badge comes back,
neither guard dismisses the other's, a faded shake restores the dimmed one).

Not verified live: a real Punto Switcher press and the HID tap's added
latency. A press made while Whytap's own menu is tracking may not reach its
local `NSEvent` monitor; with an interceptor running, that press could name it.

## Rejected

- Blaming any app with an active keyboard filter when a shortcut does not
  fire: Raycast, Siri and others hold one permanently; it would be wrong most
  of the time.
- A listen-only probe: needs Input Monitoring, which Whytap asks for only
  as a fallback.
- A HID probe on keyDown too, for combos and Space: reads every key on the
  Mac for a diagnostic.
- The latency fields of the tap list as an activity signal: constant on
  idle taps.
- Reading Punto Switcher's or other apps' settings to predict conflicts:
  private configuration of another app.
- A permanent polling timer: the 2 s check runs only while a logo is up.

2026-11-26 · PR: see the commit that adds this file.
