# Plan: NowPlaying sync (Dynamic Island music wing + always-on player strip)

## Plan status
Status: `ready-for-execution`
Reason:
- Spec approved by Andrey (this session). Source (AppleScript Music+Spotify) and waveform (animated, play-state) decisions locked.
- Every stage has a binary, stage-specific gate. No blocking open questions remain (only visual constants, resolved by defaults + a user visual gate).

## Source spec
- Spec: `docs/specs/nowplaying-sync.md` (materialized into the execution worktree on approval; full text in conversation).
- Approved by: Andrey (explicit, this session).
- Scope summary: Read the current track from Apple Music / Spotify via AppleScript and surface it in the Dynamic Island as (a) a compact right-wing slot that **replaces** the AFK passive hints (album thumbnail + linear progress + animated waveform; priority just above hints, below every other right-band slot) and (b) an **always-on player strip** rendered as a structural row directly below the compact island (album art + track title with marquee + artist + prev/playpause/next), drawn whenever a track is active including paused, independent of hover and of right-band priority. Plus a Settings "Now Playing" tab with a default-on toggle. Architecture mirrors Meeting Notes (Source → Controller → Coordinator → AppState → UI).

## Current state context
Evidence-based (recon workflow + targeted greps).

### Affected modules
- `Sources/Sidekey/AppState.swift` — central `@MainActor ObservableObject`. Meeting slice at `:52-55` (`meetingRecordingActive/Paused/Duration/Levels`), mutators `updateMeetingRecordingState` (`:148`) / `clearMeetingRecordingState` (`:162`), weak coordinator mirror at `:122`. New `nowPlaying` slice + mutators mirror this.
- `Sources/Sidekey/AppDelegate.swift` — `installMeetingsCoordinator()` (`:2843`) called from `applicationDidFinishLaunching` (`:281`; install site `:395`). New `installNowPlayingCoordinator()` added beside it + stored property + weak mirror on AppState.
- `Sources/Sidekey/DynamicIsland/IslandView.swift` — right-band priority `enum IslandRightBandPriority` (`:1014`) with `hasPriorityRightState` (`:1021`), `showsMeetingRecording` (`:1039`), `showsUpdateAvailable` (`:1051`), `showsDropModeStatus` (`:1068`), `showsHoverTriggerOrbs` (`:1093`); `IslandWrapRow` (`:1141`, props `:1148-1155`, right-band ZStack `:1235-1294`); `IslandCompactRow` (`:1301`, props `:1308-1312`); `islandStack` instantiation of `IslandCompactRow` (`:608-622`); the hover drawer block + `outerHeight` (`:343`); `IslandMeetingRecordingWaveform` (`:1545`); `IslandMeetingCountdownView` ring (`:1335`).
- `Sources/Sidekey/DynamicIsland/IslandFrameLayout.swift` — `rightSideWidth = 70` (`:42`); `hostPanelFrame` (`:406`).
- `Sources/Sidekey/DynamicIsland/IslandPanel.swift` — `setHoverBandHeight` (`:898`), `hoverBandHeightDelta` (`:910`), `expandedHitTestSize`/`expandedMouseFrame` (`:914-925`); `makeRootView` `onHoverPanelBandHeightChange` wiring (`:803`).
- `Sources/Sidekey/DynamicIsland/IslandDropModeControl.swift` — `IslandMeetingRecordingSlot` constants (`:188`: width 64 / barCount 12 / barWidth 2 / waveHeight 10) + `appendingLevel`/`displayLevels` helpers; `detachedPanelGap = 8` (`:52`); `historyHoverPanelHeight` band-growth precedent (`:58-59`).
- `Sources/Sidekey/Settings/SettingsWindowTab.swift` — tab enum (`account/models/hotkeys/permissions/notes/agentMode/notifications/toolbox`). New `.music` case (title "Now Playing", SF symbol e.g. `music.note`).
- `Sources/Sidekey/Settings/SettingsWindowView.swift` — `detailPane` switch (`:164-191`). New `.music` branch → `SettingsNowPlayingView`.
- `Resources/Info.plist.template` — `NSAppleEventsUsageDescription` already present (no plist change required for read; confirm wording covers media control).

