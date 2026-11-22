# Screenshots

Find **Screenshot** in the island's **Search all tools**, or add it from
Settings → Toolbox. Settings → Hotkeys → Tools can assign its optional named
shortcut. Existing layouts and shortcuts are preserved.

Settings → Permissions → **Screen Recording** shows a green checkmark when
access is granted, or **Allow** when it is missing. The first **Allow** only
asks macOS; later presses read **Open Settings** and open System Settings →
Privacy & Security → Screen & System Audio Recording. Returning to Whytap or
clicking Refresh updates the status. Screenshot invocation can also request
this access; opening Settings or launching Whytap never requests it. In the next version
after 2.2.26, the first Screenshot press without access shows only the macOS
dialog; its button leads to
System Settings. A later press without access shows Whytap's own explanation with
Open System Settings. It is optional for other features. Follow macOS's reopen instruction after finishing
current work.

The visible screen freezes before the editor opens, including Whytap's current
Hover. Hover keeps its current open/closed state during capture; capture does not
wake, close or exclude the island first. Only the area you drag is exported.
There is no full-display shortcut or initial instruction strip. **Copy & exit ↩**
or Enter copies that selected area and closes; Enter without a selection does
nothing, and double-click does not select the display.
Selection belongs to the display where it starts. The floating toolbar stays
outside the crop where space permits, flips above a bottom-edge crop and is
never included in the image.

The main toolbar exposes Arrow, Shape, Pen, Text, **Blur**, Numbered steps,
**Copy text**, Share, Undo, Redo, **Download**, **Copy & exit ↩**, and Cancel. There is no More
menu or separate Select/crop control. Initial region selection is still a drag;
Highlighter, Spotlight, Pin above windows and Output size are removed.
Copy & exit shows Return in a separate centered keycap within the same button.
Blur is text-only; Download is the downward arrow. On narrower
displays the toolbar wraps onto more rows.

Hover over any toolbar button or tool setting to see what it does and its key,
for example **Copy text — recognize the text in the selection, copy it and
close (OCR on this Mac)**. The first hint appears after about half a second;
moving to the next button shows its hint at once. A click, a key press or
leaving the button hides it. The same text is the control's VoiceOver help.

Copy text can also be found from the island: type **OCR**, **распознать**,
**copy text**, **recognize text** or **text from screen** in **Search all
tools**. The result reads **Shot — Copy text**: it opens Shot; select an area,
then click Copy text.

Hold Shift while drawing with Pen to draw one straight line from the point
where the drag started. It snaps to the nearest 45 degrees (horizontal,
vertical or diagonal) and stops at the crop edge without bending. Releasing
Shift mid-drag continues freehand. Shift does not change other tools.
Color, width, shape and blur mode appear in a **separate adjacent settings
panel** for the current tool; color/width are remembered per tool. Choose Text,
click anywhere inside the crop and type directly there. Click an existing label
to place the caret and edit; native selection, clipboard commands and text undo
stay in the label. From a new empty label, press an arrow assigned to another
tool to switch immediately. Shift-Return adds a line. Hover shows an outlined
label and a separate move handle; drag that handle to reposition it without moving
the crop. The selected label keeps its handle visible. Tab can focus the handle;
arrows move its label one point (Shift: ten), and Return edits it. Empty labels
are discarded. Escape restores the text before this edit or discards a new label;
a second Escape cancels capture. Finishing an edit or move creates one screenshot
undo step. Handles, editing outlines and the caret never enter exported pixels. Click the
active tool again to stop drawing, then move annotations or move/resize the
selection by its corners. Shift plus arrows moves it; Option plus arrows resizes it (bare arrows run their assigned tools). Blur patches
can be deleted or undone; they cannot be moved because moving them would
expose original information. Undo/redo preserves the selected region.

**Blur → Text and numbers** is the default. Select a zone; on-device Vision
finds text regions, numbers, dates, amounts and codes using fast recognition
and language-independent detection. A bounded extra pass checks uncovered
glyphs for isolated letters/digits: a temporary repeated-glyph atlas helps the fast
recognizer identify single numbers. Its pixels never enter the screenshot.
The editor uses fast detection, avoiding the accurate recognizer’s long cold start.
Dark-background crops are inverted only for detection, preserving output colors. Only detected text
rectangles are blurred, with small rounded masks and strength
matched separately to each text region’s height, so large text is not weakened
by nearby small labels. Rendering uses a reusable hardware-backed Core Image
context; cropping, detection, blur and PNG encoding run away from the UI thread.
**Entire area**
blurs the complete zone. The visible result supports review: detection can miss
small or unusual text, and blur does not promise irreversible anonymization.
No detections or an analysis error leaves the image unchanged and offers a
retry/entire-area message. Editing/export wait for processing; Escape cancels.

