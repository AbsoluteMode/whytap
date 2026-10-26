---
id: whytap-screenshot-toolbar
type: decision
title: Compact screenshot editor and text-and-number blur
summary: Explicit local capture opens a native toolbar with Blur defaulting to text and standalone numbers and an entire-area alternative.
status: confirmed
tags: [screenshots, capture, blur, numbers, vision, toolbar, privacy]
canonical_for: [screenshot-editor, screenshot-text-number-blur]
verified_at: 2026-10-26
sources:
  - type: user-confirmed
    reference: On 2026-10-26 the user reported that the adjacent screenshot tool icons and arrow keycaps did not clearly show which shortcut belonged to which tool.
    confirmed_at: 2026-10-26
  - type: user-confirmed
    reference: On 2026-10-21 the user requested restoring screenshot text extraction after finding a use for it, superseding only Copy text removal in the earlier tool reduction.
    confirmed_at: 2026-10-21
  - type: user-confirmed
    reference: On 2026-10-21 the user replaced the arrow-shaped cross with tool icons in dashed squares and a separate arrow hotkey hint beside each because the cross was hard to understand.
    confirmed_at: 2026-10-21
  - type: user-confirmed
    reference: On 2026-10-21 the user replaced the four stock assignments with Blur, Shape, Pen and Text, rejecting duplicate Copy, and reported the top/bottom arrow outlines pointed the wrong way.
    confirmed_at: 2026-10-21
  - type: user-confirmed
    reference: On 2026-10-21 the user clarified the four arrows must appear as a cross directly on the screenshot toolbar, with reassignment in that same panel rather than Settings.
    confirmed_at: 2026-10-21
  - type: repository
    reference: Sources/Sidekey/Screenshots/ScreenshotArrowCluster.swift
    confirmed_at: 2026-10-21
  - type: repository
    reference: Tests/SidekeyTests/Screenshots/ScreenshotArrowToolbarTests.swift
    confirmed_at: 2026-10-21
  - type: user-confirmed
    reference: On 2026-10-21 the user reported Cmd-Z still failed after a curved stroke and requested four assignable arrow actions, Screenshot before Agent priority, chosen defaults, replacement on drop and dashed draggable slots.
    confirmed_at: 2026-10-21
  - type: repository
    reference: Tests/SidekeyTests/Screenshots/ScreenshotUndoTests.swift
    confirmed_at: 2026-10-21
  - type: repository
    reference: Tests/SidekeyTests/Screenshots/ScreenshotArrowTests.swift
    confirmed_at: 2026-10-21
  - type: user-confirmed
    reference: On 2026-10-21 the user requested highlighting Enter within Copy and exit, suggesting a square keycap or vertical separator, and centering it.
    confirmed_at: 2026-10-21
  - type: user-confirmed
    reference: On 2026-10-21 the user removed Select/crop, Highlighter, Spotlight, Copy text, Pin above windows and Output size, retaining initial area selection, Arrow, Shape, Pen, Text, Blur, Numbered steps, Share and the existing finish/edit actions.
    confirmed_at: 2026-10-21
  - type: user-confirmed
    reference: On 2026-10-21 the user requested preserving Whytap Hover in the frozen capture, area-only output without full-display Enter/double-click actions, and removal of the initial instruction strip.
    confirmed_at: 2026-10-21
  - type: user-confirmed
    reference: On 2026-10-21 the user requested visible Copy and exit with Enter, every tool on the main toolbar without More, separate tool settings, Cmd-Z editing undo, and reported intermittent Screenshot activation and spontaneous editor dismissal.
    confirmed_at: 2026-10-21
  - type: repository
    reference: Sources/Sidekey/Screenshots/ScreenshotCoordinator.swift
    confirmed_at: 2026-10-21
  - type: repository
    reference: Tests/SidekeyTests/Screenshots/ScreenshotReliabilityTests.swift
    confirmed_at: 2026-10-21
  - type: user-confirmed
    reference: On 2026-10-20 the user requested a single toolbar row, faster and cleaner Blur, Copy plus direct Download with filename confirmation, and Enter to copy and close.
    confirmed_at: 2026-10-20
  - type: user-confirmed
    reference: On 2026-10-20 the user requested a Screen Recording entry for screenshots in Settings Permissions.
    confirmed_at: 2026-10-20
  - type: user-confirmed
    reference: On 2026-10-20 the user requested implementation of the approved compact screenshot toolbar, explicitly including text and numbers in the default Blur mode.
    confirmed_at: 2026-10-20
  - type: repository
    reference: Sources/Sidekey/Screenshots/ScreenshotCoordinator.swift
    confirmed_at: 2026-10-20
  - type: repository
    reference: Sources/Sidekey/Screenshots/ScreenshotDocument.swift
    confirmed_at: 2026-10-20
  - type: repository
    reference: Tests/SidekeyTests/Screenshots/ScreenshotTests.swift
    confirmed_at: 2026-10-20
  - type: repository
    reference: Tests/SidekeyTests/Screenshots/ScreenshotSelectionTests.swift
    confirmed_at: 2026-10-20
