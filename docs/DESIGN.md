# Interface decisions

## Agent voice model mark — 2026-10-22

The user speaks to the agent and wants to recognize the selected model's author.
First keep the transcript legible; the small mark identifies who will answer.
They explicitly chose the existing star beside the voice ticker, not new UI in
the model list. Keep the 15 pt mark in the 16 pt slot, existing gaps and capsule
measurements. The mark is an accessible labelled image, not a button.

- Model-author identity follows the exact Agent route, independent of an
  OpenRouter hosting-provider pin. Google search and Drop keep their own marks.
  Unknown/Auto OpenRouter authors use the existing router mark rather than a
  guessed company logo. No routes or preferences change.
- Bundled prewarmed artwork is immediate. Optional background cache refresh has
  no spinner, error banner or layout change; failed/offline refresh keeps usable
  artwork. A completed old download cannot replace a newly selected model.
  Reason: a decorative asset must not delay voice capture or change the task.
- Flatten logos to neutral 72% white using source alpha, preserving source aspect
  ratio. On black, the opaque mark has 10.54:1 contrast; the existing pulse's
  dimmest frame remains 3.91:1. Reason: colored source artwork must remain legible
  in the black voice capsule and must not become differently tinted company marks.
  Only model-author marks use this neutral mask; Drop/Google search retain their
  previous alpha wash and colors. Perplexity uses a 3-unit contour instead of its
  1-unit source line so the symbol remains visible at 15 pt, including after refresh.
- Keep the existing Core Animation pulse (scale 0.94–1.08 and opacity 0.58–0.96,
  1.15 s autoreversing). Reduce Motion removes scaling/pulsing and parks at 0.78
  opacity (6.51:1 for opaque mark pixels). There is no new animation, focus stop,
  hover target or keyboard action.

Verification uses native offscreen voice fixtures at 180/280/400 pt, both
appearances and Cyrillic transcript text; component tests cover pulse/reduced
motion, author selection, stale-download rejection and warm/offline cache paths.
Physical voice, system Reduce Motion and VoiceOver remain installed-app acceptance.
Assumption: the supported author marks are recognizable at 15 pt; the user can
confirm that in the installed voice ticker. Static OpenRouter image paths may
change; bundled fallbacks protect the voice experience.

## Screenshot tool squares and arrow hints — 2026-10-21

The person comes to annotate a region and configure four quick tools without
leaving the editor. First see the tool icons in dashed squares, each with its
arrow-key hint beside it; then drag a tool onto a square or click to reassign it.

- Put four pairs in one compact row directly on ScreenshotToolbar: a 30 pt
  dashed rounded square with the assigned tool's 16 pt symbol, then a nearby
  22 pt arrow keycap using HotkeyHintView. Keep a 5 pt intra-pair gap and 7 pt
  between pairs. The complete group is 249 × 30 pt. Why: the user found the
  earlier arrow-shaped cross hard to read and explicitly chose square tool
  icons with separate arrow shortcut hints. This supersedes both the cross
  and the earlier Settings-only/inverted-T placement.
- Defaults are ↑ Blur, ← Shape, → Pen, ↓ Text. Only the old unmodified stock
  map migrates once; custom mappings remain. Why: the user requested these
  four drawing tools and rejected duplicating the existing Copy action.
- The physical keys execute the functions. Clicking a square opens its native
  assignment menu, including every retained action and Reset this arrow. A
  drop from any toolbar tool or assigned square replaces only the destination
  and saves immediately, preserving the source and current screenshot. Why:
  reassignment should neither finish capture nor require Settings or Save.
- Track press/drag/release without also activating a dragged source. Escape
  aborts the pending click; hidden or disabled controls cannot complete it.
  Why: beginning a drag from Copy/Download must never export on release.
- Square hit areas highlight completely on hover, press and valid drop, with
  native focus rings. Tab/Space reach assignment menus. Adjacent keycaps are
  decorative, pass clicks through and add no focus stop. Busy state disables
  squares, menus and drops and dims key hints. Why: affordances must match the
  actual click targets and keep a keyboard/VoiceOver alternative to dragging.
- Keep the group intact while the surrounding toolbar wraps. Reuse adaptive
  AppKit popover materials and semantic foregrounds, with no new animation.
  Screenshot's priority over Agent, text navigation and Command-Z stay intact.

Native offscreen toolbar renders cover 360/520/900 pt in light/dark appearances.
Physical dragging, menu/keyboard/VoiceOver and installed-app acceptance remain
separate from these generated fixtures.

## Screenshot toolbar and capture reliability — 2026-10-21

The user comes to annotate a screenshot, discover the available tools, then
copy or download the result. First see the crop and every tool on the main bar.
Then change the selected tool's settings in an adjacent accessory and finish
with the visible **Copy & exit ↩** action or Enter.

- Expose Arrow, Shape, Pen, Text, Blur, Numbered steps, Share, Undo, Redo,
  Download, Copy & exit and Cancel. Remove More and the Select/crop control;
  keep the initial area drag. Clicking the active tool again stops drawing
  and restores direct selection/annotation adjustment without another button.
  Highlighter, Spotlight, Pin above
  windows and Output size are removed, including their hidden commands and
  shortcuts. Why: the user chose a smaller annotation-focused tool set after
  reviewing every action; full pixel resolution remains automatic.
- Restore Copy text beside Share, using the text viewfinder symbol and the same
  native button, whole-area hover, pressed, focus and disabled behavior. It is
  also assignable to the four arrow slots without changing saved assignments.
  Why: on 21 October the user found a use for extracting screenshot text and
  reversed the earlier removal of this action. Recognize only the edited crop,
  show local progress, allow Escape and keep the editor on empty/error results;
  success copies plain text and exits. Why: the user can recover without losing
  edits, and text extraction follows visible Blur/annotation output.
- Blur uses text alone; Download uses its downward arrow alone with a tooltip.
  Why: the user explicitly removed Blur’s icon and Download’s label.
- Keep color, width, shape, blur mode and label input in `ScreenshotToolSettings`,
  a separate native child panel. It follows the main bar without moving its
  targets when tools change; the label field uses a second accessory row.
  Why: the user explicitly replaced the previous inline-settings requirement.
- Preserve semantic AppKit typography, popover material and the accented finish
  action. All buttons highlight their full area on hover/press; native focus
  rings and control behavior remain. Accessory controls gain a hover outline;
  disabled controls suppress it. Borderless buttons draw semantic foregrounds
  without inline-cell dimming; native offscreen Blur text contrast measures
  9.02:1 light and 6.73:1 dark. Why: interactivity and text must stay readable.
- Wrap main-bar controls onto more rows at the width where they stop fitting,
  retaining order, full hit areas and every command. Why: exposing more tools
  must not hide Copy or clip controls on smaller displays.
- Enter and the copy button both copy the selected area and exit. The button
  names the outcome and shows ↩ in its own square keycap via HotkeyHintView.
  Center the label/keycap group and both elements vertically; the hint passes
  clicks through to the same button. Why: the user asked to distinguish and
  center Enter. No passive instruction strip remains; errors,
  processing and download results still appear when relevant. There is no
  full-display Enter/double-click mode. Why: the user wants area capture only.
- Cmd-Z / Shift-Cmd-Z undo/redo edits from both panels;
  a focused text field keeps native text undo. Tab/Shift-Tab traverse enabled
  controls in both panels. Unknown editor keys terminate locally instead of
  bubbling back into the forwarding window. Why: outcomes and shortcuts
  must be discoverable and match macOS editing behavior.
- Capture the visible Hover before any focus/search/hover cleanup or island
  wake. Hold its current open/closed mouse latch until pixels are frozen;
  include Whytap's visible windows in the capture. Why: the user expects the
  same visible-state freeze as Apple's region screenshot.
- Repeated Screenshot activation preserves the current capture. Unchanged
  screen-parameter notifications do not cancel it; actual display layout or
  Space changes still discard stale pixels. Sanitized lifecycle logs record
  reasons only. A 10-second capture deadline releases activity and permits retry
  even if ScreenCaptureKit does not return; it ends before editing starts.
  Why: repeated hotkey events must not toggle the editor off or leave it stuck.
- Request filter content points multiplied by ScreenCaptureKit's pixel scale
  with best capture resolution. Why: the affected Retina display reports
  1728×1117 through the legacy display functions but has 3456×2234 source
  pixels; exporting lossless PNG cannot recover detail already lost at capture.
  PNG also records its original point scale, avoiding a double-sized Retina paste.
- Keep both bars below a display's top safe-area inset. Why: full-display crops
  must leave controls reachable on Macs with a notch.
- Draw the primary accent fill independently of window activation, choosing
  black/white text for the stronger contrast. Why: the floating toolbar is
  usually not the key window, but Copy & exit must remain the leading action.

The later 21 October tool reduction also supersedes the initially expanded
21 October catalog. The earlier single-row/More/inline-settings decisions below are historical and
superseded by this user request. No new animation is introduced; reduced motion
uses the same immediate layout. Offscreen fixtures and generated pixels provide
local verification; actual hotkey delivery and capture remain single-installed-app
acceptance after the designated builder promotes the reviewed source.

## Screenshot editor polish — 2026-10-20

The person comes to mark a screenshot and copy or download it quickly. First
they see their crop and a single toolbar row. Next they choose a tool, adjust
its settings beside it, and finish with Copy/Return or Download.

- Tools, contextual controls and export actions share a 42 pt horizontal row.
  Why: the user explicitly rejected settings on a second row. Keep system
  typography, adaptive popover material and semantic accent/label colors.
  Selected tools retain label-color text on an accent wash; accent-blue text
  on that wash had insufficient contrast in the native dark snapshot.
- Show only settings relevant to the active tool. Color/width use existing
  per-tool preferences; the label field is 160 pt. Why: the screenshot is the
  workspace, and tool configuration should stay nearby without a permanent form.
- Copy remains the accented primary action. Download has a downward arrow and
  explicit text, writes directly to Downloads and keeps the editor open with
  its actual filename. Why: file destination and success must be visible without
  a Save dialog or interpreting a Share symbol. Name collisions never overwrite.