Numbered steps places consecutive numbers. Share uses macOS's picker and sends
only the edited image to the service the user selects.

**Copy text** (the text viewfinder beside Share) recognizes text and numbers
from the selected, edited area on this Mac, copies plain text and closes the
editor. It reads the same flattened pixels as image export, including Blur and
placed labels; text outside the crop is excluded. Accurate system recognition
supports English and Russian and keeps language correction off for numbers and
codes. The first request can take longer while macOS initializes recognition.
Progress stays visible; Escape cancels without copying a late result. If no
readable text is found or recognition fails, the editor stays open for retry or
image copy. A clipboard write failure restores the previous readable contents
while the operation still owns the clipboard; it never restores over a newer
copy from another app. No provider key, model download or network request is needed.

Copy writes flattened PNG pixels to the clipboard and finishes. **Return /
numeric Enter** does the same after selection; during Blur it waits for the
completed patch before copying. Return during Download likewise waits for the file
and then copies/closes. A failed Blur keeps the editor open. In the
inline annotation editor, Return commits the current text, then copies/closes.
**Download** (or ⌘S) writes PNG directly into Downloads, using a readable local
timestamp such as `Screenshot 2026-10-20 at 20.30.15.png`. Existing files are never
overwritten; a fully written temporary file is published by an exclusive atomic
rename, with staging removed on success or failure. A collision adds `(2)`, `(3)`, and so on. The editor stays open and
shows “Downloaded to Downloads as …” with the actual filename, also announced to
accessibility. Folder/write failures leave the editor open for retry.
Capture uses the full pixel resolution supplied by ScreenCaptureKit, including
Retina scale. Copy and Download preserve those pixels without resizing. PNG encoding itself is lossless. Retina PNG stores its logical point size as
well as its pixel dimensions, so apps respecting PNG resolution do not paste it
at double size. Captures/history stay in memory until an
explicit
export; no screenshot files are written automatically. Copies may enter the
ordinary clipboard history. Exports carry no editable original layers.
There is no provider setup, account, app-managed model download or API request.

Editor shortcuts, also listed in Help: A Arrow, R Rectangle,
O Oval, P Pen, T Text, B Blur, N Numbered steps, ⌘C Copy,
⌘S Download, ⌘Z Undo, ⇧⌘Z Redo. Undo/redo also work with Russian input.
Bare arrows default to ↑ Blur, ← Shape, → Pen, ↓ Text. Four shortcut buttons sit directly on the screenshot toolbar. Each encloses its tool icon and arrow-key hint inside one shared border, with wider gaps between pairs.
Drag a toolbar tool/action onto one to replace its function, or drag one arrow's
assignment onto another; the source remains. Click anywhere in a pair for the native
menu of every tool/command and Reset this arrow. Assignments save immediately,
without leaving the editor, copying the screenshot or cancelling capture. The
physical arrow keys execute those assignments; Tab and Space reach the menus.
Copy text is also available in the assignment menu and as a drag source; custom assignments remain saved.
Shift-arrows move the crop 10 points; Option-arrows resize it. Move crop can
also be assigned to a bare arrow for 1-point movement. Screenshot owns arrows
before Agent; text fields keep native cursor movement. Closing Screenshot
restores Agent’s current arrow actions. Delete removes the selected annotation. Escape cancels the
current drawing first, then capture. Return requires a selected area, then copies that area and closes. These are local editor commands.

Opening Screenshot again while capturing or editing keeps the current editor
and edits instead of toggling it closed. A stalled capture times out after ten
seconds with a retry message, releases its activity flag and permits a new
shortcut attempt. This deadline does not apply while editing. An unchanged screen-parameters notification
is ignored; actual display-layout or Space changes cancel stale captures.
Unassigned keys are consumed locally, preventing responder recursion. Tab and
Shift-Tab traverse enabled toolbar/accessory controls; both bars avoid a notch's
top safe area. Local
lifecycle diagnostics contain only static events and cancellation reasons. App-initiated update
restarts wait for the editor, local processing, dialogs and unsaved edits to
finish. Returning to idle alone never restarts Whytap.

Implementation: `Sources/Sidekey/Screenshots/`. Tests use generated images and
unshown windows. Real capture, permissions, multi-display compositing, clipboard
delivery, Downloads access and share dialogs require acceptance in the single
installed app
after builder promotion.
