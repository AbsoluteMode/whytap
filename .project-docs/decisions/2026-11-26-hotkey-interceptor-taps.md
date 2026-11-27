---
id: hotkey-interceptor-taps-2026-11-26
type: decision
title: Whytap names the app whose event tap swallows a modifier shortcut
summary: An app such as Punto Switcher bound to Right Option swallows the press with its own event tap and Whytap's Google search silently does nothing. A HID-level probe (flagsChanged only, Accessibility, passes every event) sees the physical press; when Whytap's NSEvent shortcut monitors never see that same press (matched per press by event timestamp, only presses of the key alone) the press was lost in between. Only then the public tap list names, as possible interceptors, the owners of enabled active flagsChanged filters that existed when the press began with the same app in front; the logo shakes beside the island in the Secure Input badge for about 3 s, then hides, and every new lost press shows it again. Never Whytap, never Apple, never a listen-only tap.
status: confirmed
tags: [hotkeys, event-tap, island, punto-switcher, accessibility]
canonical_for: [hotkey-interceptor-indicator]
verified_at: 2026-11-27
sources:
  - type: user-confirmed
    reference: Spec REV 1 (2026-11-26) from the maintainer - the interceptor's logo must not stay dimmed; on a blocked press it shows with the shake and highlight for about 3 s, then hides, and every new blocked press shows it again and restarts the time. Secure Input's badge keeps its own behaviour.
    confirmed_at: 2026-11-26
  - type: user-confirmed
    reference: The maintainer's Google search on Right Option silently did nothing; the cause was Punto Switcher intercepting Right Option. He asked that the Secure Input indicator also point at apps intercepting Whytap's hotkeys with their own taps (orchestrator task 45).
    confirmed_at: 2026-11-26
  - type: trace
    reference: Builder review of build queue ticket 624 (PR 492 head 109ffcd7, merged onto 85d4d931) - four findings on press/deadline matching, tap and settings lifecycle, shortcut eligibility and attribution, and clipped hover text, with five failing detector assertions.
    confirmed_at: 2026-11-27
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
related: []
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
  implausible constants (about 2e7 to 4e9 microseconds) and say nothing about whether
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
   posting pid, to skip Whytap's own posted events, and the event's own
   timestamp. It runs on Accessibility, as the other taps do; no Input
   Monitoring request. It exists exactly while a modifier key is bound to a
   switched-on shortcut (Right ⌘ Agent, Right ⌥ Google, a modifier Drop or
   tool) and the session is interactive. The guard follows shortcut changes
   (`HotkeyPreferences`), capability switches
   (`sidekeyCapabilityFlagsChanged`), Accessibility trust changes
   (`com.apple.accessibility.api`, retried at once), screen lock/unlock and
   session switches, so the very first press after Google search is switched
   on is already watched, and switching it off removes the tap at once.
   Every install or stop bumps a generation: a callback an earlier tap
   already dispatched, and any verdict still pending, is discarded.
2. **Lost press, matched per press.** `HotkeyInterceptionDetector` keeps
   one record per physical press. It is matched only with a delivered press
   of the same key whose event timestamp is the same hardware event (within
   2 ms), or lies inside that press's own down-to-up interval (an app that
   swallows and re-posts the key while it is held). A later delivered press
   never covers an earlier lost one. The delivered side keeps every event
   with the key down alone by its event time, with no delivered press
   boundaries of its own: a release that never reached the monitors cannot
   hide the next press; which press an event belongs to is decided by the
   physical boundaries alone. Both sides use the events' own
   timestamps, so a busy main thread does not change the match; deadlines
   use main-thread time. A released press is judged 0.3 s after the release
   was seen, never earlier by the 0.5 s hold deadline; a press still held is
   judged 0.5 s after it began. A judgement that runs late because the main
   thread was busy waits again (up to three times), and a delivery handled
   after a blocked verdict takes the badge back. Records older than 30 s
   (a release the probe never saw) are dropped.
