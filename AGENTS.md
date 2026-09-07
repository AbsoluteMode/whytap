# whytap

Native macOS client (Swift + SwiftUI + AppKit, SwiftPM). Fully local, free,
MIT. Two hotkeys: hold Space in an editable field -> voice -> paste; Right
Command tap (text) / hold (voice) -> the user's local agent CLI (Claude Code
or Codex) -> rendered answer in the island. No account, no Whytap servers,
no telemetry. The user-facing name is Whytap; the module and most internal
identifiers are still `Sidekey`.

## Architecture

```
Voice flow (Drop / dictation):
  User -> hold Space in an editable field + speech -> CGEventTap
       (SpaceHoldMonitor: hold ~300ms -> AX check of the focused field ->
        swallow + Backspace the leaked spaces; release = graceful finish:
        post-release tail until ~140ms of silence / max 450ms
        (StreamingFinishGate in StreamingAudioEngine) -> drain -> commit;
        Escape = cancel without tail)
       -> AutoPasteEngine.rememberTargetBeforeRecording (pid + name)
       -> realtime STT via TranscriptionSessionFactory
            (level = TranscriptionIsolationLevel, Settings -> Models):
            - Local: FluidAudio Parakeet TDT v3 (Core ML), app-owned cache in
              Application Support, Apple Silicon only, offline after the
              one-time download (Streaming/Local/)
            - Your key (BYOK): direct to the provider with the user's key
              from the Keychain (Streaming/BYOK/): OpenAI Realtime or a
              self-hosted OpenAI-compatible endpoint, Deepgram, Soniox,
              ElevenLabs
       Soniox Stop: drain all captured audio -> 200ms PCM silence -> explicit
       finalize + text EOF. A final <fin> acknowledgement completes the take;
       finished=true also completes it. The 10s watchdog remains the backstop.
       -> cleanup (PostProcessor, level = LLMIsolationLevel):
            Local MLX Qwen3 / OpenRouter with the user's key / custom
            OpenAI-compatible endpoint (Ollama, LM Studio, vLLM) / none
            (raw transcript + Filler stripping). An unconfigured route
            degrades to the no-LLM output; the paste never fails on it.
       Smart uses the lowest supported OpenRouter reasoning effort (or off
       when optional), discovered from the cached model catalog, and asks
       OpenRouter to sort providers of the selected model by throughput. Meeting
       summaries and custom endpoints retain their own defaults. AX context
       has a 1.5s caller deadline. Diagnostics stay in local os_log and contain
       timings/counts/IDs only. WHY: docs/decisions/2026-09-07-smart-latency.md
       -> AutoPasteEngine.paste: pasteboard write -> Post Event preflight ->
            wait for modifiers released -> restore target focus -> settle ->
            CGEvent Cmd+V (4-event sequence)
       Resilient delivery: local audio is the truth. A degraded stream goes
            to batch recovery over the retained PCM with the local model
            (`LocalBatchTranscriber`, skipped when the Parakeet model is not
            downloaded; bounded by BatchRecoveryDeadline, 30s), then
            rung3 raw partial, then rung4 .deliveryFailed ("Couldn't
            deliver" + Retry). .deliveryFailed is escapable: a new take
            discards it. Empty batch = silence, not offline. WHY:
            docs/decisions/2026-07-26-empty-batch-is-silence-not-offline.md,
            docs/decisions/2026-06-24-deliveryfailed-escapable-and-retry-robust.md
       Transcript join (BYOKTranscriptJoin): Soniox tokens carry their own
            spaces = verbatim join; word-level providers = word-boundary join.
            WHY: docs/decisions/2026-07-22-hub-token-join-and-batch-recovery-deadline.md

Codex model controls:
  CodexModelCatalogReader -> short-lived app-server (initialize -> model/list).
  The CLI registry supplies models, reasoning levels and Fast/service tiers.
  AgentSettingsStore resolves saved/config/default model and validates controls;
  Settings and execution use the same options. No GPT-5.5 pin or model-name
  speed exception. Normal explicitly overrides Fast from the CLI config.
  Discovery refreshes at startup/Agents open/manual refresh, keeps last good
  data on failure, and never creates a thread or submits a prompt. Prefer the
  CLI in ChatGPT.app, then Codex.app and standalone locations. WHY:
  docs/decisions/2026-09-07-codex-model-registry.md

Agent flow (local CLI):
  User -> Right Command tap (text) / hold (voice) -> RightCmdGestureMonitor
       -> voice: the same STT factory as Drop
       -> the user's agent CLI (Connect Claude Code / Codex in
          Settings -> Agents or in onboarding, Skills -> Agent; runs on the
          user's machine with the user's subscription)
       -> permission-bridge prompts -> streamed render in the island
  Active agent = `agent.activeProvider` (UserDefaults), written ONLY by an
  explicit Connect confirmed by the provider's `probe()`. The chooser's
  preference (`agent.preferredProvider`) is stored separately and never read
  by dispatch. WHY: docs/decisions/2026-08-02-onboarding-connect-is-probe-backed.md

Meeting Notes:
  Always-on detector (mic activity + CoreAudio system audio + FluidAudio
  Silero VAD; fires only when a recognised meeting app writes the mic)
       -> island nudge: Take notes / Skip (20s) -> MeetingRecorder (mic +
          system audio, 16 kHz PCM16; the system-audio tap exists only while
          recording, WHY: docs/decisions/2026-06-16-system-audio-tap-on-record-only.md)
       -> processing: fully local (mic track = "Me", system track diarised by
          FluidAudio -> "Speaker N", alignment by time, MLX summary with
          map-reduce for long transcripts; the three models load SERIALLY
          with evict() between stages) or BYOK processor (provider batch STT +
          LLM with the user's keys). Neither configured = the meeting is
          marked failed with `LocalModelMessaging.meetingProcessorNotConfigured`
          and its audio stays staged; a `MeetingFinalizeManifest` re-dispatches
          it later with the language captured at Stop time.
       -> MeetingsStore (local SQLite) -> notes window (BlockNote in WKWebView)
  Manual start: Option M (configurable), the Record hover tile, or Settings ->
  Other; all converge in MeetingsCoordinator.toggleManualRecording(). With the
  Meeting Notes capability off, the manual start shows the nudge as an
  enable-prompt. Auto-end when the system mic is released for 3s (not before
  the 30s startup grace); an auto-ended recording waits 3 minutes as
  pendingReconnect and ANY detector re-fire shows "Notes | Reconnect | Skip";
  resuming is always the user's decision. WHY:
  docs/decisions/2026-07-29-reconnect-always-asks.md

Local LLM (Apple Silicon):
  MLX (`ml-explore/mlx-swift` + `-lm`), Qwen3-4B-Instruct-2507-4bit;
  diarisation FluidAudio Core ML. Gate = `LocalModelSupport.isAppleSilicon`
  (runtime sysctl `hw.optional.arm64`, not `#if arch`: the binary is
  universal). Weights download from Hugging Face into Application Support.
  Unified strings in `LocalModelMessaging` (not Apple Silicon / offline and
  not downloaded / not downloaded).
  Metallib: SwiftPM does not compile Metal shaders; `Resources/mlx.metallib`
  is built by `scripts/build-metallib.sh` and VERSION-LOCKED to the resolved
  mlx-swift revision (bump both together). It ships as a sealed resource in
  `Contents/Resources/` with a relative symlink from `Contents/MacOS/`; never
  put it directly into `Contents/MacOS/` and never sign it separately
  (breaks first-launch Gatekeeper on Sequoia). WHY:
  docs/decisions/2026-06-30-metallib-sealed-resource-sequoia-gatekeeper.md