related: [2026-10-26-first-launch-permissions.md, ../project.md]
---

# Context

The user approved a compact screenshot toolbar and corrected Blur to include
text **and numbers**, including standalone digits.

# Alternatives

Whole-rectangle blur unnecessarily hides the interface. Remote image analysis
adds setup and sends content away. A full editor window adds navigation.

# Decision

Use explicitly triggered ScreenCaptureKit snapshots, an AppKit canvas/toolbar
and system Vision. Blur defaults to Text and numbers, with Entire area as an
alternative. Secondary tools live in More. Existing layouts/shortcuts do not
gain an automatic pinned tile or reserved key.

# Rationale

Recognition without language correction retains number/code identities;
additional text detection does not depend on recognizing a language. Blur
uses already edited pixels, composites replacement pixels and exports no
editable original layer. Copy text also uses the edited image.

# Sources

Frontmatter links the confirmation and implementation. See the
[screenshot guide](../../docs/screenshots.md) for behavior and limitations.

# Comments and objections

OCR and blur do not guarantee finding every glyph or irreversible anonymization.

# Resolution

Keep the result visible, both modes explicit, and analysis errors non-destructive.
Export waits for local processing; cancellation invalidates late results.
Selecting an existing immovable Blur is a selection-only gesture, not a new
crop gesture. Clicking, dragging or deleting it preserves the crop and leaves
undo/redo attached to actual edits. Dedicated unshown-canvas regressions cover
these interactions alongside normal crop creation, movement and resizing.
The old ScreenRecordingRemoval guards predate explicit screenshots. Their
capture exception is restricted to ScreenshotCoordinator's still-frame entry.
The user's later request adds a Screen Recording status and explicit Allow/Open
action in Settings Permissions; PermissionsHelper owns that action's request
and system-settings link. Passive refresh never requests access. Launch,
the orb and meeting audio retain the no-screen-capture/no-prompt contract.

# Follow-up polish

The user rejected the second settings row and slow/rough Blur. Keep tool settings
inline in one row. Download replaces Save, uses a downward arrow and writes PNG
directly into Downloads under a readable local timestamp, with exclusive creation
and numbered collision suffixes. Download writes into an owned temporary
directory first, then publishes the completed PNG using exclusive atomic rename;
failures remove staging instead of leaving a truncated final file. Success names the actual file and retains the
editor. Return copies and closes after selection; if Blur is pending it waits for
the patch, and a failed Blur remains open. Return in the label field also copies/closes, as requested. Typing only prepares
the label; click the screenshot to place it. The placeholder/help explicitly say
that an unplaced label is discarded; native clipboard editing stays in the field.

Fresh-executable checks reproduced a 30-second first accurate-OCR call even
with CPU compute devices. Blur therefore combines fast Vision recognition and
language-independent regions, with a bounded extra pass for isolated digits.
That pass examines up to 8192 contours and classifies up to 256 uncovered glyph
candidates in a repeated-glyph atlas, accepting repeated letters/digits and mapping them
back to original coordinates. Atlas pixels never reach output. Accurate OCR
remains in Copy text. Dark crops are normalized for recognition only, preserving
original screenshot colors. Pure region detection and fast OCR alone were
rejected because they missed small single digits. Per-region blur strengths
replace a median strength that could leave a large amount legible beside small
labels; stronger overlapping masks apply last. Crop-first compositing allocates only the selected
pixels. Rendering/detection/PNG work happens off the UI thread, and a reusable
hardware-backed Core Image context replaces per-gesture software setup. Mask
strength follows text height, with padded, subtly rounded text edges; Entire area
covers its full rectangle. Geometry and pixel regressions preserve Retina/crop
alignment and background pixels. See [interface decisions](../../docs/DESIGN.md).

# 2026-10-21 revision

The user replaced inline settings and More with an always-visible tool/action
bar and a separate settings accessory. Copy is visibly named Copy & exit with
its Return glyph; Enter is explained in the canvas hint. Cmd-Z and Shift-Cmd-Z
route edits from either floating panel while text fields retain native editing.
Narrow screens wrap the controls without hiding commands. Native focus and
pressed behavior remain, with explicit enabled-only hover feedback.

Capture now requests filter content points multiplied by its pixel scale and
best capture resolution. Legacy display-width functions returned 1728×1117 on
the affected 2× Retina display rather than its 3456×2234 source pixels. PNG is
lossless, but could not recover that lost capture detail. Export preserves the
captured size; the subsequent tool-reduction revision removes resizing.