### Reusable components
- `Sources/Sidekey/WaveformBars.swift` — `WaveformBars` (TimelineView(.animation) bar row) with `enum WaveformMode { .recording (level-driven), .processing (pure sin/cos **decorative** animation — `levels` is ignored) }`. `.processing` gives the animated bars; it has **no play-state awareness** on its own. Freeze-on-pause is achieved solely via the separate `paused: Bool` init flag (halts the TimelineView). The wing must bind `paused: !snapshot.isPlaying`.
- `IslandMeetingRecordingWaveform` (`IslandView.swift:1545`) — 12-bar Canvas; alternative/forkable if `WaveformBars` styling doesn't fit the 70pt band.
- `IslandMeetingCountdownView` ring (`IslandView.swift:1335`, `Circle().trim`) — for the **linear** progress, fork to a `Capsule` width-scale / trim (no linear progress component exists — net-new but trivial).
- `FrontmostAppDetector.runAppleScriptForURL` (`Sources/Sidekey/Meetings/FrontmostAppDetector.swift:118`) — `NSAppleScript.executeAndReturnError` pattern to copy for the source.
- `MeetingPillController` (`Sources/Sidekey/Meetings/MeetingPillController.swift:66`) — `@MainActor ObservableObject` controller template (`setState` `:273`, `pause` `:153`, `resume` `:168`, `stopRecording` `:183`).
- `MeetingsConfig` (`Sources/Sidekey/Meetings/MeetingsConfig.swift`) — feature-flag pattern; `isEnabledDefaultsKey = "com.sidekey.meetings.enabled"` (`:27`), instance-scoped `UserDefaults` for tests.
- Image chip recipe `Image(nsImage:).resizable().interpolation(.high)` (`IslandView.swift:2606`); `HistoryHoverPreview.previewImage`/`imageDisplaySize` for image sizing.
- `Tests/SidekeyTests/DynamicIsland/IslandWrapRowPriorityTests.swift` — priority truth-table tests to extend.

### Existing patterns to follow
- Controller/Coordinator/AppState/AppDelegate-install quartet (Meeting Notes).
- Right-band slots: `.transition(.opacity.combined(with:.scale(scale:0.96)))`, `.contentShape(Capsule())`, `.onTapGesture` (NOT `Button` — non-key NSPanel; precedent `IslandUpdateAvailablePill:137-142`).
- Island springs: `hoverMotion .spring(0.24, 0.82)`, `widthGrowth .spring(0.32, 0.9)` (`IslandView.swift:262`).
- Band-height plumbing: SwiftUI reports height → `onHoverPanelBandHeightChange` → `IslandPanel.setHoverBandHeight` grows hit-test/mouse band.

### Constraints
- `NSAppleScript.executeAndReturnError` is **synchronous and can block/hang**. It must run off the main thread with a timeout; publish to AppState on MainActor. The app is hang-sensitive (swiftui-expert).
- **Unit/field differences between players:** Apple Music — `duration`/`player position` in **seconds**, artwork via `data of artwork 1 of current track` (raw image data). Spotify — `duration` in **milliseconds**, `player position` in seconds, artwork via `artwork url` (https URL → async fetch). Source must normalize units and use per-app artwork loading.
- Transport: use discrete `play` / `pause` where state is known (avoid blind `playpause` toggle races); `next track` / `previous track` for skip.
- Inv #3 extension: track metadata is **never** written to prod `os_log` — DEBUG-only.
- Non-activating NSPanel: interactive controls via `.onTapGesture`; hit region must sit inside the reported band height.
- **Execution:** single git worktree, **sequential** stages, **NO commits / no push** (Andrey merges to main later).

