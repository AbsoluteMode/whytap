# Troubleshooting

Live-debugged issues whose root cause was non-obvious, kept so the next person
(or the next session) does not re-derive them. Each entry: symptom, root
cause, what did NOT work, the fix, and — where it earned its keep — the
diagnosis technique.

---

## Island answer ✕ does nothing on click (only Esc closes)

**Symptom.** The Dynamic Island agent answer panel shows a ✕ close control.
Clicking it does nothing; the panel only closes via Esc. Reproduces reliably
when Whytap is NOT the active app (the user invoked the agent from another app
and is reading the answer there).

**Root cause.** The island is an `NSPanel` with `[.borderless,
.nonactivatingPanel]` that is intentionally never key while an answer is on
screen (`canBecomeKey` is true only while the composing field needs the
keyboard). With Whytap inactive and the panel non-key, AppKit treats the click
as a window-activating "first mouse" click and the AppKit→SwiftUI event bridge
**drops it before any SwiftUI gesture sees it.** Esc is unaffected because it
is a global Carbon hotkey (`AgentResponseCloseHotkey`), independent of
key/first-mouse state.

**What did NOT work (don't retry these):**

1. `override func acceptsFirstMouse(for:) -> Bool { true }` on the
   `NSHostingView` subclass (`ClickThroughHostingView`). AppKit consults
   `acceptsFirstMouse` on the view `hitTest` *returns*, which for SwiftUI
   content is an internal SwiftUI view — not the hosting view — so the
   override is never reached.
2. An `acceptsFirstMouse`-true `NSView` bridged in via `NSViewRepresentable`
   and overlaid on the ✕ (a "first-mouse catcher"). Its `mouseDown` **never
   fired** — the bridge drops the click upstream of the hosted NSView too.

Both were verified dead by the trace below (the catcher's `mouseDown` log line
never appeared; the SwiftUI button action never appeared).

**The fix.** Intercept the click geometrically at the **window** level, the one
layer the trace proves always runs. `IslandPanel.sendEvent(_:)` checks each
`leftMouseDown`: while the agent answer is visible, if the location is inside
`IslandAgentHitZones.answerCloseHotspot` (a control-sized box at the answer
panel's top-right, with a few points of slop), it calls the dismiss closure and
returns without forwarding. The ✕ stays a SwiftUI `Button` for the visual +
VoiceOver label; its action is a harmless fallback. The hotspot rect is pinned
by `IslandAgentHitZonesTests.test_answerCloseHotspot_coversRenderedCloseCluster`
against a real traced click coordinate, so a layout change that moves the ✕
fails the test instead of silently breaking the click.

Files: `Sources/Sidekey/DynamicIsland/IslandPanel.swift`
(`sendEvent`, `IslandAgentHitZones.answerCloseHotspot`),
`Sources/Sidekey/DynamicIsland/IslandAgentAnswerPanelView.swift` (the ✕ visual).

**Known related limitation.** Other hosted controls in the answer panel (e.g.
the useful-links chips) are reached by the same dropped-first-mouse path, so a
direct *click* on them may not register while Whytap is inactive. They are
driven by keyboard instead (bare arrows: Insert ←, Open →, Next ↓, Prev ↑). If
click support for them is ever needed, give each its own window-level hotspot —
do not reach again for `acceptsFirstMouse`.

**Diagnosis technique (reusable for "click does nothing" in the island).**

`log show` returns nothing for the dev build, so unified-logging
instrumentation is invisible here. Use a **file-backed trace** plus
**synthetic CGEvent clicks**:

1. Add a `clickdbg(_:)` that appends a timestamped line to
   `/tmp/whytap_clickdbg.log`, and call it from each layer you want to prove:
   `NSWindow.sendEvent` (did the event reach the window? what are
   `ignoresMouseEvents` / `isKeyWindow`?), `hitTest` (accepted? what view did
   it resolve to?), the control's action, and any catcher's `mouseDown`.
2. Find the island window id + bounds with the
   `CGWindowListCopyWindowInfo` prober (`/tmp/island_winlist.swift`, set the
   pid). Layer-1000, on-screen, non-empty bounds is the island.
3. Post a real click with a tiny CGEvent script: `mouseMoved` to the target
   first (so the app's `NSEvent.mouseLocation`-based mouse routing un-ignores
   the region), then `leftMouseDown` + `leftMouseUp`. Coordinates are
   bottom-left origin.
4. Read `/tmp/whytap_clickdbg.log` and see exactly which layers fired. Here it
   showed `sendEvent` + `hitTest` firing but nothing downstream — pinning the
   fix to the window level.

Remember to strip the instrumentation before the PR (it is not behind a flag).
