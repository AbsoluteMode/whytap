# Hotkey display standard

Single source of truth for how Whytap renders hotkey hints in its UI.

## Component

All hotkey hints route through one SwiftUI component:

- **`HotkeyHintView`** — `Sources/Sidekey/HotkeyHintView.swift`

`HotkeyHintView` composes an optional small label with one or more
keycap chips. The chip itself lives in `KeycapView`
(`Sources/Sidekey/KeycapView.swift`) and is an internal building
block — call `HotkeyHintView`, not `KeycapView`, from product code.

Modifier glyphs and their VoiceOver pronunciations live on
`HotkeyGlyph` (`Sources/Sidekey/HotkeyHintView.swift`).

## Rules

- **Capitalize labels.** Hotkey-context labels (the small text next
  to the keycaps) follow the macOS UI convention: `Help`, `Quit`,
  `Drop`, `Agent`, `Tap`, `Hold`. Never `help` / `quit`. Window
  titles outside the hint surface are not in scope for this rule.
- **No `+` glyph between keys.** Keycaps render side-by-side, each
  in its own cap. The visual separation is the gap between caps,
  not a punctuation glyph.
- **Each key in its own keycap.** A combo of two keys is two
  `KeycapView` chips, not one wide cap with both glyphs inside.
- **Modifier keys as glyphs, not words.** Use
  `HotkeyGlyph.option` (⌥), `HotkeyGlyph.command` (⌘),
  `HotkeyGlyph.shift` (⇧), `HotkeyGlyph.control` (⌃). Never the
  word `"Option"` / `"Command"` etc. as the cap label.
- **Side disambiguation lives INSIDE the keycap.** When a hotkey is
  wired to a specific physical side of a modifier key (e.g. Whytap's
  Agent uses Right Command only), use
  `KeycapContent.prefixedGlyph(prefix: "right", glyph: HotkeyGlyph.command, ...)`
  to bake the qualifier in front of the glyph inside the SAME cap
  (`right ⌘`). The qualifier must not become its own keycap — users
  read separate caps as keys they need to press, so an `R` cap next
  to ⌘ misleads them into trying to press a literal R key. The cap
  auto-widens horizontally to fit the qualifier; the vertical
  envelope stays the canonical 22pt so it sits flush with neighbours.
- **Letters, digits, and special keys as their visible character.**
  `"Q"`, `"H"`, `"/"`, `"1"`. Multi-letter keys spell out the key name
  in a single cap: `"Space"`. The shared `KeycapView` auto-widens a
  multi-character cap horizontally while keeping the canonical 22pt
  vertical envelope, so a wide cap sits flush next to single-glyph caps
  without clipping.
- **Outer chip is part of the standard.** Every `HotkeyHintView`
  renders inside an `.ultraThinMaterial` capsule with a subtle
  black overlay and white border. The chip is built into
  `HotkeyHintView` itself — callers don't add their own background,
  padding, or capsule overlay. The floating Keybindings hint, the
  response panel close row, and every Help window row look
  identical at the chip level for this reason. Two styles opt out
  of the outer capsule: `.keycaps` (each cap draws its own mini
  chip — the Hover-slot hints above the tiles) and `.bare` (loose
  glyphs, an API option with no production callsites today). Both
  still route through `HotkeyHintView`.
- **Every hotkey must appear in the Help window**
  (`Sources/Sidekey/HelpWindowController.swift`). The Help window
  is the canonical place where the user sees every available
  hotkey at a glance. The Help rows are config-driven — they read
  `configuration.dropVoiceShortcut.contents` etc. — so the Drop row
  shows "Hold Space" automatically (no hardcoded glyph).
- **Drop defaults to hold-Space but is user-rebindable.** By default Drop
  is triggered by holding the Space bar (a `CGEventTap` gesture, detected by
  `SpaceHoldMonitor` — not a Carbon `RegisterEventHotKey` combo). Its row in
  Settings → Hotkeys is recordable: the user can assign any combo or bare key,
  or record a bare Space to restore hold-Space. All assignments go through
  `setDropShortcut(_:)`, which applies the Space hold-only rule: Space forces
  `.hold` gesture; other shortcuts keep the user's current gesture choice
  (`.hold` = release-to-stop, `.tap`/Toggle = second-tap-to-stop). The gesture
  switch is live for non-Space bindings and locked on Hold for Space. All Drop
  hint surfaces (Help, onboarding, idle chip, History strip, Dynamic Island
  passive hints, Toolbox caption) source the caps from
  `configuration.dropVoiceShortcut` and the gesture word from
  `configuration.normalizedDropGesture.voiceTitle`, so a rebind propagates
  everywhere from one source of truth.

## Conflict model

Conflicts are detected at the level of the **physical key**, not the raw
`(gesture, key)` pair (`HotkeyBinding.ConflictKey` in
`Sources/Sidekey/Hotkeys/HotkeyPreferences.swift`):