## Spec coverage map
| Spec requirement | Stage | Validation signal |
|---|---:|---|
| AppleScript source Music+Spotify (read + transport) | 1 (read + command build) / 3 (transport execution) | unit: field parse + active-player select + transport command build; manual: DEBUG log reflects the real track (S1); strip buttons drive the real player (S3) |
| Published `nowPlaying` snapshot + feature flag + controller/coordinator | 1 | unit: controller publishes/clears via injected fake source; flag off = coordinator inert |
| Right wing replaces AFK hints; priority just above hints, below all slots | 2 | unit: extended priority truth table; manual: wing replaces hints, yields to agent/meeting/update/drop-status |
| Wing content: thumbnail + linear progress + animated waveform | 2 | unit: progress fraction math; manual: visual |
| Keep wing visible while paused | 2 | manual: pause → waveform freezes, progress holds |
| Always-on strip below island, independent of hover AND band priority | 3 | manual: strip appears on play without hover; persists while band busy (meeting/update/agent) |
| Strip content: art + marquee title + artist + transport | 3 | unit: marquee overflow predicate; manual: visual + buttons act |
| Strip buttons clickable without hover (band growth) | 3 | manual: click prev/playpause/next without hovering |
| Keep strip visible while paused | 3 | manual: pause → strip stays, Play icon shown |
| Settings toggle, new `music` tab | 4 | unit: viewmodel/flag persistence; manual: tab renders, toggle gates surfaces + stops polling |
| Automation permission UX | 1 (prompt) / 4 (status + CTA) | manual: prompt on first read; denied → CTA deep-links to Privacy > Automation |

