---
id: brightness-hold-2026-10-28
type: decision
title: Optional brightness hold restores the chosen backlight level
summary: Hold brightness captures the island display's current backlight and restores external changes while awake; Whytap adjustments replace the target, and sleep, heat and failures prevent automatic writes.
status: confirmed
tags: [brightness, display, hold, automatic-brightness, settings]
canonical_for: [brightness-hold]
verified_at: 2026-10-28
sources:
  - type: user-confirmed
    reference: On 2026-10-28 the user reported automatic brightness decreases on another MacBook and asked for Whytap to hold brightness.
    confirmed_at: 2026-10-28
  - type: repository
    reference: Sources/Sidekey/Brightness/ScreenBrightnessController.swift
    confirmed_at: 2026-10-28
  - type: repository
    reference: Tests/SidekeyTests/Brightness/ScreenBrightnessControllerTests.swift
    confirmed_at: 2026-10-28
related: [2026-10-18-brightness-tool.md]
---

# Brightness hold

## Context

Keeping Extra enabled does not keep the underlying backlight steady. The user
still observes automatic dimming on another MacBook. Its cause is unconfirmed;
this feature is an optional backlight policy, not a diagnosis of that Mac.

## Decision and rationale

Hold brightness is off by default and captures the current island display's
level without writing it. A lock next to the hover slider and a switch in
Settings -> Toolbox -> Display control the same session-only state. The chosen
level is restored on the existing half-second poll, even with the panel closed.
This directly addresses the user's request without changing macOS preferences.

The slider and Whytap's optional Brightness keys replace the target. Readback
cannot identify the intent of an external change, so native macOS controls are
also restored while Hold is enabled; unlock to use them. Extra remains separate,
including the first manual decrease consuming Extra without lowering backlight.

Writes settle for 0.75 seconds. A 0.005 tolerance absorbs hardware quantization
but still detects a fine brightness-key step. A refused write or three successive
corrections without a matching readback ends Hold with a visible notice. A later
successful read resets the retry count. This bounds attempts when the requested
level cannot be reached; it cannot guarantee fixed physical luminance.

Display sleep, system sleep and an inactive user session independently pause
reads and automatic writes until their matching wake notifications arrive.
An additional Quartz asleep check prevents Hold from writing a sleeping display
when a notification was missed. No power assertion or screen wake is added.
Serious/critical thermal state ends Hold and Extra; cooling does not restart
them. Display selection changes, disconnection, unreadable hardware and quit end
Hold. It never transfers a target to another display and never persists or
restarts after launch. The last backlight level stays in place when Hold ends.

## Alternatives

- Automatically hold whenever Extra is on: would change the existing boost
  contract and remove automatic backlight adjustment without a separate choice.
- Disable macOS automatic brightness or battery dimming: changes system policy
  outside Whytap and does not address other sources of brightness changes.
- Restore on every timer tick without checking hardware: unnecessary writes
  and an unbounded conflict with unsupported hardware or another controller.

## Sources, comments and resolution

The user request and the controller/tests above establish the feature contract.
The specific cause on the other MacBook remains unknown. No remote inspection,
system preference changes or second-Mac brightness changes were performed.

## Consequences and supersession

Holding a brighter level can use more battery. Physical luminance still depends
on hardware, macOS and thermal limits. This adds an opt-in backlight policy;
the linked brightness-tool decision continues to own Extra and brightness keys.
Native use on the second Mac remains acceptance after delivery.