- **Modifier keys (Right ⌘ / Right ⌥) allow a tap/hold split.** Their
  conflict identity includes the gesture, so `tap = Agent text` and
  `hold = Agent voice` on the same modifier coexist. Two modifier bindings
  conflict only when both gesture *and* key match.
- **Ordinary keys / combos / hold-Space are one physical key = one action.**
  Their conflict identity drops the gesture, so binding both a tap and a hold
  to the same ordinary key is reported as a conflict — the two gestures are
  indistinguishable to the user on a non-modifier key. `holdSpace` is its own
  conflict case, deliberately distinct from a `⌥+Space` combo.

A binding is a combination of modifiers + one symbol key. The modifier set
can be any combination of ⌘⌥⌃⇧ (left/right side not significant for combos);
a bare symbol key with no modifiers is valid (bare Space → `.holdSpace`); a
bare single RIGHT modifier (R⌘/R⌥) is also valid as a standalone
`.modifier` binding. Chords like ⌘⇧A (three physical keys) are fully
supported. `HotkeyTapCombo.recorded(from:)` is a separate legacy
modifier-required path (`guard modifiers != 0`), distinct from the Settings
`HotkeyShortcutRecorder`. Multi-key sequences (sequential) remain out of
scope.

## Voice hotkey gestures

Voice bindings (Drop and Agent voice) carry a `HotkeyGesture` that controls
recording lifecycle. The gesture is not the same as the shortcut — it is
stored separately and can be changed in Settings independently of the key.

### Hold vs Toggle

| Gesture | Label (UI) | Behaviour |
|---------|-----------|-----------|
| `.hold` | Hold | Press starts recording; release sends (grace-tail then commit). |
| `.tap`  | Toggle | First press starts recording; second press sends. |

All UI surfaces that display the gesture word for voice bindings must use
`HotkeyGesture.voiceTitle` — `.tap` maps to **"Toggle"** (not "Tap"), because
"Toggle" correctly describes start/stop semantics. `HotkeyGesture.title`
("Tap") is for one-shot actions only. `HotkeysSettingsView.voiceGestureTitle`
delegates to `voiceTitle` (one source of truth).

### Space hold-only rule

Space is **hold-only**: a tap-Space would fire on every typed space, so the
`.tap` gesture is disallowed when the shortcut is `.holdSpace`. The gesture
switch in Settings is locked on Hold for Space and live for all other
shortcuts. `HotkeyConfiguration.normalizedDropGesture` enforces this rule at
read time — stale persisted `.holdSpace`+`.tap` heals to `.hold` without
touching UserDefaults.

### Recorder (Raycast release-to-commit)

The Settings recorder (`HotkeyShortcutRecorder`) uses a Raycast-style
release-to-commit model:

- **Press a combination** — modifiers accumulate as a high-water mask;
  the last non-modifier key pressed becomes the symbol. The field reflects
  the combination in real time while keys are held.
- **Release all keys → commit.** The moment every key and modifier is
  released the combination is committed as a `HotkeyShortcut`. Release is
  the commit signal — it never clears the snapshot (the old model cleared
  the modifier on release, losing the combo).
- **Valid shapes:** bare symbol (no modifiers → modifierless `.combo`, or
  `.holdSpace` for bare Space), bare single RIGHT modifier (R⌘/R⌥ →
  `.modifier`), or modifiers + symbol (any ⌘⌥⌃⇧ combination + one
  keyCode). Left/ambiguous bare modifier with no symbol does not commit
  (field waits for a symbol or right modifier).
- **Escape cancels** the recording without changing the saved binding.
- **Save applies** the draft to the runtime (`apply(draft)`); Revert
  restores the last saved value.
- Trigger matching is by physical **keyCode** (layout-independent).

### Monitor routing

The monitor that handles a voice binding depends on the shortcut type
and the gesture, as determined by `HotkeyShortcutMonitor.isDropHoldTap`:

| Shortcut type | Gesture | Monitor | Effect |
|---------------|---------|---------|--------|
| `.holdSpace` (normalized hold) | hold | `SpaceHoldMonitor` (CGEventTap, Input Monitoring) | Swallows Space; plain typing unaffected by release |
| bare combo (`modifiers == 0`) | hold | `SpaceHoldMonitor` (CGEventTap, Input Monitoring) | Swallows the key on hold; plain taps still type |
| bare combo (`modifiers == 0`) | tap/Toggle | Carbon `RegisterEventHotKey` | Key grabbed globally — **stops typing**; Settings shows a warning |
| modifier combo | hold | `SpaceHoldMonitor` (CGEventTap, Input Monitoring) | Swallows the key on hold |
| modifier combo | tap/Toggle | Carbon `RegisterEventHotKey` | Standard combo registration; modifier key still types normally |
| `.modifier` (R⌘, R⌥) | — | `ModifierOnlyHotkeyMonitor` | Tap/hold split on the same physical key |

`voiceTitle` in display: `.tap` shows as "Toggle" on voice rows;
`HotkeyGesture.rawValue` ("tap"/"hold") is for persistence only, never for UI.

## Hover-slot hotkeys