Repeated activation no longer toggles an in-flight or edited capture off.
Display-parameter notifications cancel only after a real display layout/scale
change. Space changes retain the stale-capture guard. Static lifecycle/reason
logs aid follow-up without screen pixels, text, paths or keys. An existing responder recursion is independently confirmed in a local crash
report: unknown keys cycled from canvas to its forwarding panel and back until
stack overflow. Unknown editor keys now terminate locally; Tab explicitly
advances keyboard focus across both bars. A regression sends Space, Tab and
unassigned letters/numbers through all three panels. A capture-only ten-second
deadline releases activity and permits retry even when the capture provider
ignores cancellation; it never times out an editor. Both bars observe the
screen's notch safe area. Retina PNG records its logical point size alongside
full pixel dimensions. The primary action draws its accent independently of
which screenshot panel is key. Other spontaneous-dismissal causes and physical
hotkey reliability remain installed-app acceptance.

# Visible-state freeze and area-only revision

Freeze the visible screen, including Whytap Hover, before presenting editor
windows. A capture-preparation signal holds the existing mouse-expansion latch
and defers its expiry/dismissal. Screenshot activation does not wake the island,
release search focus or clear a query first. Release the hold after all source
frames have been captured, or on cancellation/failure/timeout. No continuous
screen stream or background capture is introduced.

Export requires a region the user dragged. Remove full-display Enter and
double-click selection, its accessibility command and Help row, and the passive
instruction strip. Enter with no crop is inert. Keep transient processing,
error and download confirmation states. This supersedes the earlier full-display
and pre-capture island-exclusion behavior.

# Tool-reduction revision — 2026-10-21

After reviewing each action, the user chose Arrow, Shape, Pen, Text, Blur,
Numbered steps and Share, plus Undo/Redo, Download, Copy & exit and Cancel.
Remove the Select/crop button and V shortcut, Highlighter and M shortcut,
Spotlight, Copy text, Pin above windows and Output size. Initial area selection
still uses a drag, with the existing selection geometry and keyboard adjustment.
Clicking the active annotation tool again stops drawing, restoring direct
selection/annotation adjustment without a Select control. No replacement menu or hidden invocation retains the removed actions.

The reduced editor exports the original Retina pixels without resizing. Keep
fast local text/number detection for Blur. Accurate OCR remains only in tests
as an independent oracle for blur/orientation regressions; its copying action
and runtime recognition path are removed. This supersedes the earlier expanded
tool catalog and the copying/pinning/resizing behavior in this record.

# Copy text restored — 2026-10-21

The user found a use for screenshot text extraction and asked to restore it.
This supersedes only Copy text removal in the tool-reduction revision above.
Restore its main-bar text-viewfinder action beside Share and make it available
in the existing arrow action catalog, preserving every saved assignment.

Use accurate on-device Vision recognition with English/Russian support and
language correction off for codes/numbers. Render the selected crop with its
annotations and Blur before recognition; never analyze hidden original pixels.
Rendering and OCR run off the UI thread. Show local progress and allow Escape;
cancelled/old generations cannot write a late result to the clipboard. Success
copies plain text and exits. Empty/error results retain the editor for retry
or image export, leaving the clipboard untouched until readable text exists.
The bounded ScreenshotTextCopy helper owns the asynchronous commit boundary.
Before clearing the clipboard it snapshots all items/types; incomplete snapshots
abort without mutation. A failed write restores the snapshot only while the
pasteboard is still owned by this operation, preserving a newer owner's data.
Named-pasteboard tests inject late recognition and write failures to exercise
cancelled/stale generations, empty/error results and rich multi-item recovery.
Keep Blur's fast region path unchanged; no warmup, network or app-managed model
download is introduced. Accurate recognition can have a slow first call.

# Capture-test isolation

A 21 October focused run received a real `space_changed` cancellation before
its fake provider began; static lifecycle diagnostics confirmed the source.
The deadline/retry assertions consequently failed despite unchanged tool code.
Tests now inject private application/workspace notification centers and no
foreground application through ScreenshotCaptureEnvironment. They still post
unchanged-display and Space-change events explicitly, verifying the real
cancellation handlers while avoiding interference with the user's desktop.
Production defaults retain the system centers and previous-app focus behavior.

# Return-key presentation revision

Copy & exit keeps one native button and one click/focus target. Its Return
symbol uses the shared HotkeyHintView keycap style in a click-through hosting
view, separated from the label by an 8-point gap. Center the label/keycap group
horizontally and both elements vertically; disabled state dims the hint with
the button. This distinguishes the finish shortcut without adding a second
action or changing Return behavior.

# Undo dispatch and configurable arrows — 2026-10-21