- Return/keypad Enter copies and closes after selection; during Blur the command
  waits for the completed patch; during Download it waits for the file. Without a crop it copies the whole display and closes in one action.
  Return in the label field also copies/closes. Typing is preparation;
  click the screenshot to place the label first. The placeholder/help explicitly
  say that an unplaced label is discarded, keeping the requested one-Return finish. Failed processing stays open.
- No entrance, resize or tool-switch animation delays input; reduced motion uses
  the same immediate behavior. Busy state disables mutating/export controls and
  reports processing; Escape stays available. Copy and Download encode off the
  main thread. Fast Vision regions plus a bounded isolated-glyph atlas avoid accurate
  OCR’s per-build cold start; dark crops are normalized for detection only.
  Copy text retains accurate OCR as a separate action.
- Text masks have 3 px padded, subtly rounded edges; strength follows each text region’s height,
  rather than the selected area's dimensions or the median of other labels.
  Overlapping masks apply stronger blur last. Entire area covers every pixel.
  Why: avoid oversized smears while preserving the existing text/number contract.

Native offscreen fixtures cover the real AppKit toolbar in both appearances,
all main tool states and 640/768/1024 pt available widths; generated images cover region detection, crop/annotation
alignment, flattened pixels, unique downloads and keyboard commands. These
checks do not establish live capture permission, real clipboard delivery, physical
keyboard focus or perceived smoothness in the installed application. Those remain
acceptance after the designated builder promotes the reviewed source.

## Provider key tiles — 2026-10-21

Tiles, form actions and picker rows show full-target hover and pressed feedback,
with distinct keyboard focus. Disabled controls are dimmed and ignore hover.
Feedback is local to API & Models; shared MacButton behavior stays unchanged.
Dark pressed overlays are capped at 8% to preserve small blue/white text contrast.

The person comes to connect a provider. First they see every available provider,
including OpenAI and Anthropic, then open its square to enter and check a key.
The chosen direction is the user's tile-to-inline-form request.

- Use square provider buttons in a responsive 2/3/4-column grid, with a 12 pt
  gap and 12 pt corners. Each tile is an independent provider connection, so
  its boundary has a purpose. Show the brand, provider name, speech/language
  purpose and key status even before a key exists. No decorative statistics.
- Clicking a tile expands a full-width form immediately below that tile's row.
  One form is open at a time; a thin accent outline marks it. Native keyboard
  focus has an outline too. Escape or repeating the tile closes it;
  closing returns focus to that tile. Input receives focus on expansion.
- Keep the shared system typography and adaptive Settings colors: 13 pt title,
  11.5 pt explanation and 11 pt tile status. Hover never changes geometry.
  Expansion is immediate, including Reduce Motion. At narrow widths the grid
  reduces columns and the form retains the full row width.
- As amended by the user on 2026-10-21, the inline form contains only the key
  field and Save/Remove actions. Remove is unavailable before a key exists;
  removal is direct, with no extra confirmation row. Custom endpoints retain
  required name/URL fields. There is no helper, permanent form status, Check now,
  Cancel or detailed error copy. Why: the user rejected technical explanation
  and explicitly requested two simple actions with a brief result notice.
- Save validates before persisting and disables competing actions with a small
  spinner. A rejected/unreachable check preserves the draft and old key. A
  successful save clears the draft. No model-assignment sheet opens from inline
  Save. The panel shows only Key accepted / Key not accepted for 2.5 seconds,
  anchored to the visible panel instead of scrolled content, and announces it
  to accessibility. Repeating Save resets the notice lifetime; the notice never
  captures clicks or shifts fields/buttons. Existing keys are never read back.
  A failed Tavily deletion uses "Couldn’t remove key" in the same brief notice,
  so a storage failure is not described as a rejected credential.
  Add-key entry points in Models/API hints open this same API keys surface.
- OpenAI and Anthropic are ordinary LLM providers for all text modes. Adding a
  key never assigns routes silently; model selection retains its own synthetic
  check. Why: the user rejected limiting API setup by individual features.

Native offscreen fixtures cover collapsed tiles and OpenAI, saved OpenRouter and
custom-server forms at 600/900 pt in both appearances. Shared token contrast on
tile surfaces is 17.01:1/14.58:1 for primary text (light/dark), 6.62:1/7.98:1
for secondary text and at least 5.59:1 for key-entry actions; selected-state
status text retains at least 5.98:1. Physical keyboard focus,
VoiceOver, actual key entry and live provider responses remain installed-app
acceptance; all automated transport checks use synthetic keys and stub servers.

## Searchable model selection — 2026-10-20

The user comes to choose a model without scrolling a long catalog. First they
see a focused search field, then matching model IDs under their provider.
The closed control retains the shared 30 pt popup label and existing widths.

- Open a 440 pt native popover with a fixed search band, 300 pt scrolling list
  and a fixed result count. Why: searching and browsing need no maintenance
  commands; the user removed Refresh models and Other model ID on 2026-10-21.
- Match every query term in any order, ignoring case, diacritics, width and
  separators. Split letters/digits: `qwen 27` and `qwen27` find
  `qwen/qwen3.8-27b`. Prefer contiguous matches within each provider. For a
  nonempty query, equally relevant models sort by newest catalog date, with
  unknown dates last; equal/missing dates retain catalog order. An empty query
  retains catalog order and provider groups never move. Why: relevance comes
  first, then recency helps choose between equivalent matches.
- Keep provider headings, current-selection checkmarks, cached-refresh failures
  and disabled unsupported models. A two-line model label and full-ID tooltip
  handle long names. Exact account/model pairs remain distinct.