## Cross-cutting concerns
| Concern | Plan |
|---|---|
| Auth / authorization | Not applicable (no auth surface). |
| Observability | Stage 1: DEBUG-only `os_log` of snapshot (title/app/state) behind `#if DEBUG`; never in release (inv #3 extension). No metrics needed (local-only). |
| Testing | Per stage: unit (parsing, active-player select, priority truth table, progress math, marquee overflow, settings viewmodel) + manual UI handoff (Stages 2/3/4). `swift test` is the runner. |
| Documentation | Post-merge: update `CLAUDE.md` Архитектура (new NowPlaying flow) + Notion Docs. Not a code stage; flagged in handoff. |
| Migration / backfill | Not applicable (no persisted data). |
| Backward compatibility | Additive. Priority-enum change must **extend** `IslandWrapRowPriorityTests`, not break them (Stage 2). |
| Feature flags / rollout | `NowPlayingConfig.isEnabled` (UserDefaults, default-on) — Stage 1; Settings toggle UI — Stage 4. |
| Security | Stage 1: AppleScript sources are **static literals** (no untrusted interpolation → no script injection). Automation (Apple Events) consent is the only permission. Artwork bytes → `NSImage(data:)` (no eval). |
| Privacy | Stage 1: track metadata DEBUG-only, never in prod logs. |
| Cost | Not applicable (no paid APIs). |
| Idempotency | Stage 1: discrete `play`/`pause` over blind toggle; `next`/`previous` are naturally discrete. |
| Concurrency | Stage 1: AppleScript runs on a background queue with a timeout; results hop to MainActor to publish. Single polling source; no shared-resource races. |
| Accessibility | Stage 3: transport buttons get `accessibilityLabel`; marquee respects Reduce Motion (no scroll → truncate when reduced). |
| i18n | Stage 4: minimal new UI strings ("Now Playing", toggle label, players note). Track/artist come pre-localized from the player. |
| Failure modes | Stage 1: AppleScript error/timeout / app quitting → treat as "no active player", clear after debounce; Automation denied → empty snapshot, no crash, no prompt spam. |

## Stages

### Stage 1 — NowPlaying data foundation (source + model + controller + coordinator + AppState slice + flag)
- **Behavioral delta:** While a track plays in Apple Music or Spotify and the feature flag is on, `AppState.nowPlaying` publishes a live `NowPlayingSnapshot` (app, title, artist, album, artwork, elapsed, duration, isPlaying), refreshed ~1s and cleared (debounced) when nothing is active; `NowPlayingController` exposes `previous()/playPause()/next()` that drive the active player. No island UI yet.
- **Scope:**
  - In: `NowPlayingSnapshot` model; `NowPlayingSource` protocol + `AppleScriptNowPlayingSource` (read + transport, per-app field/unit/artwork normalization, active-player selection); `NowPlayingController` (`@MainActor ObservableObject`, off-main polling with timeout, debounced clear, transport methods); `NowPlayingCoordinator` (owned by AppDelegate, weak mirror on AppState); `NowPlayingConfig` (UserDefaults flag, default-on, instance-scoped); AppState `@Published private(set) var nowPlaying: NowPlayingSnapshot?` + `updateNowPlaying(...)` / `clearNowPlaying()`; DEBUG-only snapshot log.
  - Out: any SwiftUI/island rendering; Settings UI; waveform level buffer (animated waveform is local to the wing, Stage 2).
- **Dependencies:** none (foundation).
- **Affected modules:** new `Sources/Sidekey/NowPlaying/{NowPlayingSnapshot,NowPlayingSource,AppleScriptNowPlayingSource,NowPlayingController,NowPlayingCoordinator,NowPlayingConfig}.swift`; `Sources/Sidekey/AppState.swift`; `Sources/Sidekey/AppDelegate.swift`.
- **Artifacts:** the 6 new files; AppState slice; AppDelegate install; new test file `Tests/SidekeyTests/NowPlaying/NowPlayingSourceTests.swift` + `NowPlayingControllerTests.swift`.
- **Validation gate:**
  - Automatic (`swift test`): `test_appleMusicFields_mapToSnapshot_inSeconds`; `test_spotifyFields_mapToSnapshot_msNormalizedToSeconds`; `test_activePlayer_prefersPlaying_thenMostRecent`; `test_pausedTrack_producesPausedSnapshot`; `test_controller_publishesSnapshot_fromFakeSource`; `test_controller_clearsAfterDebounce_whenSourceEmpty`; `test_flagOff_coordinatorDoesNotPoll`. Expected: all green; existing suite still green.
  - Stage-specific (manual, on-device, user): with flag on, play a track in Apple Music then Spotify → DEBUG log shows correct title/artist/elapsed (units normalized) and the per-app Automation prompt appears once. **Transport command *building* is unit-tested here; real-player transport *execution* is validated at Stage 3** (the strip buttons are its natural trigger) — Stage 1 does not require a throwaway DEBUG transport hook.
  - Regression: `swift build` + full `swift test` green; app launches.
- **Validator:** agent (unit) + user (on-device source check — needs real Music/Spotify + Automation grant).
- **Failure strategy:** `NowPlayingConfig.isEnabled = false` (or don't call `installNowPlayingCoordinator()`) → entire subsystem inert; revert the new files. No persisted state to undo.
- **Observability:** DEBUG-only `os_log` of snapshot summary; not applicable in release.

### Stage 2 — Right-wing music slot (replaces AFK hints)
- **Behavioral delta:** When `nowPlaying` is active and no higher-priority right-band slot is shown, the right band renders `IslandMusicWingView` (album thumbnail + linear progress + animated waveform), replacing the AFK passive hints. Priority: just above hints, below `agent / meetingCountdown / meetingRecording / update / dropModeStatus`.
- **Scope:**
  - In: `IslandRightBandPriority.showsMusic(musicActive:showsMeetingCountdown:showsMeetingRecording:showsUpdateAvailable:showsDropModeStatus:agentFlowActive:)` = `musicActive && !agentFlowActive && !countdown && !recording && !update && !dropModeStatus`; extend `hasPriorityRightState` with `showsMusic`; thread a `music` prop (a view snapshot derived from `AppState.nowPlaying`) through `IslandCompactRow` → `IslandWrapRow`; new `if showsMusic` branch in the right-band ZStack just above hints; `IslandMusicWingView` (thumbnail chip + `Capsule` progress + `WaveformBars(mode: .processing, paused: !isPlaying)` — `.processing` is decorative and ignores `levels`, so the **`paused` flag is the only thing that freezes the bars on pause; it MUST be bound to `!snapshot.isPlaying`**); no audio tap; extend `IslandWrapRowPriorityTests`.
  - Out: the player strip; Settings; any change to higher-priority slots' behavior.
- **Dependencies:** Stage 1 (`blocking-required`).
- **Affected modules:** `Sources/Sidekey/DynamicIsland/IslandView.swift`; new `Sources/Sidekey/DynamicIsland/IslandMusicWingView.swift`; `Tests/SidekeyTests/DynamicIsland/IslandWrapRowPriorityTests.swift`.
- **Artifacts:** new wing view; priority + wiring edits; extended priority tests.
- **Validation gate:**
  - Automatic (`swift test`): truth-table additions — `test_showsMusic_trueOnlyAboveHints_whenNoHigherSlot`; `test_showsMusic_yieldsTo_agent/meeting/update/dropStatus`; `test_dropModeStatus_doesNotYieldToMusic`; `test_hasPriorityRightState_includesMusic`; `test_wingProgressFraction(elapsed,duration)`. Expected: green; **existing priority tests unchanged & green**.
  - Stage-specific (manual UI, user): play a track → wing replaces the hint rotation, shows thumbnail + moving progress + animated bars; pause → bars freeze (verifies `paused` bound to `!isPlaying`, not just the always-running decoration), progress holds, thumbnail stays; trigger an update-pill / start a meeting recording → wing yields to that slot; stop playback → hints return. **This is also the first surface that exercises a real transport call (deferred from Stage 1): clicking is added in Stage 3, but the wing's existence confirms the published snapshot drives UI.**
  - Regression: `swift build` + `swift test` green.
- **Validator:** agent (priority/units) + **user handoff** (rendered island UI).
- **Failure strategy:** revert Stage-2 edits → island returns to prior right-band behavior (Stage 1 data layer stays inert-but-published, harmless).
- **Observability:** not applicable (pure view layer); covered by Stage 1 logging.

### Stage 3 — Always-on player strip (art + marquee title + artist + transport)
- **Behavioral delta:** While a track is active (playing or paused), `IslandMusicStripView` renders as a structural row directly below the compact island — **always**, independent of hover and of right-band priority — showing album art + track title (marquee on overflow) + artist + prev/playpause/next; the island's base height grows by `musicStripHeight` while active and the window hit-test band grows so the buttons are clickable without hovering.
- **Scope:**
  - In: `IslandMusicStripView` (art tile via `Image(nsImage:)`, `IslandMarqueeText`, artist line, three `.onTapGesture` transport buttons wired to `NowPlayingController`); net-new `IslandMarqueeText` (TimelineView(.animation) offset translate; scroll only when content width > envelope; gap+loop; respects Reduce Motion); insert the strip into the `islandStack` VStack (`IslandView.swift:606-624`) **above** the `if isHoverExpanded` drawer block (`:769`) so the hover panel still renders below it; gate the strip only on `musicActive` (NOT `isHoverExpanded`, NOT band priority); add `musicStripHeight` constant in `IslandDropModeControl`; grow the SwiftUI content height (`outerHeight`, `:343`) by `musicStripHeight` while active.
  - **Hit-testing without hover (CRITICAL — new always-on hit region, NOT `setHoverBandHeight`):** the existing hover band-height plumbing (`setHoverBandHeight` → `expandedSize`) is consulted **only while hovering** (`acceptsExpandedHitTesting` flips true on hover via `setHoverExpanded`, `IslandPanel.swift:828`), so it cannot make below-pill buttons clickable when not hovering. The meeting Stop button only works hover-free because it lives **inside** the compact pill band (covered by `compactSize`). The strip is a genuinely new below-pill clickable region. Model it on the existing always-on `agentActive` hit zone: add `musicStripActive: Bool` + `musicStripHeight` to `IslandPanel` (mirrored from `AppState.nowPlaying != nil`, same install/observe pattern as the agent/notification zones), and extend `acceptsEvent` (`:113-168`), `mouseActiveFrames` (`:229-248`), and `refreshMouseEventRouting` to **unconditionally** union a strip rect (below the compact pill, full `compactWidth`) while a track is active — independent of `acceptsExpandedHitTesting`. Verify the permanent host window frame (`agentExpandedHostFrame`, `IslandPanel.swift:716-726`) has vertical room for `compactHeight + musicStripHeight + hoverPanelHeight` (strip and hover panel can both be present); if not, grow `hostPanelFrame`.
  - Out: any edit to the hover panel's own content; scrubbing/seek; Settings.
- **Dependencies:** Stage 1 (`blocking-required`); Stage 2 (`blocking-required` for sequencing only — same file `IslandView.swift`/`islandStack`, single worktree, avoid edit conflicts).
- **Affected modules:** `Sources/Sidekey/DynamicIsland/IslandView.swift` (islandStack insert + `outerHeight`); `Sources/Sidekey/DynamicIsland/IslandPanel.swift` (**new always-on `musicStripActive` hit zone in `acceptsEvent` / `mouseActiveFrames` / `refreshMouseEventRouting`, modeled on `agentActive`; verify/grow host frame**); `Sources/Sidekey/DynamicIsland/IslandDropModeControl.swift` (`musicStripHeight` constant); new `Sources/Sidekey/DynamicIsland/IslandMusicStripView.swift` + `Sources/Sidekey/DynamicIsland/IslandMarqueeText.swift`; new `Tests/SidekeyTests/DynamicIsland/IslandMarqueeTextTests.swift`.
- **Artifacts:** strip view, marquee view, constant, height/hit-test wiring, marquee unit test.
- **Validation gate:**
  - Automatic (`swift test`): `test_marquee_scrolls_whenContentWiderThanEnvelope`; `test_marquee_static_whenFits`; `test_marquee_static_whenReduceMotion`. Expected: green; existing suite green.
  - Stage-specific (manual UI, user): play a track without hovering → strip appears below the island with art + title + artist + buttons; long title scrolls, short title is static; click prev/playpause/next **without hovering** → player responds (this is the canonical real-transport-execution check, deferred from Stage 1); while a meeting recording / update pill occupies the right band → the strip is **still drawn**; pause → strip stays with Play icon; hover the island → existing hover panel appears **below** the strip, unchanged (no clipping — strip + panel both fit the window frame); stop → strip disappears, island returns to compact.
  - Regression: `swift build` + `swift test` green; hover panel + agent wing behavior unchanged when no music.
- **Validator:** agent (marquee unit) + **user handoff** (rendered island UI + click-without-hover hit-testing).
- **Failure strategy:** revert Stage-3 edits → island loses the strip only; Stages 1–2 intact. Note: showing the strip inside the hover-expanded band is **NOT** an acceptable fallback — it makes the strip hover-only, violating the spec's "independent of hover" requirement; it may be used only as a throwaway debugging crutch, never as the shipped behavior. The real roll-forward is fixing the always-on hit zone in `IslandPanel`.
- **Observability:** not applicable (view layer).

### Stage 4 — Settings "Now Playing" tab + toggle
- **Behavioral delta:** A new Settings tab "Now Playing" with a default-on toggle bound to `NowPlayingConfig.isEnabled`; toggling off makes all music surfaces disappear and stops polling; toggling on restores them. The tab also shows the supported-players note and the Automation permission status with a CTA that deep-links to Privacy > Automation when denied.
- **Scope:**
  - In: new `.music` case in `SettingsWindowTab` (title "Now Playing", system image `music.note`); `.music` branch in `SettingsWindowView.detailPane`; `SettingsNowPlayingView` (toggle + players note + Automation status/CTA); wiring the toggle to `NowPlayingConfig` + making `NowPlayingController`/coordinator observe the flag (start/stop polling, clear snapshot on disable).
  - Out: per-player enable toggles; advanced options.
- **Dependencies:** Stage 1 (`blocking-required` — flag + controller); best validated after Stages 2–3 (`blocking-soft`) so the toggle visibly affects surfaces.
- **Affected modules:** `Sources/Sidekey/Settings/SettingsWindowTab.swift`; `Sources/Sidekey/Settings/SettingsWindowView.swift`; new `Sources/Sidekey/Settings/SettingsNowPlayingView.swift`; `Sources/Sidekey/NowPlaying/NowPlayingConfig.swift` + `NowPlayingController.swift` (observe flag); new `Tests/SidekeyTests/Settings/SettingsNowPlayingTests.swift`.
- **Artifacts:** tab case, settings view, flag-observe wiring, settings test.
- **Validation gate:**
  - Automatic (`swift test`): `test_toggle_persistsToUserDefaults`; `test_disable_clearsSnapshotAndStopsPolling` (injected fake source/clock); `test_tab_titleAndIcon`. Expected: green; existing suite green.
  - Stage-specific (manual UI, user): open Settings → "Now Playing" tab renders with toggle on; turn off → wing + strip vanish and polling stops; turn on → surfaces return on next poll; with Automation denied, the CTA opens Privacy > Automation.
  - Regression: `swift build` + `swift test` green; other Settings tabs unaffected.
- **Validator:** agent (flag/persistence) + **user handoff** (rendered settings page).
- **Failure strategy:** revert Stage-4 edits → feature stays on via default flag (still controllable through `defaults write`); no data loss.
- **Observability:** not applicable.

## Execution sequencing
| Stage | Dependency type | Parallel with | Notes |
|---:|---|---|---|
| 1 | foundation / none | none | Data pipeline; unit-testable + on-device source check. |
| 2 | blocking-required: Stage 1 | none | Edits `IslandView.swift` priority/wrap-row. |
| 3 | blocking-required: Stage 1; blocking-required: Stage 2 (file-conflict avoidance) | none | Edits `IslandView.swift` islandStack/height. |
| 4 | blocking-required: Stage 1; blocking-soft: Stages 2–3 | none | Settings; validated last so toggle visibly gates surfaces. |

All stages **sequential in a single git worktree** (no commits/push per Andrey). Per-stage dev-agent pairing:
- **Stage 1** (non-UI: AppleScript source, controller, coordinator, AppState slice) → `backend-dev` + `dev-foundation` (+ `swiftui-expert` consulted only for the off-main/hang concern).
- **Stages 2–4** (SwiftUI/island/settings views) → `frontend-dev` + `dev-foundation` + `swiftui-expert`.

Each stage is followed by a `pr-review` reviewer-agent on the gate (Stage 1 review must explicitly check no AppleScript runs on the main thread).

## User handoffs
| Stage | What user validates | Checklist |
|---:|---|---|
| 1 | On-device source | Play in Music & Spotify → DEBUG log correct; Automation prompt appears once per app; transport drives player. |
| 2 | Rendered wing | Wing replaces hints; progress moves; bars animate; pause freezes; yields to higher slots; stop → hints return. |
| 3 | Rendered strip + hit-testing | Strip shows without hover; long title scrolls; buttons click without hover; strip persists when band busy; pause keeps strip; hover panel still below; stop hides strip. |
| 4 | Rendered settings page | Tab renders; toggle off hides surfaces + stops polling; on restores; denied-Automation CTA deep-links. |

## Specialist review requirements
| Area | Stage | Review skill |
|---|---:|---|
| PR correctness/conventions | each | pr-review (reviewer-agent on each gate) |
| Hang/perf (sync AppleScript off-main) | 1 | performance-review lens within pr-review (verify no main-thread AppleScript) |

## Open questions / blockers
None blocking. Visual constants (thumbnail size, strip height, marquee speed ~30pt/s / end-pause 2s / gap 32pt) default-and-confirm at the user visual gates (Stages 2–3).

## Out of scope
- MediaRemote / arbitrary players (browser/web audio): gated on macOS 15.4+, non-viable; only Music+Spotify.
- Real audio-reactive waveform (system-audio tap): animated only.
- Scrub/seek, volume, like, shuffle/repeat, queue: not v1.
- Hover-panel edits: untouched.

## Risks
| Risk | Impact | Mitigation | Stage |
|---|---|---|---|
| Sync AppleScript blocks main thread → app hang | High | Run source off-main with timeout; publish on MainActor; pr-review checks for main-thread calls | 1 |
| Spotify vs Music field/unit/artwork differences | Medium | Per-app normalization (ms→s, artwork url vs data); explicit unit tests | 1 |
| Always-on strip buttons not hit-testable without hover (dead zone) | High | New unconditional `musicStripActive` hit region in `IslandPanel.acceptsEvent`/`mouseActiveFrames` (modeled on `agentActive`), NOT `setHoverBandHeight` (hover-only); user clicks-without-hover gate. In-band/hover fallback is forbidden as shipped behavior (violates "independent of hover") | 3 |
| Automation prompt fatigue / denied state | Medium | Lazy first-use prompt; graceful empty; Settings status + CTA | 1, 4 |
| Priority-enum change breaks existing island behavior | Medium | Extend (not rewrite) truth-table tests; keep `dropModeStatus` above music | 2 |

## Handoff for execution
- Status: `ready-for-execution`
- Recommended boundaries: one logical change-set per stage (no PR yet — single worktree, no commits per Andrey).
- Execution: sequential (1 → 2 → 3 → 4), single worktree.
- Parallelizable stages: none (shared `IslandView.swift` + single uncommitted worktree).
- User validation required: Stages 1, 2, 3, 4 (on-device).
- Specialist review: pr-review reviewer-agent per stage; hang/main-thread check at Stage 1.
- All hard gates passed: yes.
- Post-merge docs: `CLAUDE.md` Архитектура + Notion (flagged, not a code stage).