3. **Only presses the real monitors would take.** A press begins only when
   its key goes down alone (`HotkeyFlags.isOnly`, the rule of
   `ModifierOnlyHotkeyMonitor` and the gesture state machine): Shift+Right ⌥
   or both Options start nothing, and a press that gains another modifier
   while held is retired unjudged, as the gesture monitors cancel it. A key
   that stops being a shortcut retires its held and pending presses at once,
   even while another watched key keeps the tap installed; a press still held
   then starts nothing new until it is released. The time each key's binding
   last changed is kept, so a press the probe saw before that moment, whose
   callback only reaches the main thread afterwards, belongs to the former
   binding and is never judged; another key's binding change does not touch
   it. The shortcut preferences are read on the main thread's next turn
   after a write, while the probe runs on its own thread, so for a key that
   becomes a shortcut the boundary is not the sync's time but the moment
   the preference was written (`bindingsWillChange`): the first press after
   enabling Right Option is judged whether its callback runs before or after
   that deferred sync, and a press before the write is not. A key that
   stops being a shortcut keeps the sync's time, so a press seen while the
   removal was still queued is retired. The write time is recorded by the
   preference observer as the write happens, before any probe callback that
   was already queued runs, and every press is judged by its own event time
   against that boundary, never by callback order: a press 5 ms before the
   write is retired even when its callback runs after the write and before
   the deferred sync. A key that became watched with no recorded write is
   not judged until the sync.
4. **Name possible interceptors only on that signal, in the press's own
   context.** When a press begins, the frontmost app and the exact filters
   (tap ids) that could act on it are recorded. Both are read when the
   probe's callback reaches the main thread; if both reads have not
   finished within 50 ms after the probe saw the event, they may describe a
   later moment, so the press is not attributed at all (the limit is checked
   after the reads, not before). A tap that replaces another one of the
   same app gets a new id and inherits nothing. On a lost press the
   tap list is read again: candidates are enabled active filters with
   flagsChanged in their mask, owned by another process, global or filtering
   the frontmost app, that are the very taps recorded when the press began. If another
   app came to the front in between, nothing is shown. The tap list proves
   which apps could have taken the press, not which one did, so the text
   names them as possible interceptors: "Punto Switcher may be intercepting
   Right Option". Whytap's own and Apple's processes (`com.apple.*`, `/System`,
   `/usr`) are never named; Siri keeps such a filter on every Mac. HID
   filters come first. No candidate: nothing shown, one log line. On a locked
   screen or another console session nothing is judged.