- Show a secondary date line under each dated model: Anthropic `Released`,
  OpenAI `Created`, OpenRouter `Added to OpenRouter`. Why: their APIs describe
  different events, so a shared release label would mislead. Hide missing,
  malformed and Unix-epoch dates without a placeholder. Format the provider's
  UTC day in the user's date locale; dates participate in search announcements.
  Refresh older metadata caches once on opening, retaining offline results.
  No new controls or motion; the existing full-row feedback covers the date.
  Sources: [Anthropic](https://platform.claude.com/docs/en/api/models/list),
  [OpenAI](https://developers.openai.com/api/reference/resources/models),
  [OpenRouter](https://openrouter.ai/docs/guides/overview/models#model-object-schema).
- Speech selectors use the same line and date tie-breaker. Deepgram shows
  `Updated` from the newest dated API version already cached by the app,
  including the plain `nova-3` alias. Soniox and ElevenLabs omit release dates
  in their model API schemas, so shipped stable IDs use an exact-ID release
  registry with checked official launch sources: Soniox `stt-rt-v5` 2026-06-16,
  `stt-async-v5` 2026-06-11; ElevenLabs `scribe_v2_realtime` 2025-11-11,
  `scribe_v2` 2026-01-09. They show `Released`, including offline and catalog-less
  states. Unknown models/aliases inherit no date. Why: speech models need the
  same recency context without fabricating API fields or release dates.
  Sources: [Deepgram model metadata](https://developers.deepgram.com/guides/fundamentals/model-metadata),
  [Soniox model changelog](https://soniox.com/docs/stt/models),
  [Scribe v2 Realtime launch](https://elevenlabs.io/blog/introducing-scribe-v2-realtime),
  [Scribe v2 launch](https://elevenlabs.io/blog/introducing-scribe-v2).
- The native search field owns normal editing and IME composition. Up/Down
  moves through enabled results and scrolls them into view; Return selects.
  Escape clears the query, then closes; outside click dismisses. Focus returns
  to the originating control. There is no new animation.
- Empty results offer Clear search; absent providers offer Add API key. Opening
  the picker automatically refreshes stale/failed catalogs, keeping the query
  and cached models. Successful catalogs are cached for one day; requests are
  single-flight per account. Search/arrow
  movement alone never selects or checks a model. An explicit pick uses the
  existing verification and route-preservation path.

Offscreen native fixtures cover the 440 pt picker in both appearances, filtered,
empty, absent-provider, stale-catalog and long/disabled-row states. Search and
native editing-command tests cover matching, stable ordering, account identity,
keyboard bounds and IME Return. Dated fixtures add all three date meanings,
unknown dates and long IDs in both appearances. Secondary date text contrast
is 6.62:1 light / 6.84:1 dark, or 5.30:1 / 5.45:1 on the active row.
Tie-order tests preserve better matches, unknown-last ordering and stable ties.
These checks do not prove physical focus,
popover dismissal or VoiceOver on the installed app; those remain acceptance.
The interpretation that a family plus size is the useful search input follows
the user's example; typo correction and model aliases are outside this change.

## API & Models costs — 2026-10-20

The user chose four tabs in one surface: API keys, Models, Costs, API hints.
Costs first shows the nearby period, then used features with one Price column;
USD and ElevenLabs credit values retain explicit units, including both lines
when a feature used both. Model details appear on the feature. Why: compare
feature expenses without a permanent model-level grid or scattered period control.

- One existing bgCard surface, 14 pt corners, shared underlined tabs and quiet
  separators. No extra metric cards, chart, entrance or number animation.
- Period choices are Today, Last 7 days, This month and inclusive Custom dates.
  Each entry into Costs starts at This month. Local-calendar date labels stay
  beside the table header. Invalid dates, loading,
  empty history and a recoverable storage error have explicit states.
- System typography: 15 pt heading, 13 pt feature/value rows, 11.5 pt secondary
  labels. Aligned numeric columns use monospaced digits; colors reuse adaptive
  MacSettingsTheme tokens. Approximation and incomplete totals use text marks,
  so meaning does not rely on color.
- From/To controls share the period menu's 30 pt geometry, neutral fill and
  typography. They open a 310 pt calendar with separate month menu and editable year combo.
  Selecting a day or Today applies and closes; month/year browsing never changes
  the filter, and Done/Return/Escape close without applying the browsed month.
  Year offers the recent 100 years and accepts any earlier positive year; future
  days and next-month navigation after today are disabled. Why: the user found
  the native whole-calendar focus ring distracting and year navigation unclear
  (2026-10-21). Focus stays visible on individual controls/day buttons, with
  full-area hover and pressed feedback; disabled days never respond to hover.
  The neutral closed controls retain their keyboard focus outline. The month
  selector uses a local native popup with an enabled-gated highlight drawing;
  shared plain menus are unchanged. Why: its pressed state must be verifiable
  from the real native control, rather than assumed from SwiftUI Menu styling.
- Hover opens model details; click pins, keyboard focus opens, Escape closes.
  Row fill follows actual pointer hover, so an open popover does not leave a
  selected-looking row after the pointer moves away.
  A short delayed dismissal permits pointer transfer into the native popover.
  The model list scrolls at 320 pt while its heading and explanation stay visible.
  Rows retain their geometry during disclosure; no new motion needs reduction.
- Historical feature/provider/model snapshots drive expenses. Unknown price is
  Unavailable, never free; ≈ denotes a calculated estimate and + excluded unknown
  costs. The permanent bottom explanation is removed at the user's request;
  help and model details explain these marks. ElevenLabs credits are never
  combined with dollars or inferred from a plan.

Update 2026-10-21: one feature table remains the cost surface. Soniox exact
request prices replace estimates when available; API delay/failure retains ≈
values. ElevenLabs uses recorded minutes and cached model credit/minute rates;
the separate workspace usage block is removed to follow the user's chosen
calculation policy. Rates are learned from credit/minute statistics, retained
across outages and never converted from USD. A new model without a rate stays
unavailable. Price checking leaves history visible, shows a small header spinner
and disables Refresh; failures show concise text near the period. Refresh,
period/date and calendar actions retain full-area hover/press, focus outlines
and inactive disabled states. Existing feature disclosures and layout stay intact.

Update 2026-10-21: ElevenLabs model details distinguish missing recorded audio
duration from a missing model rate, beside the affected historical model.
A durationless attempt cannot be priced by fetching a rate; it does not trigger
that lookup or a misleading rate warning. Unknown costs stay excluded with +
on partial totals. Known estimates are unchanged; no cost is inferred from a
failed connection or borrowed from another model.

The revised date popover has 310 pt offscreen fixtures in English/Russian and
both appearances. Calendar arithmetic covers leap days, DST, previous years
and future bounds; native month highlight snapshots cover rest/pressed/disabled
(with disabled/highlighted drawings identical), and native month actions reject
disabled future choices. Native year-editor Return is tested without selecting a day
or closing the popover. Physical day-grid keyboard navigation and VoiceOver
remain acceptance on the shared installed application. White selected-day text
on the shared #0064D2 fill has 5.59:1 contrast.

Offscreen native fixtures cover all four tabs at 600/900 pt, both appearances,
long model histories, custom dates, empty/error states and synthetic temporary-store
usage. Calculated text contrast on the card is 17.01:1 / 6.62:1 for primary/
secondary text in light appearance and 12.49:1 / 6.84:1 in dark appearance; the
selected-tab underline uses the primary text color. Physical pointer
transfer, keyboard/VoiceOver and live provider billing remain shared-app
acceptance. Tracking starts with this update; earlier history is not inferred.

## Model disclosure — 2026-10-20

The user chose compact function rows that open their settings on click. The
person comes to see which models each function uses; first they see the function
and selected model IDs, then they can open that function to change its routes.

- Closed headers are 48 pt high, with a 116 pt name column, a single-line model
  summary and a reserved 12 pt disclosure arrow. Paired speech/text routes show
  their model IDs together, separated by a dot, truncating in the middle.
  Full provider/model labels remain available through native help; accessibility
  announces both model IDs and expansion/setup state. Why: model names must not
  move other rows or cause uneven header heights.
- A click anywhere on the header, Space or Return opens settings directly below
  it. One function is open at a time; another click or Escape closes it. Escape
  returns focus to that header. No expansion or entrance animation is added.
  Why: configuration should stay compact and connected to the chosen function.
- The summary stays visible while open. The expanded controls use Speech/Text
  labels for paired routes and Model for a single route. Transport labels such
  as real-time, recorded and LLM with tools are removed from the main list.
  Model filtering still follows the unchanged internal feature modes.
- Selected model IDs are derived directly from the saved routes. Changing or
  removing a route updates the summary; opening/closing rows writes no route.
  Unselected routes show Choose a model and retain the existing warm contour.
- Actual errors, language warnings and recovery actions stay visible even when
  collapsed. Configuration-error links and Show expand the target function
  before scrolling to its stable group ID. Why: disclosure must not hide a
  required repair or break runtime links into Settings.
- Existing system typography, adaptive colors, card contours and 10 pt gaps
  remain. Expanded model fields have equal widths, with reserved space for the
  optional provider menu. Checking… and its progress indicator remain visible
  below the header even when closed; repeated checks are ignored until the
  pending check completes. Native menu behavior is retained.

Offscreen fixtures cover 600/900 pt content panes, both appearances and closed
and open paired rows, using temporary stores, synthetic keys and offline
providers. They do not establish physical keyboard focus, VoiceOver or native
menu operation on the installed app; those remain promotion acceptance.

## Independent subtitle models — 2026-10-20

The user requested both subtitle model roles in Settings and explicitly chose
an independent subtitle LLM. The existing compact disclosure stays: one
Subtitles header summarizes both model IDs and opens Speech then LLM selectors.
Text Translation retains its own row and route. Why: changing the text
translator must not change the model used by live subtitles.

Keep 48 pt headers, existing equal-width model controls, theme colors, keyboard
disclosure and visible errors. Both subtitle error links open this same group;
Speech and LLM prefixes identify the required repair. No new animation is added.
Existing subtitles keep their prior model/provider once at migration; clearing
the new LLM never reconnects it to Translation. Offscreen fixtures cover closed
and expanded Subtitles at 600/900 pt in both appearances. Native menu/focus and
real provider output remain acceptance in the shared app after promotion.

## Screenshot permission — 2026-10-20

The user requested a screenshot access entry in Settings -> Permissions.
Keep the existing permission group, MacRow and MacButton: this is one
more permission in the same workflow. A persistent explanation names
screenshots and tells them to finish current work before a macOS-requested reopen.

Only clicking Allow requests access; a denial
opens the system privacy pane. Returning to the app and Refresh reread access
without prompting. A missing grant never blocks launch or Drop. Existing native
button focus, keyboard activation, semantic colors and scroll behavior apply;
there is no new hover-only action or animation.

### Permission row status — 2026-10-20

The user requested one quiet indicator instead of dot chips and differently
labelled buttons. All three permissions use the same trailing slot:

- Granted: a 22 pt green `checkmark.circle.fill`, with no button or status chip.
  The icon exposes the permission name and Allowed to accessibility.
- Missing, not requested or denied: one Allow button, with the permission name
  in its accessibility label. Existing request handlers still choose the native
  permission prompt or the appropriate System Settings pane.
- The 60 × 26 pt slot keeps row height and text wrapping stable when access
  changes. The adaptive success color retains contrast in both appearances.
  No motion or hover-only information is added.

Offscreen native fixtures cover all granted, all missing and mixed access in
light/dark at 739 and 1059 pt content widths (the existing 960 and 1280 pt
Settings shells). Real TCC prompts, keyboard focus, VoiceOver and post-promotion
refresh remain installed-app acceptance. This presentation assumes the circled
checkmark is recognizable without a visible Allowed label.


## Meetings overview — 2026-10-20

The user approved the Overview composition: recent meetings first, History
beside the screen title, and room below for future Meeting Assistant presets.
The person comes to reopen a recent note; first they see the newest five
meetings, then they can open a note or browse the complete history.

- Keep one source, selection and refresh path for overview and history.
  Why: continuing a call, deleting a meeting and opening a notification must
  describe the same meeting in every surface.
- Show five meetings in descending start time, with a date/time on every row.
  Why: the overview should be quick to scan without losing temporal context.
- History keeps every date-grouped meeting. The header stays visible while
  scrolling. Back from a note returns to the page that opened it; the Settings
  Meetings entry and direct note links use the overview as their parent.
  Why: browsing older notes must not repeatedly reset the user's context.
- Reserve extension through the overview's vertical section layout, without
  empty Meeting Assistant panels, preset settings or new persistence yet.
  Why: unfinished controls would imply that the assistant is already available.
- Use the current adaptive Settings tokens and the system font. Screen title is
  23 pt semibold, section headings 13 pt semibold, titles 13 pt medium, dates
  and statuses 12 pt. Titles wrap to two lines; full text is available through
  the native help tooltip. Rows have 14 pt horizontal and 13 pt vertical insets.
  Why: long Russian meeting titles need room while date/status remain readable.
- Each row is a native Button with stable hover/selection geometry. Preserve
  deletion's context menu, status restrictions and confirmation. Return to the
  list requests keyboard focus on the selected meeting, or navigation if it
  is outside the overview. No entrance or navigation animation is introduced.
  Why: keyboard use and repeated navigation should stay immediate.
- Initial loading, a successfully empty store and a failed load are distinct.
  Retry preserves the last readable list until a new load succeeds.
  Why: a storage error must not suggest that saved meetings disappeared.

The native supported window remains at least 800×600; renders inspect both
800 pt and a 600 pt Settings content pane, including long names, processing,
failure and empty states. Offscreen renders do not establish real keyboard
focus, compositor appearance or screen-reader behavior on the installed app.
In the original feature fixture on a synthetic dark 0.12-gray backdrop, normal title/date contrast is 11.44:1 /
5.44:1, selected title/date/status contrast is 7.34:1 and unselected failure
text is 4.53:1. Selected and hovered statuses/dates use the primary text color
to retain contrast over their brighter fills.
Five recent meetings and the future preset details remain product hypotheses
to revisit after normal use; actual presets require a separate feature.

Combined with adaptive Settings, native overview/history/error fixtures also render in light and dark appearance on the matching page surface. Semantic token contrast remains covered by MacSettingsThemeTests.


## Settings appearance and switches

### Purpose and attention

Settings is a working surface for configuring providers, shortcuts and optional
features. The user first identifies the selected section, then reads each setting
and its current value, then changes that value without losing context.

### Direction and layout

- Use iOS inset groups within the existing macOS sidebar window. Groups describe
  related settings. In API & Models, independently configured functions have
  separate contours and a 10 pt gap, so their setup states do not run together.
- Keep the current tabs and navigation. Sidebar rows use text alone, following
  the user's 2026-10-20 request to remove the colored icon tiles.
- Use 14 pt group corners, 14 pt row insets and 12 pt vertical row padding.
  Shared dividers are one point, inset on both sides, with 2 pt breathing room
  above/below. Long descriptions wrap instead of shrinking the control.
- The window keeps its 960 pt minimum width; verify the minimum and a larger
  1280 pt window. This desktop window does not have a phone-width layout.

### Typography and color

Use the system font: 22 pt semibold page titles, 13 pt regular row names,
11.5 pt explanations, 12 pt semibold group captions. Keep Cyrillic legible.

`MacSettingsTheme` owns dynamic AppKit colors shared with SwiftUI. Light surfaces
are grouped grey with white groups; dark surfaces are charcoal with lighter
groups. Text, separators, fields, status text and menu labels all resolve for
the current system appearance. The open Settings window follows appearance
changes without saving an override or changing any feature preference.

Blue labels indicate navigation/actions; filled blue actions keep white-label
contrast. Green/red/amber status text has separate light and dark values.
`MacSettingsThemeTests` measures normal text and status labels at 4.5:1 or better
against their intended surfaces. Disabled controls are explicitly dimmed.

An unconfigured model function uses a static orange outline and a soft 5 pt
outer glow (12% light, 18% dark). The outline has at least 3:1 contrast on both
the row and page surface; the glow is decoration, never the only boundary.
The normal `Choose a model` action stays visible. `Not set` and warning triangles
are removed from these rows; actual error explanations and recovery actions
remain text. Native accessibility exposes `Needs setup`; the picker group also
explains that a model and its provider key are required. Reduce Transparency
removes the glow while preserving the solid contour. There is no pulse or
attention animation; Reduce Motion also disables programmatic row scrolling.

### Switch reference and behavior

The user supplied `toggle-switch-glass.tsx` on 2026-10-20. Adapt its green track,
white pill thumb, short spring, press feedback and drag-to-set behavior directly
in SwiftUI; the native app does not acquire a React runtime or npm dependencies.

- Settings switch: 60 × 33 pt with a 35 × 28 pt thumb. The island retains its
  compact 30 × 18 pt blue switch because it must fit its existing control row.
- Click/Space toggles. Left/Right select Off/On on the focused control. Drag
  settles at the nearest endpoint; a quick swipe uses its projected direction.
  A drag commits once on release. Escape cancels a drag.
- External binding changes remain authoritative. Disabled controls cannot change
  state, including through accessibility. A native Toggle accessibility proxy
  exposes the setting name and state, with a visible keyboard focus ring.
- Hover highlights the switch's full capsule without changing its geometry;
  disabled switches do not highlight. Press and keyboard focus retain their
  separate existing feedback.
- Only thumb position/press scale animate: a short spring (0.22 s response,
  0.88 damping) and a 0.1 s press transition. Reduce Motion removes these
  movements; Reduce Transparency uses an opaque white thumb. Native glass is
  guarded for macOS 26, with a simple highlighted thumb on macOS 14/15.

### Agent permissions wording

- The existing action switch is named **Bypass mode**. The person comes to
  let the agent work without interruptions; the label matches that intent
  instead of suggesting only that tools exist. There is one control, bound
  to the existing preference, with no migration or default change.
- The visible explanation states both outcomes: On runs file edits and
  commands without approval using the Mac user's permissions; Off blocks
  those actions. It also states that changes apply to the next request.
  Why: OpenCode controls local approvals; OpenRouter routes model requests.
  Off must not imply an interactive approval mode that Whytap does not offer.
- Keep the established row, wrapping subtitle, switch size, keyboard and
  accessibility behavior. Live pointer and keyboard acceptance remains in
  the single installed app; offscreen renders only establish text/layout.
- Verification: eight offscreen images cover On/Off in light/dark at
  739 × 560 and 1059 × 760 pt content sizes (960/1280 pt Settings windows).
  Theme tests verify text contrast ≥4.5:1 and control borders ≥3:1.
  VoiceOver remains a live check because AppKit omits even the native switch
  from invisible-window accessibility trees.

### Embedded surfaces

The island stays dark. Toolbox embeds actual island editors inside explicitly
dark previews; the Toolbox navigation, captions and catalog follow the Settings
theme. This keeps the preview faithful and prevents white overlay text from
disappearing on a light settings surface. API hints and key/model sheets follow
the parent window's system appearance.

### Verification and hypotheses

Offscreen render tests use temporary fixture stores and offline providers and never
show a window, start an app runtime, record audio or request permissions. They
cover both appearances at 960 × 560 / 1280 × 760 pt, Cyrillic descriptions,
disabled switches, fields and notes. A hosted-window test changes appearance
without rebuilding its root. Screenshots are visual evidence only; live keyboard,
drag and Reduce Motion/Transparency remain explicit acceptance checks in the shared
installed app. Older-macOS fallback needs device acceptance.

### Decision log

- 2026-10-20 — Follow system appearance automatically: the user asked for light
  and dark support, so a separate theme preference adds unnecessary state.
- 2026-10-20 — Adapt the supplied component to SwiftUI: existing Settings is
  native, and retaining native focus, bindings and accessibility matters here.
- 2026-10-20 — Group rows with consistent insets: this brings the requested iOS
  settings rhythm while preserving the established macOS navigation.
- 2026-10-20 — Replace unconfigured model alarms with a warm contour and soft
  glow: the user requested a calm setup cue, plus clearer separation of rows.
  Each model function gets its own contour because its routes form one setting.

## Text-only Settings sidebar — 2026-10-20

The user requested removal of the sidebar icons and animation on hover.
Keep section names, order and 220 pt sidebar width. As amended 2026-10-21,
rows have 30 pt hit targets, 4 pt gaps and 10 pt vertical list insets. The ten
sections and pinned footer fit at the minimum Settings size without scrolling;
the ScrollView remains a fallback if the section list grows. Why: the user
requested smaller buttons so every section is immediately visible.
Removing the icon and gap gives labels 180 pt instead of 144 pt, without
changing text size or moving any row during interaction.

- Hover fades the rounded background in/out over 140 ms with ease-out. It
  signals which row is clickable, accepts reversals immediately, and affects
  only background opacity. Text and hit geometry stay fixed.
- Unselected rows use the existing adaptive hover color at 85% opacity; the
  selected blue row gets a 10% white overlay (white-label contrast 4.67:1).
  Selection remains recognizable during hover.
  FAQ and Quit use the same feedback. Existing navigation highlights remain.
- Reduce Motion makes the hover response immediate. Native Button actions,
  keyboard access and focus are preserved. Press adds a stronger full-row
  fill; keyboard focus has an inset outline, and the selected row exposes its
  selection to accessibility. Disabled buttons dim and suppress hover/press/focus
  highlights. No function requires hovering.

Offscreen native Settings fixtures cover the minimum 960 × 560 pt and larger
1280 × 760 pt window in both appearances. Physical hover, focus/VoiceOver and
system Reduce Motion acceptance remain on the shared installed app after
builder promotion; the feature session does not launch another app instance.
Offscreen cacheDisplay captures intermittently omit sidebar glyphs, including
the selected label on the unmodified base. These images establish layout only;
check every label in both appearances on the installed app.

## Case and persistent hover menus — 2026-10-20

The person comes to find a key, then use it or configure access. The existing
native SwiftUI/AppKit surface, notch-derived width and 320 pt Case viewport
remain. Search, projects and keys get the available space.

- Connected apps appear as their icons, without a status lamp or text caption.
  The icons describe saved Case registrations, not whether a process is running.
  Clicking an icon opens access settings; an empty state has a link icon for
  setup. Native help and accessibility name the app and action. A horizontal
  strip supports more registrations without widening the drawer.
- Access explains Approve/Bypass in one line. The Touch ID requirement and
  shared-terminal Bypass consequence remain concise and visible where relevant.
  Back uses white at 88% opacity, matching the island's navigation.
- Case has no Doppler import action, integration, or background synchronization.
  The requested one-time transfer is operational work; removing the integration
  does not establish that the user's real keys were transferred.
- Every explicitly opened inline menu stays open through pointer exit, including
  Case authentication success/denial. Back and normal selection retain their
  existing navigation; outside click or bare Escape dismiss the menu. The outside
  click still reaches its target. Native submenu and file-picker interactions
  temporarily suspend dismissal. Activity/preemption policy still wins.
- Root tools retain hover dismissal. Hardware brightness glances retain their
  two-second timeout and leave keyboard focus in the user's app. Entering the
  glance converts it to an ordinary persistent menu. Timers cannot dismiss an
  explicitly opened submenu. Search keeps its own focus behavior.

No new entrance animation or decoration is introduced. Existing density, system
font and motion settings remain. The app icons are 18 pt in 28 pt targets.
Offscreen native fixtures use synthetic names and values, widths 310/390 pt,
320 pt content height and a dark backdrop. They cover connected icons, long
names and access modes without launching an app runtime or requesting Touch ID.
White navigation has 14.28:1 contrast and the explanation 13.36:1 over the
synthetic 0.08-gray backdrop; the 60% footer has 7.12:1 there. These measurements
do not establish contrast on every live glass backdrop. Native event classifier
checks cover outside/inside clicks and bare/modified Escape; pure state checks
cover every inline mode, pointer exit, stale hover zones and brightness glances.

Actual keyboard focus, compositor appearance, menus/file pickers and physical
Touch ID remain acceptance on the one signed installed app after promotion.


# Backup: automatic synchronization — 2026-10-20

As requested on 2026-10-21, a short explanation above the status card states
the recovery purpose (keys, passwords and settings), local encryption, private
GitHub storage, automatic synchronization after the first backup and keeping the
recovery code. GitHub
receives ciphertext, not the recovery credential. Why: the status alone does
not explain what is protected or who can read the stored copy. Keep the existing
13 pt secondary text role and multiline wrapping; no new disclosure or setup
step. The native offscreen fixtures cover the longer content at 560 and 760 pt.
The shared MacButton style and the Backup GitHub link highlight the full hit
area on hover, use a stronger pressed overlay and show a separate focus ring;
disabled controls suppress those active states. Why: the user explicitly asked
for visible interaction feedback on 2026-10-21. These state changes add no motion
and preserve control geometry and existing native keyboard activation.
Colored-text buttons use a hover outline, strengthened on press, instead of
brightening their background. Why: the recovery-code action's dark-theme blue
text would drop from 4.92:1 to 3.59:1 on hover and 2.76:1 on press with the neutral
overlay. The outline keeps its text contrast unchanged and marks the whole hit
area. The state matrix includes this ghost action in both appearances.
The backup regression tests cover key-only automatic
sync and clean-profile recovery. Native offscreen renders cover 560/760 pt in
both already-supported Settings appearances and normal/hover/pressed/focus/
disabled control surfaces. The explanation has 8.35:1 dark and 5.94:1 light
contrast; white primary-button text stays at least 5.59:1 through active states.
Physical pointer, Tab navigation and VoiceOver remain shared-app acceptance.
The first code is shown once after upload. Leaving before completion retains
a visible Save your recovery code status, with a Save recovery code action;
subsequent Show recovery code uses the same ghost action. Both require Mac
authentication. Repeating Back up does not reveal the code. These states keep
recovery possible without claiming that merely showing the code proves it was saved.

Pause and resume (2026-10-21): once a copy reached GitHub, a separate card below
the status card holds an **Automatic backup** row with the shared MacSwitch; it
stays visible while GitHub is unreachable because local captures continue. Its
subtitle says the cadence ("At most hourly, only when something changed") with
the next check time, or "Paused. Back up still saves one copy and keeps this
off." Why: the pause was previously reachable only through Cancel during a sync
or a hidden preference, and Back up silently resumed it. A persistent setting
uses the macOS switch idiom rather than a one-shot button; it stays enabled while
a sync runs so it can cancel an automatic capture. The status card's paused hint
is removed. Offscreen fixtures cover paused/on states at 560 pt and the synced
state at 560/760 pt in both appearances; live switch pointer, keyboard and
VoiceOver checks remain installed-app acceptance. WHY:
`.project-docs/decisions/2026-10-21-backup-capture-pacing.md`.

The user opens Backup to confirm their data is protected, then open its GitHub
copy or restore it. The existing native Settings card, primary actions, system font
and dark theme remain. Direction is supplied by the user: a compact status with
a backup link, without the connection caption or date. Use a 13 pt medium status
and a 12 pt GitHub link on one row, existing green only for verified sync, existing
neutral text for waiting/paused, and the existing actionable error banner.

The row never hides the link behind hover. Link participates in native keyboard
navigation, opens GitHub Releases and has an explicit accessibility label.
Status changes add no animation; busy/cancel and restore-code focus retain their
existing behavior. The scheduler waits for idle; edits during upload remain
pending. The status must not imply success from a historical upload alone.

Offscreen native fixtures cover 560 and 760 pt synchronized states, connection,
recovery code, restore, pending, syncing, paused and error without presenting a
window or uploading real data. The synchronized label and GitHub link have
6.95:1 and 11.43:1 contrast on the synthetic native dark card (sRGB #323235).
The screenshot matrix was inspected after successful render tests. Live pointer/keyboard checks remain acceptance on
the one installed app after builder promotion. Existing Settings is a dark
surface; a new light-theme system is outside this change.

## Planner: tasks and calendar — 2026-10-20

### Feature connections — 2026-10-21

The user comes to connect a calendar capability. First they see the provider's
calendar feature, its current state and permissions. Then they can connect that
feature, add an account or disconnect an existing one.

- Integrations keeps its GitHub section and adds Google Calendar, Outlook Calendar,
  Apple Calendar and Zoom Calendar. Each provider has one grouped card with a
  13pt title, 11pt status, 12pt permission copy and account actions. Why: separate
  capabilities must not imply access to unrelated email, recordings or transcripts.
- Connect starts the provider browser/macOS prompt directly; there is no
  intermediate sheet, account-name field or Advanced setup. Native client
  configuration belongs to the build. Why: a feature connection is a user task;
  app registration is an owner task.
- Pending Google verification and Zoom publication are visible before interaction.
  Their shared-client action is disabled; existing accounts retain Disconnect.
  Why: the user explicitly rejected sending public users through Google's warning.
- While browser sign-in is active, all additional connect actions are disabled
  and its provider shows progress. Cancel closes the browser receiver; failures
  stay inline on the provider card. Leaving Integrations cancels its flow.
  Sign-in completion/cancellation releases restart/restore
  deferral. Why: Settings and Planner must share one connection flow.
- A backup operation, staged restore or pending backup maintenance also blocks
  new calendar connection changes, with a reason above the cards and inline after an attempted connection.
  Why: restored account metadata must not overwrite a newly connected account.
- Disconnect uses a native confirmation alert and keeps original provider events.
  Corrupt connection metadata stays preserved with a visible error. Long labels
  and permission/error text wrap. Why: recovery must not silently discard accounts.
- Scoped Integrations buttons/links share full-area hover,
  pressed and 2pt keyboard focus feedback. Disabled controls dim and ignore hover
  and press. Only color transitions animate (80–100ms), with no animation under
  Reduce Motion. Why: the user requires visible interaction feedback consistently.

Offscreen synthetic fixtures cover 500/739/1059pt, both appearances, direct
connection progress/cancellation and inline errors, pending states, long account labels, malformed metadata
and forced normal/hover/press/focus/disabled surfaces. Reduced Motion is injected
into the same control rendering used by the native environment. These fixtures
do not prove physical keyboard navigation, live browser consent or system alerts.
Static Reduce Motion images check layout only; the native preference and temporal
behavior remain live acceptance. Code review verifies animations become nil.
Calculated contrast: white primary labels 5.59:1 normal, 7.08:1 hover, 8.40:1 pressed;
secondary text 6.62:1 light / 6.84:1 dark; warning copy 6.54:1 light / 8.69:1 dark.
Focus blue against secondary control fills is 4.79:1 light / 3.22:1 dark.
Provider approval and installed-app acceptance remain separate.
The independent Claude Opus 5.5 review led to the reverse restore gate, a single
metadata error, truthful unavailable accessibility labels and clearing an old
desktop secret when the client ID changes. Zoom's missing shared registration
deliberately retains the known public publication status; independent source-user
setup remains available through Planner.
WHY: `.project-docs/decisions/2026-10-21-calendar-integrations.md`.

### Existing Planner and To-do decisions

The person comes to write down a task or find the next appointment. First they
see the task list or selected day, then they can add/edit local content or join
a connected meeting. Calendar retains its native sidebar and detail pane.
The user subsequently selected a compact inline To-do list; that supersedes
the original window entry for the To-do catalog action (details below).

- The earlier Calendar window design below is superseded by the 2026-10-21
  inline Calendar decision. To-do opens in Hover. Historical rationale: the month grid needed
  desktop space; quick task capture needs a small surface. Saved slots stay intact.
- Use the system font, native controls and semantic surfaces. Titles are 28pt
  bold, object names 13pt, metadata 11–13pt. MacSettingsTheme.text2 keeps metadata
  readable in both appearances; the selected date uses the shared #0064D2 fill
  with white labels. Why: both Russian text and calendar counts remain legible.
- Task entry stays above the active/completed list; Return adds it. Search, edit,
  complete/reopen and delete actions are visible without hover. Delete asks first.
  Why: this is a short repeated workflow, so secondary actions cannot shift rows.
- Calendar retains a month grid and a scrolling day agenda. Minimum height leaves
  at least one agenda row; remaining events scroll in place. Local event editing
  uses a sheet, external event details offer Join/Open original. Why: the source
  calendar remains authoritative for connected events in the first version.
- A sheet remains attached when another tool hotkey opens Planner. Account sign-in
  shows browser progress, cancellation and actionable error text. Closing the main
  window ends polling. Why: navigation and closing must not lose drafts or leave
  hidden network work running.
- Validation errors belong to their editor and disappear with it. Moving Start
  keeps the event duration, and All day preserves its prior times of day. Notes
  and day counts have explicit accessibility labels. Why: correction and date
  changes must not contaminate another editor or silently discard entered times.
- A registered build asks the user to select a calendar provider and sign in. Native
  client settings are advanced setup; an unregistered build exposes that setup
  honestly. Why: owner registration is a packaging responsibility, not a repeated
  task for every account holder.
- Planner/To-do visibility or a retained new-task draft defers update restart and restore.
  Backups continue to capture saved data. Why: protecting edits must not pause all
  backup synchronization while someone keeps their calendar open.
- No additional motion is introduced; native focus, keyboard shortcuts, sheets
  and accessibility labels remain. Why: repeated editing should stay immediate
  under Reduce Motion as well as ordinary settings.

Offscreen synthetic fixtures cover empty/populated tasks, the month/day calendar,
connect and event editors, at 820 and 980pt in both appearances, plus calendar
visibility-limit feedback in both appearances. Measured metadata contrast is 6.62:1 on the light surface; white selected-date
labels on the shared blue fill are 5.59:1. Separate Codex and Claude Opus 5.5 reviews
inspected layouts and data/backup contracts. The Claude review led to repairs in
token backup behavior, editor errors, date editing, accessibility and packaging
configuration discovery. Real OAuth, system permissions, VoiceOver, physical keyboard/focus and
compositor appearance require acceptance on the one installed application. The
priority of a unified calendar over separate provider windows remains a product
hypothesis to revisit after ordinary use.

# Notification cards — 2026-10-20

The user comes to notice a completed event and open its result. First they see
the source, title and short message. They can click to open the destination or
hover to keep the card visible while reading.

- All sources use the existing left-side card. Small notifications and the type
  selector are removed at the user's request; older icon sources become cards.
- Hover retains the 3% enlargement, brightness and paused expiry. It grows left
  and down from the top-trailing corner, preserving top alignment and the 8 pt
  island gap. Transparent panel overflow fits the whole card; the click region
  follows its transformed size. The inset border stays within the rounded shape.
- Each source has a separate labeled Notification sound row using the existing
  native menu. Off is the default; Glass, Ping and Pop preview when selected.
  A separate row keeps long source names and the enable switch readable.
- Existing type, spacing and colors stay in use. Keyboard and VoiceOver can
  reach the sound selector. Reduce Motion suppresses hover growth and transition
  animation. Live pointer/audio acceptance follows
  promotion of the one signed installed app; offscreen renders use fixtures.

Offscreen native checks cover 560 and 760 pt settings widths, enabled/disabled
sources, idle/hover/reduced-motion card states. Pixel bounds prove that the
card really enlarges while remaining inside its panel with rounded edges. Synthetic card text contrast is 11.44:1 for primary
and 5.44:1 for secondary text on the sampled dark backdrop. This does not claim
live pointer, VoiceOver or audio-output acceptance before installed promotion.

Combined integration also renders notification Settings in both system appearances using the shared adaptive tokens; island cards retain their dark appearance. The earlier Backup fixture measurements above describe that original dark fixture, while current shared Settings follows the Settings appearance section.


## Case Connect, project scope and search — 2026-10-20

The person comes to find a key or give an agent access to it. First they see
key search, their projects and the connected app icons. Then they can use a
key, add one explicitly, or choose Connect and review an agent's rights.

Keep the existing native SwiftUI/AppKit surface and 320 pt viewport. The user's
chosen flow is Connect → agent → rights, and an existing icon → that agent's
rights. No alternative composition or decorative screen is needed.

| Component | Behavior and reason |
| --- | --- |
| Search | Finds project and key names/descriptions, including empty projects and General. A project match shows all its keys; a key match shows just matching keys under its project. The project with the best match (own or a key's) comes first; equal ones keep project order. A query word that starts a word of a project name lets the rest of the query match that project's keys. + Key stays available in project results. Return cannot create a key; name/value fields open separately after + Key. Empty results say Nothing found. |
| Connected icons | Open the selected registration directly. Connect stays visible beside the horizontally scrolling strip, including when empty. Codex/OpenAI uses blue, Claude/Anthropic orange, Cursor a white halo. Hover/focus change color and glow without changing geometry; keyboard focus has an outline. Reduce Motion removes the short opacity/color transition. |
| Client picker | Discovers installed OpenCode, Claude Code and Cursor only after Connect (no Codex). Shows bundled brand marks, loading, no installed clients or already-connected states. Selecting a client opens a draft; nothing is registered until Connect on the rights screen. The arbitrary program picker is removed. |
| Rights | Default Accept asks before use; Bypass allows use without prompts. All projects includes future projects (explained in native help); Selected shows searchable checkboxes and denies unchecked projects at the broker. Filtering preserves the full draft selection. Existing per-project overrides remain visible/editable. An empty saved scope closes access; a new connection needs at least one project or All. |
| Save | One transaction stores mode and scope; registration, widening access and enabling Bypass require Touch ID. Pending authentication disables edits and Back. Failure preserves the draft and explains recovery; connector errors remain visible after registration, with Retry setup reusing the same registration and rights. |
| Back / disconnect | Back discards unsaved rights. Disconnect revokes access before editing client config. Existing island outside-click and Escape dismissal still apply. |
| Approval | The request shows the command, app, project and key names. A native digits-only field changes temporary Bypass to 1–240 minutes without arrows; the separate temporary Bypass button and physical A use that value. The bottom row contains Deny (N)/Allow (Y) only; Escape also denies outside editing. Default 15 is restored for the next request without selecting the field. Grants are scoped to app/project and disappear at expiry, policy change or restart. |

Display metadata and project sections are rebuilt when the vault changes and
reused for renders. Search only filters/ranks metadata; values never enter its
index. The list is lazy so closed projects and offscreen rows do not create a
full hierarchy on every keystroke. Touch ID remains the opening gate.

Validation uses offscreen native fixtures, synthetic names and values, and fake
authentication. The installed application is reserved for acceptance through the
shared builder. These fixtures do not prove live keyboard focus or glass
contrast on every desktop; those remain runtime acceptance checks. The user's
reported lag may have been concurrent build load, not a confirmed app fault.


### Case search correction — 2026-10-20

A newly created empty project must be findable before it has keys. The user's
report corrects the earlier key-only interpretation: search is separate from
creation and includes projects too. Project matches reuse cached full sections;
key-only matches remain filtered. Search results expose + Key so the found
project can be used without clearing the query manually. Adding explicitly
expands that project before leaving search; existing cached metadata and
lazy rendering remain.

### Case search ranking — 2026-10-21

Sections follow each project's best match instead of the alphabet, so the
project holding the wanted key is scanned first. `whytap github` finds
whytap's GITHUB keys, below any key spelling out the whole query; a project
matched only by its first word then shows just its matching keys.
Later query parts that start a key-name word add to a partial match; parts of three or more letters may be one typo off (`github_lan` finds GITHUB_LENDING_KEY). WHY:
`docs/decisions/2026-10-21-case-search-project-ranking.md`.


## Compact To-do in hover — 2026-10-20

The user chose one small list, with immediate capture and completion. First see
active tasks and the input; History is secondary. This replaces only the To-do
catalog entry's former large-window direction.

- Use the existing island width (including 310pt) and a 290pt content band inside
  the shared glass drawer. A 26pt header contains Back, To-do and History. Rows
  scroll within the panel; titles use 12pt, history dates 10pt. Why: the list stays
  compact and its native pointer band matches visible content.
- Input has a stable 32pt height and a visible focus outline. Return adds; empty
  input does nothing; invalid input or failed persistence keeps the draft.
  A successful Return scrolls the new row into view, including in a long list.
  Opening the tool explicitly acquires keyboard focus, ordinary hover does not.
  Why: capture takes one action without stealing focus from the user's editor.
- Clicking the entire task row toggles completion. Completed rows stay at the
  bottom during this opening, with a checkmark and strikethrough; the next opening
  shows active tasks only. History sorts completed tasks by completion time and
  supports reopening. Why: accidental completion is reversible before closing.
- History shows completion date and local time. The optional persisted timestamp
  decodes old archives without migration; legacy unknown times stay explicitly
  unknown. Reopening clears the timestamp, and a later completion writes a new
  one. Why: history must describe an actual action rather than an invented date.
- Rows keep fixed geometry on hover. A native help tooltip exposes the full title;
  accessibility labels retain the full title and completion state/date. Native
  buttons and text input provide keyboard access. Why: long titles remain readable
  without shifting the next target. Native keyboard navigation to buttons follows
  the macOS Keyboard Navigation / Full Keyboard Access preference.
- Back returns to tools; Escape/outside click closes through the existing menu
  observer. Pointer exit keeps an explicitly opened panel available. The input
  draft survives dismissal and defers restore/update restart until saved or
  cleared. Ordinary backups still capture saved tasks. Why: closing must not
  silently discard text or allow a restore to replace it.
- No task movement animation; Reduce Motion also disables panel-mode animation.
  White text at 76% or above is used for secondary text on the dark hover surface.
  Why: completion remains precise and text retains a readable contrast.

Validation uses temporary archives and synthetic offscreen fixtures at 310, 360
and 500pt. Native text-field Return dispatch was exercised in an invisible window,
without activating the app. The history-date fixture measures 9.67:1 against its
row background (RGB 211/41). Physical keyboard/VoiceOver, native tooltip timing and compositor glass
appearance require acceptance on the one installed application.


### Case Connect polish — 2026-10-21

The person comes to connect an installed agent. First they see OpenCode and/or
Cursor with their logos. Clicking one opens its access mode and project scope;
only Connect commits the draft after authentication. The user chose this flow.

- Offer OpenCode then Cursor, only when their existing locators find them and
  they are not registered. Do not offer a program chooser, Claude Code or Codex
  for a new connection. Keep all saved legacy registrations and their policy
  editors. Why: limit new setup to the two requested integrations without
  silently revoking existing rights.
- Bundle the official OpenCode mark and Cursor 2D cube as square transparent PDF
  templates, reused by the picker, policy header and connected strip. Why: the
  same agent should remain recognizable throughout setup, even in fixtures or
  after its app is removed. Sources: [OpenCode](https://opencode.ai/brand) and
  [Cursor](https://cursor.com/brand); SVG sources live beside their PDFs.
- Use 44 pt logo/name/disclosure rows, 22 pt marks, 10 pt corners, system 12 pt
  medium labels and the existing white-on-dark island palette. Hover changes
  the fill; keyboard focus adds an outline without moving the row. Native
  buttons expose the agent name and setup action. No new animation is added.
- Put Accept/Ask first and Bypass/No prompt inside the mode choices, with an
  outline for selection and amber Bypass. Keep the shared-terminal consequence
  visible inside this group when Bypass applies. Why: the decision and its
  consequence should read together, without detached explanatory lines.
- Put all/selected project controls and their checklist in a separate
  group. All includes current and new projects, explained in native help; unchecked projects
  remain denied. Existing project overrides get their own group. Why: scope
  must stay clear without a loose footer between unrelated controls.
- The primary Connect/Save button contains a Touch ID glyph. Native help and its
  accessibility hint explain which changes require authentication. Why: this
  explanation belongs to the commit action; normal mode/scope navigation does
  not request authentication. Errors and retry remain visible above the editor.
- Loading and both empty states are contained surfaces. With no installation,
  explain to install OpenCode, Claude Code or Cursor and reopen Connect; with saved supported
  registrations, point to their icons for editing rights. No client config,
  secret, route or vault migration changes are part of this polish.

Validation uses synthetic native offscreen fixtures at 310/390 pt and the
320 pt viewport, fake authentication, isolated connector files and every
installed/absent combination of the offered clients. Calculated contrast on the synthetic
0.08-gray backdrop: group headings 10.56:1, selected/unselected mode text
10.15:1/9.58:1, picker labels 13.19:1, selected-mode border 4.35:1 and primary
button text 4.52:1. These do not establish contrast on every live backdrop.
Physical focus/VoiceOver, real Cursor
reconnection and live glass contrast remain shared-app acceptance after the
builder promotes the reviewed source. Grouping and logo recognition follow the
user's chosen direction; they have not been tested with other people.


Case control feedback follow-up — 2026-10-21: every custom/plain access control,
including Back, retry, mode, scope, project rows, disconnect and Save/Connect,
uses a shared full-target hover overlay, stronger pressed fill and keyboard-focus
outline. Disabled controls are dimmed and ignore hover/pressed/focus highlights.
Why: the user requires visible evidence of interactivity, beyond a button shape
or tooltip. Picker rows use the same feedback family. Offscreen state fixtures
cover normal/hover/pressed/focus/disabled at 310 pt; physical focus remains
shared-app acceptance. No authorization or registration behavior changes.

Case access polish — 2026-10-21: the user requested thin horizontal rules between
the "Access mode" / "Projects" headings and their controls. Keep the existing
groups and 7 pt spacing; use a 1 pt white rule at 14% opacity. Remove the visible
"Current and future projects" caption. "Selected projects" adds a 28 pt search field with a
loupe and clear action, matching every word against project names/descriptions
without case or diacritic sensitivity. General remains searchable. No matches
shows "No matching projects". Why: a long project list needs filtering while the
current layout already satisfies the user. Search affects only visible rows;
hidden selections remain in the saved draft. The field has full-area hover,
native text editing and a focus outline; clear and project rows retain shared
hover/press/focus/disabled feedback. Escape keeps the existing panel dismissal.
Synthetic offscreen fixtures cover 310/390 pt, long names, matches, no matches
and disabled controls; native field edits verify search never writes the scope.
On the synthetic 0.08-gray backdrop, the search border is 3.38:1 at rest and
3.07:1 on hover; its 70%-white placeholder is 6.99:1 at rest and 5.95:1 on hover.
Physical input and compositor contrast remain installed-app acceptance.

Case English copy — 2026-10-21: the user chose to translate Case before its
motion video, so every visible Case string, accessibility label, tooltip, error
and connector problem is English, in the short sentence case of Settings and the
hover tools. Case, Connect, Accept, Bypass, General, key names, layout and
behavior are unchanged. Touch ID reasons are lowercase verb phrases ("open
Case", "connect Cursor to Case") because macOS shows them as "Whytap is trying
to <reason>." Hover search keeps the old Russian aliases and adds English key
terms. Why: Case was the only Russian surface in an English app and website.

## Case approval controls — 2026-10-21

The person reviews a key-use request, then declines, allows once or grants
short temporary access. First they see the agent, project/key names and command.
The user chose a separate temporary Bypass button beside its numeric duration,
with only Deny and Allow in the final row. Keep the native black island card.

- Keep the 310/312 pt width and system type roles (12.5 pt header, 11.5 pt keys
  and buttons, 11 pt monospaced command). The command stays one line; native
  hover help and accessibility expose the full original string including line
  breaks. Why: the compact summary must remain inspectable before approval.
- Temporary Bypass is an actual capsule button with the physical A
  hint. The duration is a 34×24 pt native text field followed by min, without
  arrows. Default 15 and supported 1–240 stay unchanged. Why: direct typing
  replaces repeated stepper clicks and removes the third competing bottom action.
- Invalid/empty drafts remain editable, show warning text color and disable the
  temporary action. They never change the grant duration; blur/Return restores
  the last valid number. Escape restores the pre-edit number and does not deny
  the key request. Return only finishes editing. Why: a partially typed duration
  must neither grant access nor silently authorize a different displayed number.
- The nonactivating panel does not take keyboard focus when it appears. An
  explicit field click or keyboard/AX first responder enables native editing.
  Approval hotkeys are suspended before the first typed character; clicks on
  the other actions still work after the existing quiet period. Finish editing,
  timeout, hide or replacement by a queued prompt releases the old field editor
  and key status. Why: numeric entry must not trigger approval answers or trap later
  typing in a panel that no longer contains the original field.
- Buttons visibly highlight their full capsule on hover, change fill while
  pressed and show a keyboard-focus outline. Disabled/unarmed buttons dim and
  suppress active hover/pressed feedback. The number field shows hover and focus
  borders. No geometry shifts or new motion are added; the existing arming fade
  respects Reduce Motion. Why: every interactive target must show feedback.
- Tool ergonomics: names-only `case_list_keys(query:)` matches all query words
  across authorized key name, description and project name, ignoring case and
  diacritics. Instructions show the existing `case run --only KEY` route for a
  known key; ambiguity retains explicit project choice. Why: agents can find a
  needed key directly without fetching all projects or changing value delivery.

Native offscreen fixtures cover short/long/queued/no-timed/unarmed cards at
310/312 pt. Focused controller/native-field tests cover keyboard first responder,
editing during arming, invalid text, Return/Escape, timeout and queued replacement
without ordering a panel front. Synthetic MCP tests confirm metadata-only search;
broker authorization and secret delivery remain unchanged. Physical pointer,
VoiceOver, native tooltip timing, text selection/IME and real Touch ID remain
shared-app acceptance after promotion. A real authorized key-presence check on the
previous installed build returned only a static presence confirmation; it does
not validate this new UI. No secret value was printed or sent over the network.

Numeric approval follow-up — 2026-10-21, superseded: the earlier change to
1/2/3 misunderstood the request. The user meant numeric-only duration input,
while keeping Y/N/A answer keys. The correction below owns current behavior.


Case English copy and interaction feedback — builder review,2026-10-21:
Use English for Case panels, creation/editing/recovery messages and approval
copy while preserving IDs, rights, authentication, timing and data. Answer keys
follow the later corrected Y/N/A contract below.
The translated project headers, add-key rows, icon actions, reset/retry,
create/submit and delete-confirm controls use the existing Case access button
feedback: full-area hover, press and keyboard focus; disabled controls dim and
show no active hover. Text fields highlight on hover/focus and their full
capsule focuses the existing editor; bindings, submission and cancellation stay
with their callers. Edit fields keep their own native focus state.
The armed reset copy accurately says a new Case is created and the old encrypted
file is retained, matching CaseVaultStore.reset; it does not promise recovery
without the original key. The two-step reset and its handlers are unchanged.
Final English offscreen fixtures and the combined full suite are builder gates;
physical pointer/keyboard/VoiceOver and the real Touch ID panel remain separate.

Approval minutes correction — 2026-10-21: restore Y for Allow, N for Deny and A
for temporary Bypass; Escape denies outside duration editing. Only the minutes
editor rejects letters and mixed pastes, using native partial-string validation.
Empty/out-of-range digit drafts retain existing recovery; Return confirms and
Escape restores the previous duration, without answering the request.
The card is the panel's neutral initial first responder. Showing a new request
clears duration editing and releases key status; the field gains its bright
outline/selection only after explicit focus. Why: selecting 15 on appearance
would make the request look like an active editor and suspend the answer tap.
The real selected-field/shortcut report was not reproduced by the initial
offscreen test; the explicit focus target prevents default field traversal.
Focused tests cover native insertion/paste, neutral initial focus, shortcut
arming, duration editing, queue replacement and offscreen English card hints.
Installed physical keyboard acceptance remains pending until a new request.

## Smart Decision — 2026-10-21

The user opens Drop Smart to see and change the speech, decision and editing
models independently. Keep the chosen disclosure layout: Speech → Decision → Text,
with the current provider/model visible in each row. Decision is a separate model
type and never appears in text-generation or agent pickers. A short explanation
below the selectors describes Fast/Smart routing and uncertainty.

Reuse the searchable ModelMenu and existing popup hover, pressed, focus, disabled,
Escape and focus-return behavior. No new interactive component or animation is
introduced. Existing adaptive system colors and desktop widths remain authoritative.
Offscreen fixtures cover the expanded group at 600/900 pt content widths and both
appearances, plus the two-provider decision picker. Physical pointer/keyboard
interaction and live provider inference remain acceptance on the installed app.
The 0.05 cutoff is conservative policy; its quality on real dictation is an
unvalidated assumption, not a measured classifier accuracy guarantee.

## Calendar inside Hover — 2026-10-21

The user comes here to see today’s schedule without opening a separate app window.
The first items are the current day, events, and a persistent Connect action.
The user can inspect an event or connect another provider without losing Hover.

- One 350pt surface, 12pt insets, 8pt spacing. Agenda, event details, feed selection,
  provider choice and connection use the existing dark glass drawer. Why: the
  user explicitly asked to stay within Hover, including setup entry points.
- Calendar opens on today through the tile, search, hotkey and deep link. Day
  arrows and Today navigate in place; each reopening starts on today again.
- Event rows use a 45pt time column, a 12pt medium title (up to two lines), 10pt
  source and a disclosure chevron. Full title/notes/location are in inline
  scrollable details. Why: longer content must be readable without a window.
- Connect stays in the header. Google, Outlook, Apple and Zoom lead to the same
  CalendarConnectionFlow authorization used by Integrations. Connect immediately
  opens the provider browser or macOS permission prompt. The user clarified on
  2026-10-22 that there must be no intermediate form, account-name field or
  Advanced setup. The build supplies native client configuration.
- Provider selection shows only each calendar's name and Connect in a compact
  row. The user requested this simplification on 2026-10-22: introductory copy,
  connection-status subtitles and disclosure chevrons add noise before selection.
  The whole row retains its existing hover, pressed and keyboard-focus feedback.
- Pending Google/Zoom approval prevents authorization and appears inline after
  Connect; no additional page is opened. The active row shows progress, all
  further connections are disabled, and Cancel is available on the source list.
  Empty, loading, disconnected, stale/error and busy states retain a path back.
- All rows and header actions use a full-target rounded highlight (6% normal,
  15% hover, 23% pressed white), 1.5pt focus outline and 42% disabled opacity.
  Disabled controls suppress active hover/press. Foreground is 96% white, secondary
  text at least 76%. Reduce Motion removes the short hover color animation and
  disables panel transactions; geometry never changes during hover/press.
  On the 12% gray fixture backdrop, secondary label contrast is 8.72:1 normal,
  6.78:1 on hover and 5.33:1 pressed. Actual glass contrast remains native acceptance.
- A provider browser/macOS prompt is an explicit setup handoff; the Calendar
  panel remains open during its serialized connection. Settings connections
  do not pin Hover. Permission work lives in CalendarConnectionFlow outside the
  view, so temporary meeting/agent priority and repeat opens do not cancel it.
  Success returns to the agenda without stealing focus from a priority surface;
  errors retain a retry path and announce changes to accessibility clients.
  Connecting rows have an explicit Connecting accessibility label. Explicit
  Cancel/Back cancels it. Settings listens to its own retained window closing,
  so closing another window does not cancel authorization. Repeated accounts
  receive distinct provider-based names automatically, without another form.
  Source events and local archive data keep their current formats.

Verification: synthetic NSHostingView fixtures at 310/360/500pt cover the agenda,
long event list, details, providers, inline pending Google, direct connections,
feed selection and a busy connection. A separate fixture disables animations.
These fixtures use temporary stores, fake credentials and no network. Physical
hover/keyboard/VoiceOver, system Reduce Motion and live provider consent remain
separate native acceptance; no second app or worker package is launched.

Assumptions: daily browsing is sufficient for the compact entry; event editing
and a month grid are not added to Hover. The explicit current-day requirement
supersedes the former window presentation. See
`.project-docs/decisions/2026-10-21-calendar-hover.md`.

## Agents: native runtime and Tavily (2026-10-22)

- Keep the existing macOS Settings card/row typography and spacing. The selected
  model, workspace and connection stay together; no runtime
  installation card remains. Reason: the agent is now built in.
- Tavily belongs in API & Models → API keys, alongside every other API key.
  The user corrected its original Agents placement on October 22. Its search tile
  uses the existing provider grid and minimal secure Save/Remove form; the shared
  accepted/rejected notice is announced without adding a model route. Its saved
  Keychain account remains unchanged, and failed replacement retains that key.
  Leaving the form or closing its own Settings window clears the draft.
- Key tiles and form actions retain the shared APIModel hover/press/focus/disabled
  feedback and secure native field; saving disables competing tile/form actions.
- Open folder exposes the permanent app-data workspace; the action switch says
  Allow file edits and commands. Reason: describe current behavior while approve
  and bypass modes remain future work. Context reset after 15 minutes means no
  reuse, not timed deletion of the last local conversation file.
- Verification uses offscreen native views in light/dark at compact/roomy sizes,
  plus fixture save/error/disabled states. No animated transitions were added, so
  reduced motion follows the existing shell without extra movement. Real key
  acceptance and native Screen Recording remain installed-app checks.

## API hints: Tavily search (2026-10-22)

- Keep the existing offer cards, typography and semantic colors; add Tavily as
  web search for Agent with a neutral globe symbol. Reason: a search API should
  not appear as another LLM model.
- Lay out all offers dynamically: two columns from 560pt, with the odd final
  card spanning both; below 560pt use one column. Keep the offer grid scrollable
  and footer controls outside it. Reason: five offers must not leave an empty
  half-row or hide the last provider.
- Show verification dates on each card: existing offers retain October 19, Tavily
  uses October 22. Reason: adding one verified offer does not reverify the rest.
- Point all key setup, including Tavily, to API & Models → API keys.
  Use MacButton interaction surfaces for full link/button hover, pressed,
  focus and disabled feedback without layout shifts or added animation.
- Check light/dark native offscreen layouts, narrow/wide, embedded/standalone and
  scroll extremes. Physical pointer/keyboard/VoiceOver acceptance remains pending;
  Claude Opus 5.5 independently reviewed source and offscreen images without
  UI blockers; physical acceptance remains separate.
  Link/card contrast is 5.59:1 light and 4.92:1 dark; date/card contrast is
  6.62:1 light and 6.84:1 dark using the shared semantic tokens.


## Meeting Assistant — approved native pilot, 2026-10-23

The user approved the isolated native design and requested a live pilot inside
Whytap. Preserve its 354pt right column, slightly dimmed material and single thin
outline. The project name/arrow selector hugs its content; there is one common
close control and a plain input with a left caret. Questions appear newest first,
with older items lower/fainter; Answers is a separate bounded list. Long replies
scroll inside their body and emphasize the conclusion and important spans.

Two contextual continuations and a free clarification input continue the same
conversation. Collapse preserves the branch and exposes Return answer. Escape
in a field releases focus and preserves screenshots. Only editors acquire key
status, so reading/clicking the module keeps the meeting app's keyboard focus.

Attach screen sits beside the main input. Up to six independently removable
thumbnails sit directly below it and scroll horizontally. Images stay in memory;
success removes submitted images, failure/cancellation preserves them for retry.
A compact explicit Listen/Stop action makes capture state visible. Empty catalog,
setup errors and listening failures have visible explanations and repair access.

Creation/editing of Spaces belongs to coding agents. The module only chooses
ready Spaces. A malformed active manifest invalidates context instead of silently
reusing its former scope. The pilot uses the existing screenshot-protection
setting. Real sharing exclusion and native call interactions are installed
acceptance; offscreen renders and test checks do not establish those guarantees.


## Meeting Assistant — per-meeting hover magic, 2026-10-24

The user chose a magic icon right of the upper recording timer, replacing the
proposed separate switch row before it shipped. Reason: this is a secondary
meeting action and should sit beside recording rather than consume drawer space.
Keep the approved right-hand answer module and tool/search show-only behavior.
A configured Space and both routes expose the icon during Notes recording;
an explicitly active Assistant session also exposes it when Notes is off.
Only the controls hover shows it; agent, nudge, approval and other inline panels
preempt it. Hover reveals a control, never capture permission.

The wand is 15pt in a fixed 28pt target, within a 36pt trailing extension of the
same black island. This is a temporary secondary-action wing: the base compact
island and drawer retain matched compactWidth, while the visible upper right
edge extends by 36pt. This geometry is an implementation assumption for the
latest requested placement, not a separate user approval of a wider drawer.
The timer, Stop and drawer keep their original positions and height. Native hit routing claims exactly this visible extension while shown.
The measured first-mouse target is only the icon, with separate hover, pressed,
keyboard-focus and disabled feedback. Its overlay owns a hover signal that holds an already
open drawer without reopening it after collapse. Off is white at 52% opacity; listening
is white/ice blue with a soft blue halo. Connecting uses a static partial outline
and stays cancellable; stopping dims and disables the control. The active halo
breathes gently over 3.2s without moving or scaling the glyph/target. Reduce Motion
keeps the glow static and stops timeline frame updates. White icon on black at
52% alpha has 5.66:1 contrast; the bright active core exceeds 3:1 throughout.

One in-memory model backs icon and module Listen/Stop. Stop preserves answers;
close/sleep/restart stop listening and no later meeting auto-enables it. Startup
and hover refresh metadata without opening a panel, accessing keys or audio.
A separate metadata-only probe stops an observed recognized call after 15s of
inactivity; brief reconnects cancel the stop. Manual unrecognized calls require
explicit Stop. Long mute/seamless call switches remain heuristic limitations.

Verification uses component-composition darkAqua fixtures at 310/312/354pt:
the live recording slot, real IslandCameraSurface with its trailing extension,
four magic phases, hover/press/focus/disabled drawing surfaces and unchanged
drawer components. These are offscreen compositions, not whole-window or
physical pointer/extension-animation evidence. Reduced-motion fixture uses the live static
branch. Pure geometry and fake-provider tests cover first mouse, scoped press
cancellation, context end, preparation and repeated/cancelled starts. Physical
pointer/keyboard/VoiceOver, native glass, actual calls and screen sharing remain
installed acceptance; offscreen evidence does not establish those guarantees.


## Meeting Assistant — automatic listening, 2026-10-26

The user clarified that configuring models enables Assistant on every meeting.
This supersedes the explicit Listen/Stop and no-auto-join choices above. Both
routes and a ready Space enable a passive meeting observer. It starts system
audio on a recognized call without opening the answers window. No extra hotkey
or persistent switch is added. The existing wand overrides only the current
meeting; its off state remains reachable during a detected call without Notes.

The module keeps the approved layout, input, attachments and answer controls.
A secondary noninteractive label shows connecting, listening or stopping;
the redundant Listen/Stop button is removed. Idle text says «Можно задать вопрос».
Closing answers keeps capture active; sleep/quit and missing required routes
stop it. Errors pause automatic attempts for that meeting, with explicit retry
through the wand. Reuse existing hover/pressed/focus/disabled feedback without
adding controls or animation. Native offscreen fixtures cover ready, connecting,
listening, stopping, populated and short-screen layouts in light/dark themes.
Physical call/hover/keyboard acceptance remains in the installed app.

## Quick Translate: two text rows — 2026-10-26

The user explicitly chose the standalone Realtime Translator layout: input and
translation only. This is a quick working palette, so remove the title, mode
selector, language toolbar, field labels, cards and button footer from text
mode, including its embedded Toolbox view. A plain 22pt input and a 24pt medium
result carry the task; embedded typography is 17/18pt. The user then chose two
full-width horizontal tones: a slightly lighter input band above the darker
result. Remove outer text-mode padding and the gap between rows; keep 26pt
horizontal text insets (12pt embedded). The input has 18pt vertical padding
(12pt embedded), result content 14pt (12pt embedded). No animation is needed. The compact floating frame starts
at 560×140pt and remains resizable down to 360×120pt; its new autosave key avoids
restoring the old tall form. These dimensions are implementation choices.

Return submits; Command-Return remains supported. Each floating Text show or
return from Subtitles issues a fresh focus request after the panel becomes key.
Reset/reapply SwiftUI focus after a yield; a visibility/generation guard rejects
requests after dismissal or a mode change. Embedded panes retain their own focus.
This restores the caret even after selecting output and reopening the palette.
The user rejected the input hint and blue outline after seeing the installed
window. Keep the input empty with no visible placeholder or border; a subtle
full-width white tint (6.5%) lightens the input, rising to 10% on hover. The
result uses an 8% black tint over the same material. Their flush boundary forms
the horizontal division without an extra border or inset field container; the
native caret indicates input focus.
Use a borderless rounded text panel to remove the empty title bar and native rim.
Secondary text on the dark fixture remains 5.45:1.
Loading, empty, over-limit and failure messages replace the second row rather
than adding rows. Setup failures are actionable with full-area hover/press and
keyboard focus feedback. Long source text stays in the native horizontal field;
long translations wrap and scroll in their row. Escape uses the panel’s existing
close/cancellation path. An outside mouse click dismisses only the floating text
palette, cancels its request and still reaches its original target. Local and
global pointer observers are installed only while it is visible and removed on
close, settings repair or switching to Subtitles. Native menu tracking and modal
interaction suspend outside dismissal; subtitles retain their existing floating
behavior. Embedded Toolbox controls never install dismissal observers. No request
starts merely by opening or hovering.

Keep native selection/copy and existing target preferences. Right-click offers
secondary copy/clear/cancel/language actions; the floating palette also offers
access to active subtitles (Toolbox uses its separate tool tile);
the input’s accessibility hint describes Return and these menu options. Do not
change provider routes, read the clipboard automatically or trigger audio.
Subtitles keep their separate Speech/LLM setup and explicit Start/Stop journey.
Their two-stage pipeline is not evidence of the standalone audio model’s latency
or translation quality. Fake-provider flow checks and offscreen renders do not
prove live permissions, physical keyboard/focus or provider quality.