The five Hover buttons each have a configurable **positional** hotkey
(default ⌥1..⌥5). The binding follows the slot **position**, not the tool:
⌥N activates whatever tool currently occupies `HoverLayoutStore.slots[N-1]`,
so reordering tiles in the Toolbox re-points ⌥N at the new occupant. The five
rows live in Settings → Hotkeys (`hoverSlotSection` in
`HotkeysSettingsView.swift`) and the bindings are
`HotkeyConfiguration.hoverSlot1Shortcut … hoverSlot5Shortcut`.

- **Keycap hint above each button.** Each Hover tile shows its hotkey as a
  `HotkeyHintView(style: .keycaps, size: .tiny)` sitting above it — each
  glyph in its own mini keycap chip, no outer capsule — sourced from
  `configuration.hoverSlot<N>Shortcut.contents` (dynamic — a rebind updates
  the hint). The hint is visible only while the cursor hovers that tile; the
  other tiles hide theirs via `opacity` (not conditional removal), so the
  layout slot above every tile stays reserved and tiles never jump. The fade
  is `easeInOut(0.15s)`, riding the same `hoveredTool` value as the
  description strip below.
- **Activation behaviour** (`AppDelegate.onHoverSlotActivated`): for
  inline-panel tools, ⌥N expands the Hover (only when
  `IslandHoverPolicy.allowsExpansion` — e.g. not during a meeting) and opens
  the tool's sub-panel; for action / navigate tools it runs the effect
  directly without forcing the drawer open. A tile click and its ⌥N hotkey
  share one code path (`HoverSlotRouter`).
- **Slot 5 is the locked Settings slot** (`HoverLayoutStore.lockSlotIndex`):
  the hotkey is editable, but the tool in that position is permanently
  `.settings`.
- Like every other monitor, the keystroke content is never logged — only the
  fact of the trigger (invariant #3).

## Meeting-record hotkey

Manual Meeting Notes recording has a configurable global hotkey (default
⌥M, tap = toggle): press starts a recording immediately — mid-call too,
bypassing the detector nudge (empty pre-record lead-in, detector cooldown
engaged); press again stops it through the regular finalize path. The same
toggle backs the Hover `Record` tile (Toolbox catalog, not in the default
slots) and the "Record a meeting now" button in Settings → Other — all
three converge on `MeetingsCoordinator.toggleManualRecording()`.

- Binding: `HotkeyConfiguration.meetingRecordShortcut`, row in
  Settings → Hotkeys, standard physical-key conflict model, Carbon tap
  registration (`RegisterEventHotKey` — ⌥M stops typing µ while bound).
- Capability off → the standard Take notes / Skip nudge doubles as the
  enable prompt: accepting IS the opt-in (flips the capability through
  `UserPreferencesCache`, then starts the recorder in the same gesture).
  Never a silent no-op.
- Help window row: "Meeting record" — contents come from the live
  configuration like every other row.

## Canonical reference

`HelpWindowController.swift` shows every existing hotkey through
`HotkeyHintView` — read it before adding a new row to see the
established style.

## API examples

```swift
HotkeyHintView(label: "Quit", keys: [HotkeyGlyph.option, "Q"])  // response panel close row
HotkeyHintView(label: "Help", keys: [HotkeyGlyph.option, "H"])  // floating Keybindings hint
HotkeyHintView(keys: ["Space"])                                 // Drop = hold Space (Help row; title column already labels it)
HotkeyHintView(label: "Hold", keys: [HotkeyGlyph.command])      // Help window row needing tap/hold disambiguation
// Hover-slot hints above the tiles:
HotkeyHintView(contents: shortcut.contents, style: .keycaps, size: .tiny)
// Each glyph renders in its own mini rounded keycap (KeycapChrome.chip),
// no outer capsule. Reads as [⌥][1] — two distinct tiny keys.
// .bare remains for overline glyphs without per-cap chips.
```

Prefer sourcing the caps from config rather than literals where a binding
is involved: `HotkeyHintView(contents: configuration.dropVoiceShortcut.contents)`.
This keeps a rebound shortcut in sync across every surface.

## Checklist when adding a new hotkey

- [ ] Registered through the appropriate monitor — Carbon
      `RegisterEventHotKey` (`Sources/Sidekey/CarbonHotkeyMonitor.swift`)
      for a combo, `ModifierOnlyHotkeyMonitor` for a modifier gesture,
      or `SpaceHoldMonitor` (CGEventTap) for the hold-Space Drop gesture.
      All route through `HotkeyShortcutMonitor`.
- [ ] Surfaced via `HotkeyHintView` in every UI surface where the
      hotkey is relevant (close rows, hints, panels) — source the caps
      from `configuration.<shortcut>.contents`, not literals.
- [ ] Added as a row in `HelpWindowController.swift` so it shows
      up in the Help window
- [ ] Pure-logic test for the register / unregister lifecycle
      (`Tests/SidekeyTests/CarbonHotkeyMonitorTests.swift` pattern)