Generated-event regressions reproduce the Russian-layout failure: the physical
Z key produces U+044F, while the previous handler matched only the character z.
Nonactivating panels now handle editing commands in both the key-equivalent
path and direct window event dispatch. One key press performs one undo/redo;
focused native text editors retain their own commands.

Settings Hotkeys exposes four dashed arrow slots with defaults Up Pen, Down
Blur, Left Undo, Right Copy & exit. Drag any retained editor tool or command
onto a slot, or choose its native menu with keyboard/VoiceOver. A drop copies
the action and replaces only the destination, including when dragging another
slot; it never swaps or removes the source. Drafts follow Save/Revert/reset and
round-trip in settings backups. Help reads the same configuration. Modified
arrows retain crop move/resize; Move crop is also assignable to bare arrows.

The Agent Useful Links controller observes screenshot activity synchronously
and unregisters its Carbon hotkeys before the editor appears. Suppressing only
a callback is insufficient: Carbon has already swallowed the arrow. Closing
Screenshot restores the latest supported actions only if the answer still
needs them. Registration generations invalidate callbacks queued before
suspension. Native text fields keep cursor navigation; held export keys do
not repeat destructive or finish actions. Synthetic tests use unshown windows
and private subjects/defaults; physical delivery and dragging remain installed
app acceptance.

# Placement correction — 2026-10-21

The user did not see the arrows because the implementation put them only in
Settings. They clarified a cardinal cross directly on the screenshot toolbar,
with reassignment in that same panel. This supersedes the Settings-only surface
and its inverted-T layout, not the saved four-action contract.

ScreenshotArrowCluster is one 96 × 60 pt toolbar component, retained as a unit
when controls wrap. Four native buttons draw dashed directional silhouettes
with the assigned function symbols. Clicking opens a native assignment menu;
physical arrow keys execute the assigned functions. Every visible toolbar
function and existing assignment can be dragged onto a destination, replacing
only that slot and saving immediately. Dragging never also activates its source.
Menus expose every retained editor action plus per-arrow reset and keyboard/
VoiceOver access. Busy processing disables assignments, menu items and drops.
The four stock assignments are now Up Blur, Left Shape, Right Pen, Down Text.
Only the exact previous stock map migrates once; custom mappings and later
intentional assignments are preserved. Directional paths account for NSButton's
flipped coordinates, keeping top Up and bottom Down. Shape dragging follows
its current Rectangle/Oval choice.
The former Settings-only component is removed; persistence, Help, backup,
Command-Z, native text handling and Agent priority stay intact.

# Square tool revision — 2026-10-21

After the preview, the user found the arrow-shaped controls hard to understand
and chose tool icons in dashed squares with adjacent arrow shortcut hints.
Replace the cross with one 249 × 30 pt group of four square/keycap pairs on the
screenshot toolbar. Native 30 pt buttons contain the function symbols; separate
HotkeyHintView keycaps show Up/Left/Right/Down without taking clicks or focus.
The whole square is the visible hover/press/focus/drop target. Assignments,
immediate saving, source-preserving replacement, menu reset, defaults and the
one-time migration are unchanged. This supersedes the arrow-contour geometry
and its directional drawing, not the toolbar placement or keyboard contract.

The defaults-migration version travels with the arrow map in the backup
registry's existing property-list format. Otherwise restoring onto a fresh
profile would mistake a deliberately reassigned previous stock map for an
unmigrated map and reset it. A synthetic encrypted settings backup/restore
regression checks version 2, the exact arrow map, other hotkeys and provider
selection without accessing real data or credentials.

# Grouped shortcut revision — 2026-10-26

The user reported that the square/keycap row did not make shortcut ownership
clear. Group each icon and its HotkeyHintView keycap inside one 57 × 30 pt
native button, with a shared solid border/background and 11 pt between pairs
(261 × 30 pt overall). The full pair owns hover, press, focus, assignment menu
and drag/drop. Its decorative keycap passes events to the button. Disabled
pairs suppress hover and reject assignment/drop. Existing arrow bindings,
defaults, migration, execution and immediate source-preserving replacement
remain unchanged. This supersedes only the separated square/keycap treatment
above. Idle borders blend the secondary foreground toward the primary label
to keep at least 3:1 contrast in the native render. Contrast measurements
convert the PNG ICC profile to sRGB before WCAG luminance; treating raw
Generic RGB channels as sRGB overstated the original light-theme contrast.
Implementation details and the validation matrix live in docs/DESIGN.md.

# Consequences

Screen Recording is requested on invocation. Content stays in memory until
explicit copy/download/system share. System OCR adds no app-managed speech/LLM
weights or provider traffic. The editor blocks update restarts. Screen/Space
changes and sleep cancel stale captures. Real permission/capture/dialog flows
remain installed-app acceptance checks.

# Supersedes / superseded by

No prior screenshot-editor decision is superseded.