5. **Show it in the Secure Input badge.** The interceptor's logo appears to
   the right of the island and shakes; hovering reads "Punto Switcher may be
   intercepting Right Option" (two candidates: "A or B may be intercepting
   ...", more: "A or another app may be intercepting ..."). When the hover
   label does not fit on one line between the island and the screen's right
   margin, it wraps and the pill grows downward
   (`SecureInputHolderMetrics.layout`), so the whole text stays readable on
   small displays; the accessibility label is always the full text. This
   applies to Secure Input's label too. **It never stays dimmed
   (maintainer's REV 1):** it is presented as a transient badge, shaken and
   at full strength, and the panel hides it after its emphasis time (2.8 s,
   plus a 0.25 s fade: about 3 s; a hover keeps it while the label is read).
   Every new lost press presents it again with a shake, which restarts that
   time; there is no throttle and no polling.
   `HotkeyBlockerBadgeStack` lets both guards share the one panel: the latest
   badge shows, and when it leaves, the other guard's persistent badge comes
   back dimmed; neither guard dismisses the other's badge. So while Secure
   Input's dimmed logo is up, an interceptor shake covers it for about 3 s and
   then it returns; Secure Input's own behaviour is unchanged. A transient
   badge that another one covers is over and never comes back.
6. **Keep the probe in front.** A HID filter installed after the probe runs
   before it and could hide the press from it. After any app launches
   (3 s later) and, at most every 10 s, on a modifier change Whytap receives,
   a new HID modifier filter of another process reinstalls the probe at the
   head.

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
  launch notification, for up to 10 s (until the next head check).
- Which key an app is configured to take (Punto's switch key): its settings
  are not read.

## Tested

`HotkeyInterceptionTests` (60) and `HotkeyBlockerBadgeStackTests` (7), with fake tap
lists, probe, clock and presenter: tap-list parsing and classification (own,
Apple, listen-only, disabled, keyDown-only, per-process taps, HID first, one
entry per app, the measured tap list of this Mac stays silent); detector
(delivered, swallowed, rewritten flags, delivery handled first, a release
waits for its own grace, a delivery during that grace resolves it, a later
delivered press never covers an earlier lost one, a re-posted press inside
the hold, a late delivery reverses a verdict, Shift+Right ⌥ and both
Options, a long hold, an unwatched key, reset retires released presses);
context (a changed frontmost app, a filter installed after the press began);
guard (Punto swallowing Right ⌥
shakes its named logo as a transient badge, every lost press presents it
again, a delivered press or benign taps or a locked screen show nothing, the
probe stops without modifier shortcuts, is retried 30 s after failing and
moves back to the head after a launch or a 10 s head check, a busy main
thread defers the verdict, a hold is judged while held, Shift+Right ⌥
never shakes, a locked session has no probe, a callback from a stopped probe
is discarded, the first modifier binding installs the probe and the last
removes it, an Accessibility grant retries at once, a late delivery takes
the badge back); hover text (a two-candidate label wraps within a narrow
width and the pill is tall enough for every line); badge stack (no
window until a badge, the covered badge comes back, neither guard dismisses
the other's, a faded shake restores the dimmed one, the interceptor's
transient badge over Secure Input's dimmed logo, a covered transient badge
never returns).

The builder's review of the first head (queue ticket 624) found: a released
press judged by the hold deadline before its release grace, a later delivered
press covering an earlier lost one, a released press from a stopped probe
still reporting, bindings followed only on delivered modifiers, Shift+Right
⌥ starting an Option-only candidate, candidates read without the press's
context, and a two-candidate label (575 pt) running off small displays. Its
five failing detector assertions are scenarios above; points 1 to 5 answer
each finding. Its second review (ticket 686) found three remaining cases: a
delivered release that never arrived hid the next press, a key unbound
while another watched key kept the tap left its pending press alive, and
attribution intersected owner pids (a replacement tap inherited the old
one's context) and read the context on a late callback. Its four
regressions (`testQueueReview...`) are in the suite, with neighbours of
each class: no delivered releases at all around a lost press, a delivered
chord with Shift, unbinding and rebinding while held, a late callback of a
hold, the same tap id surviving the verdict. Its third review (ticket 691)
found the same two classes once more: a press observed before its key was
unbound and rebound, whose callback was still queued for the main thread,
presented under the new binding; and the 50 ms freshness check ran before
the frontmost and tap-list reads, so a slow read could supply a filter
installed after the press. Its two regressions (`testBuilder691...`) are in
the suite, with neighbours: another key's binding change keeps the press, a
press after the rebind is judged, a slow frontmost read supplies no
context. Its fourth review (ticket 699) found that boundary too strict in
the other direction: with Right Command keeping the probe alive, enabling
Right Option and pressing it before the deferred sync ran retired a valid
first press. Its regression (`testBuilder699...`) is in the suite, with the
timing class: a press after the write with its callback before or after the
sync is judged, a press before the write is not, and a removal still
retires a press seen while its sync was queued. Its fifth review (ticket
705) found the remaining order: a pre-write press whose callback, queued
before the preference handler, ran after the write but before the sync was
still judged. Its regression (`testBuilder705...`) is in the suite; the
timing matrix now covers both callback orders before and after the write,
and a newly watched key with no recorded write. Removing the eligibility or frontmost-context checks fails
those scenarios (checked by mutation).

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
- A permanent polling timer: the probe's head check rides on modifier
  changes Whytap receives anyway, at most every 10 s.
- Keeping the interceptor's logo dimmed until its filter goes (first
  version): replaced by the maintainer's REV 1, since a layout switcher runs
  all the time and the logo would never leave.

2026-11-26 · PR: see the commit that adds this file.