Island display selection (multi-monitor):
  IslandScreenResolver.selectDescriptor is a pure function: user preference
  (Settings -> Other -> "Show island on") -> screen with a real notch ->
  primary display -> first. NSScreen.main is NEVER used (it is the key
  window's screen and moves with every click). All overlay panels position
  through currentDescriptor()/currentVisibleFrame() and follow
  selectionDidChangeNotification. WHY:
  docs/decisions/2026-07-07-island-display-selection-not-nsscreen-main.md

Island idle-hide:
  ~20s without activity -> the compact pill fades to the bare notch (opacity
  0 + click-through; the window never moves or resizes). IslandIdleController
  with injectable clock; blockers keep it active (meeting recording, nudge,
  agent flow, drop, update pill, music, hover, held modifiers, programmatic
  expansion, "Updated" indicator). Wake = cursor in the pill rect + 24px, any
  of our hotkeys, or a blocker rising. Toggle "Auto-hide island" in
  Settings -> Other. WHY:
  docs/decisions/2026-07-09-island-idle-hide-settings-toggle.md

Update flow (download-on-action):
  SPUUpdater (hourly, automaticallyDownloadsUpdates = FALSE) + custom
  IslandUpdateUserDriver: no Sparkle windows, everything in the island.
  Scheduled check -> "Update" pill -> hover: Download | Later -> download
  with a CALayer spinner (IslandUpdateSpinner; SwiftUI .repeatForever would
  freeze during main-thread stalls) -> auto install + relaunch -> "Updated"
  indicator for 5s on the next launch (JustUpdatedIndicator, one-shot
  marker). Feed = GitHub Releases (`BuildConfig.appcastURL`). WHY:
  docs/decisions/2026-06-17-update-download-on-action.md,
  docs/decisions/2026-07-08-update-download-spinner-and-post-relaunch-updated-indicator.md
```

First run: no sign-in. `OnboardingRouter` sends a newcomer through the tour
(permissions -> Try Drop -> Skills -> Helpers), a returning user only to the
permission-repair screen. Drop with the local level selected but no model
downloaded opens Settings -> Models (download button / key field) instead
of idling silently. Settings opens on the Models tab; "Screenshot
protection" lives in Settings -> Other (default off) and also shields the
island window.

Targets: library `Sidekey` (all app code) + thin executable `SidekeyApp`
(product `Sidekey`, `SidekeyAppMain.run()`), `OnboardingPreview` (a small
window that iterates on onboarding screens through symlinked sources) and
`SidekeyTests`. Flavors: `prod` (default) and `beta` (`-DBETA`: separate
bundle id, keychain service and feed), see `Sources/Sidekey/BuildConfig.swift`.

## Permissions

- **Accessibility** gates `NSEvent.addGlobalMonitorForEvents`
  (`RightCmdGestureMonitor`; `EscapeCloseEventMonitor` is a passive bare-Esc
  close for the visible agent answer, WHY:
  docs/decisions/2026-07-02-escape-close-passive-monitor.md), the AX check
  of the focused field (`PasteTargetValidator`) and, empirically, the active
  `CGEventTap` in `SpaceHoldMonitor`.
- **Post Event** gates `CGEvent.post` for the synthetic Cmd+V and Backspace
  (`CGPreflightPostEventAccess` / `CGRequestPostEventAccess`, a separate TCC
  bucket from Accessibility since 10.15; Tahoe shows both in one panel).
- **Input Monitoring** is only a lazy fallback: requested once if the tap
  could not be created while Accessibility is granted. Tap/toggle Drop uses
  Carbon `RegisterEventHotKey`, modifier Drop uses `ModifierOnlyHotkeyMonitor`;
  neither needs it. The tap reads all key events but handles only the trigger
  key and Escape; key contents are never logged or persisted.
- **System Audio Recording** (TCC `AudioCapture`) gates the CoreAudio process
  tap used for the other side of a meeting. Requires
  `NSAudioCaptureUsageDescription` (contract: `PackagingRebrandTests`);
  without the grant the tap silently yields zeros, so `SystemAudioVADProbe`
  rebuilds it at every recording start.
- **Microphone** for Drop, agent voice and meetings.

## Commands

```bash
# Dev: stable ad-hoc identity so TCC grants persist across rebuilds
# (`swift run` silently invalidates them, do not use it for the app).
./scripts/dev-run.sh --run

# Tests
swift test

# Onboarding screens preview
./scripts/onboarding-preview.sh

# Release: build + sign + notarize + staple + GitHub Release + signed appcast.
# Credentials come from the environment (the official builds wrap the command
# in `doppler run --project sidekey --config dev --`). Bump VERSION first.
FLAVOR=prod ./scripts/user-release.sh
FLAVOR=beta ./scripts/user-release.sh
FLAVOR=prod ./scripts/user-release.sh --dry-run
```

Details and the fork checklist: `docs/build-and-release.md`.

## Documentation

Everything lives in the repository: `CLAUDE.md` (architecture, commands,
invariants), `README.md` (user-facing), `docs/SPEC.md` (product spec),
`docs/hotkey.md`, `docs/privacy.md`, `docs/build-and-release.md`,
`docs/decisions/` (why), `docs/specs/` and `docs/plans/` (history).

After a change, update the matching place: architecture / components /
hotkey behaviour -> this file (+ `docs/hotkey.md` and a Help window row for
hotkeys); release flow -> `docs/build-and-release.md`; reasoning that is not
visible in the code -> a dated decision under `docs/decisions/` plus a
`// WHY:` anchor next to the code; product spec -> `docs/SPEC.md`. Mark the
PR with `[docs: na]` or `[docs: <path>]`.

## Hotkeys

New hotkeys follow `docs/hotkey.md`: `HotkeyHintView` is the only entry
point (`KeycapView` is internal), labels are capitalised, keycaps stand side
by side without `+`, modifiers are glyphs from `HotkeyGlyph`, and every
hotkey gets a row in the Help window (`HelpWindowController`). All hints
derive from `HotkeyConfiguration` (single source of truth for every surface).

## Invariants

1. **No Whytap-owned services.** The app never contacts a Whytap backend,
   has no account and sends no telemetry. Network traffic is limited to
   model downloads from Hugging Face, the provider the user configured with
   their own key, the local agent CLI's own traffic, `google.com` opened in
   the browser, and the Sparkle feed on GitHub Releases.
   `Tests/SidekeyTests/CloudRemovalTests.swift` fails the build on any
   Whytap hostname or removed cloud symbol under `Sources/`.
2. **Keys and content never leave through logs.** BYOK keys live only in the
   Keychain (`BuildConfig.keychainService`). `os_log` never receives
   transcripts, prompts, replies or keys (`LocalPathLoggingInvariantTests`).
   Key contents read by the hotkey tap are never logged or persisted.
3. **Local models are Apple Silicon only, gated at runtime**
   (`LocalModelSupport.isAppleSilicon`); Intel users get BYOK / custom
   endpoints. There is no paid gate anywhere.
4. **Sparkle never shows a window.** Scheduled checks only show the island
   pill; nothing downloads before the user clicks; one-button install +
   relaunch; "Later" hides the pill for the session; no background
   install-on-quit; no manual "Check for Updates" menu (there is no status
   bar item at all).
5. **Drop is remappable but hold Space by default.** Record a combo or bare
   Space in Settings -> Hotkeys (Raycast-style release-to-commit recorder).
   Space is hold-only; combos support hold or toggle; hold Drop goes through
   the generalised `SpaceHoldMonitor` (swallows the typed character, Escape
   cancels), tap/toggle Drop through Carbon, modifier Drop through
   `ModifierOnlyHotkeyMonitor`. One physical key = one action, except the
   right modifiers' tap/hold split (Right Command = agent text / voice).
   Hover buttons 1 to 5 have positional hotkeys Option 1 to Option 5 bound to
   `HoverLayoutStore.slots`.
