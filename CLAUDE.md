# Whytap

Native macOS client (Swift + SwiftUI + AppKit, SwiftPM). BYOK only: the
user's provider keys or their own OpenAI-compatible endpoints, no on-device
models; free, MIT. Two hotkeys: hold Space in an editable
field -> voice -> paste; Right Command tap (text) / hold (voice) -> local
native Whytap Agent -> the user's selected model/provider -> answer in the island. No account, no Whytap servers,
no telemetry. The project and product name is **Whytap**, reaffirmed by the user
on 2026-10-21; use it in replies, current documentation and new features.
The module and most internal
identifiers are still `Sidekey`. The public source repository is
`https://github.com/AbsoluteMode/whytap`. Preserve legacy bundle IDs, Keychain
services and Application Support paths so existing settings and permissions
survive the rename. Keep the existing community certificate, EXODIA_* release
variables, build metadata keys and backup formats/destinations as compatibility
contracts. WHY: .project-docs/decisions/2026-10-19-whytap-name.md

The canonical primary checkout folder is named `whytap`; an older `exodia`
path can remain a compatibility symlink for existing chats and worktrees.
It is not the project name. Older checkouts can contain unmerged source and WIP.
Consult current `origin/main` guidance and the primary build receipt before
treating an older checkout's naming or feature descriptions as the current app.

## Parallel development and the shared application

Read `.project-docs/processes/shared-app-development.md` for every feature task
and before integrating or updating the user's app. The user approved parallel
feature sessions with regular checked integration and one working application.

- Each feature uses its own branch/worktree. Workers build/test without
  launching, registering or installing their bundles. Do not run `dev-run.sh`
  or `customize.py build/run` from feature sessions; even build-only dev
  packaging on some branches stops other dev processes.
- Keep `/Applications/Whytap.app` (`com.rootwise.sidekey`) as the user's one
  working app, preserving signing identity, permissions and data. Source for
  shared updates is checked `origin/main`; first reconcile any fixes already
  installed from a feature branch. Do not replace them with older main code.
- Run exactly one Whytap instance across all channels: beta shares meetings,
  staging and clipboard history with production and competes for hotkeys.
  Production app/DMG packaging is reserved for the integrator under the lock.
- Finished feature agents automatically submit their reviewed PR/exact head,
  checks, dependencies and acceptance steps to the persistent build queue
  (`scripts/build-queue.py`; installed helper in the Git common directory).
  The configured builder chat processes FIFO, sends queue/start/result messages
  to the originating sessions and alone integrates/packages/promotes. These
  queue messages are user-authorized. Workers follow the result and report
  issues without starting competing builds. Follow the runbook for CLI inboxes,
  pending installs, recovery and the five-minute builder automation.
- The builder holds the shared `exodia-integration.lock` in
  `git rev-parse --git-common-dir` for protected operations. Queue claims never
  replace that lock or any validation gate. Preserve all other sessions' WIP;
  use a clean integration worktree when the primary checkout is occupied.
- Review overlaps, validate the final combined candidate and merge through a
  PR with exact head/base checks. Routine checked integration/local refresh
  needs no repeated approval. Public publishing remains a separate action.
- Build a production candidate without interrupting the installed app. Verify
  its signature/identity against the installed app and require a newer build
  number without downgrading the display version. Keep the last working
  bundle. The user authorized automatic normal restarts outside meetings on
  2026-10-20, accepting interruption of other work. Check the current meeting
  gate from the shared procedure; active/suspected meetings or an unknown
  result defer silently without repeated saved/idle questions. Never force-quit.
- Maintain build/CURRENT_BUILD.md in the primary checkout with separate
  ready, merged, pending and verified-running states, source SHA, included
  features and 1–3 acceptance steps. Report what actually runs and what to
  check after promotion. A merge alone does not update the running app.
- Bound developer backups: after a successful promotion retain one previous
  signed working app, remove obsolete app copies under the builder lock, and
  create full data snapshots only for actual migrations. Remove obsolete data
  reserves after migration preservation/recovery checks pass. Preserve every
  coding session, its work and unfinished rollback; follow the shared process's
  retention section. User-controlled Automatic backup is a separate setting.
- Before integration/app actions, fetch and reread current `origin/main`'s
  guidance even in older worktrees. Resolve technical overlaps from accepted
  requirements; report incompatible product choices or unresolved risks.

WHY: .project-docs/decisions/2026-10-19-shared-working-app.md

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
       -> DropTake.begin latches the mode and the feature route (dropFast or
            dropSmart) when the take starts; Retry and recovery read the
            latch, never the current preference
       -> realtime STT via TranscriptionSessionFactory
            (route of the take's feature, Settings -> API & Models):
            FeatureRouteResolver turns the feature's route (provider account +
            model, AIRoutingStore) into a ResolvedRoute with the account's
            Keychain key; RealtimeAdapterFactory builds the adapter. Your key
            (BYOK) only: direct to the provider (Streaming/BYOK/): Soniox
            (default), Deepgram, ElevenLabs or a self-hosted endpoint speaking
            the OpenAI Realtime protocol. OpenAI itself is not offered; a
            legacy OpenAI choice resolves to Soniox. A server route has no
            default host: a missing or unparseable base URL fails
            (.invalidBaseURL / .missingBaseURL) before any socket opens, never
            reaching api.openai.com. WHY:
            .project-docs/decisions/2026-10-18-no-default-realtime-host.md
            A feature without a route (Not set: never chosen on Apple Silicon,
            the retired Local route, or its key removed), or whose key is
            missing or unreadable, throws .notConfigured / .missingKey and
            opens Settings -> API & Models on that feature's row; nothing
            moves to another provider on its own. Deepgram's language policy
            is checked before the key (invalidLanguageConfiguration). WHY:
            .project-docs/decisions/2026-10-18-remove-local-models.md,
            .project-docs/decisions/2026-10-19-api-and-models.md
       Soniox Stop: drain all captured audio -> 200ms PCM silence -> explicit
       finalize + text EOF. A final <fin> acknowledgement completes the take;
       finished=true also completes it. The 10s watchdog remains the backstop.
       -> cleanup (PostProcessor, route of dropSmartCleanup):
            OpenRouter, OpenAI or Anthropic with the user's key / a custom OpenAI-compatible
            server (Ollama, LM Studio, vLLM) through DirectLLMRouteResolver.
            The mode is captured at take start:
            Fast bypasses AI text processing. Smart makes one request to the
            selected cleanup model: a reserved whole-response pass marker keeps
            the transcript verbatim with plain delivery; otherwise use the edited
            message. Synonyms, word order and minor polish alone should pass;
            concrete errors and useful long-message structure still edit.
            Translation cannot pass. Failed, empty, malformed or cancelled
            responses retain strict Retry behavior. The separate Jev/OpenAI
            Decision stage and settings row are removed; migration4 retires only
            that route, preserving all other model/provider choices and keys.
            The old feature ID remains for historical usage decoding only;
            Decision-only catalog entries stay excluded from text/agent pickers.
            WHY: .project-docs/decisions/2026-10-22-smart-editor-pass.md
            Smart failures retain the transcript in memory and show Retry with
            the original mode and target; configuration errors open API & Models on
            the Drop Smart cleanup row.
            Full, batch-recovered and partial transcripts use the same rule.
            A new take discards the old retry. The island observes persisted
            mode changes from every control. The cleanup provider mark appears
            only while processing; paste shows “pasting…” without a provider. WHY:
            .project-docs/decisions/2026-10-19-strict-drop-modes.md
       Smart's editor uses minimal repairs,
       retaining the author's wording, thought order, facts and uncertainty;
       it does not summarize or deeply rewrite. Self-corrections replace only
       their fragment; nested requests stay requests. Evaluated on GPT-6 Sol,
       the prompt does not change selected routes. WHY:
       .project-docs/decisions/2026-10-21-smart-editor-prompt.md
       SmartFormattingProfile selects destination syntax from app identity and
       focused AX role/document metadata (within the same 1.5s context deadline).
       Markdown editors/recognized web composers use a fixed syntax subset;
       IDEs require a real Markdown file, and single-line/unknown fields stay plain.
       Slack/Telegram use local RTF + semantic HTML + plain clipboard fallback;
       code/URLs survive filler stripping and every flavor is restored after
       paste. Fast and clean-Decision editor bypass stay unchanged. WHY:
       .project-docs/decisions/2026-10-21-smart-destination-formatting.md
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
            to batch recovery over the retained PCM through the
            `BatchTranscribing` seam (bounded by BatchRecoveryDeadline, 30s),
            then rung3 raw partial, then rung4 .deliveryFailed ("Couldn't
            deliver" + Retry). .deliveryFailed is escapable: a new take
            discards it. Empty batch = silence, not offline. Production binds
            `ProviderBatchTranscriber` (Streaming/BYOK/) for the batch rung,
            Retry, the recorder fallback and agent batch voice: the whole
            take goes to the provider of the feature that led it (Drop Fast
            or Drop Smart; agent batch voice: Agent voice) in Settings ->
            API & Models, with that provider's own Keychain key and its
            recorded model from the built-in registry (Soniox file API, Deepgram
            pre-recorded, ElevenLabs speech-to-text, self-hosted
            /v1/audio/transcriptions over https), with the realtime
            request's language choices. No route for the feature, no key for its
            provider, no recorded model for it, or a server URL without a
            host = unavailable, never another provider. Soniox polling stops after
            30s; its file, then its job, are deleted after every outcome.
            WHY:
            docs/decisions/2026-07-26-empty-batch-is-silence-not-offline.md,
            docs/decisions/2026-06-24-deliveryfailed-escapable-and-retry-robust.md,
            .project-docs/decisions/2026-10-18-provider-batch-transcription.md
       Transcript join (BYOKTranscriptJoin): Soniox tokens carry their own
            spaces = verbatim join; word-level providers = word-boundary join.
            WHY: docs/decisions/2026-07-22-hub-token-join-and-batch-recovery-deadline.md

Agent flow (native Whytap runtime; OpenRouter, OpenAI or Anthropic):
  The Agent voice ticker shows the selected model author's bundled mark instead
  of the generic star; OpenRouter's hosting-provider pin does not change authorship.
  OpenAI, Anthropic, Gemini, DeepSeek, Qwen, Mistral, Cohere and Perplexity have
  prewarmed fallbacks. Unknown/Auto OpenRouter authors use the OpenRouter mark.
  A separate bounded task refreshes public OpenRouter artwork weekly with ETag,
  without keys/content/model requests; recording never waits for it. Cache I/O
  is off the main actor, failed refreshes retain usable artwork, and stale view
  loads cannot overwrite a new model. Existing geometry, breathing and reduced
  motion remain. WHY: .project-docs/decisions/2026-10-22-native-agent.md
  User -> Right Command tap (text) / hold (voice) -> RightCmdGestureMonitor
       -> voice: the same STT factory as Drop, route of agentVoice
       -> NativeAgentProvider -> direct model HTTP -> local tool -> model loop
       -> final text and typed actions rendered in the island
  Optional selection fallback sends Cmd+C only when the target app exposes an
  enabled bare Command-C menu item. Unknown/disabled Copy, focus drift or a
  Whytap key window skips it; text/voice submission continues without selection.
  No CLI installation, binary/version probe, MCP bootstrap, provider discovery,
  model catalog fetch or paid connection probe is needed to start a request.
  Settings -> API & Models chooses the exact Agent route/key. OpenRouter uses
  Chat Completions (including an explicit endpoint pin without fallback),
  OpenAI uses Responses with store:false and encrypted reasoning replay, and
  Anthropic uses Messages. Provider-native reasoning/tool items survive within
  the turn. OpenRouter continuations normalize tool arguments to JSON strings,
  preserve tool IDs and ordered reasoning_details, and omit duplicate plaintext
  reasoning. Only allowlisted provider error categories become static messages;
  raw errors stay out of output/logs. HTTP-200 error envelopes fail after any
  reported usage is recorded. The shared model loop applies the same handling
  to Meeting Assistant's OpenRouter route. No provider fallback or model substitution. Connect checks only
  local key availability, model selection and writable workspace; it does not
  prove the provider accepts the key. Existing connected OpenCode users migrate
  to native without changing the route/key; disconnected users stay disconnected.
  Persist the legacy opencode connection identifier so the retained rollback app
  can still read the connected state; dispatch resolves it to native in memory.
  Keys stay in Keychain, only in requests to their own service. No model key is
  put in child environments, argv, files or logs. The old OpenCode implementation
  and its local files remain unused for compatibility; do not delete user data.
  AgentDaemonWorkingDirectory keeps the dedicated workspace at
  Application Support/whytap/agent, with AGENTS.md memory, sessions.json and
  native-conversation.json. Read bounded memory before the first model request;
  no bootstrap scan of the home directory or source checkout. Recent context is
  at most six completed user/assistant pairs (answer text and returned card
  descriptions/destinations) and 12,000 characters, scoped
  to provider/model/endpoint and resumed within 15 minutes. Expiry stops reuse;
  the last file remains locally until replaced. An oversized latest exchange is
  shortened while retaining both ends and room for later turns. Copy-card
  payloads are excluded from supplementary memory; only their labels remain.
  Tool output, reasoning and
  screenshots are not written into this new history. The system prompt is one
  app-owned source, supplied once per request; this is not an empty context on
  every question. Old project catalogs/indexes/workspaces remain unused on disk.
  Settings -> API & Models -> API keys saves a separate Tavily key in Keychain
  (byok.tavily.search_api_key), after a GET /usage check without a search. The
  web_search tool sends only its bounded query to POST /search (basic, five
  results, at most two searches per turn); excerpts/URLs go to the chosen model.
  No key means an actionable tool error, never an alternative search provider.
  Tools cover bounded file reads/list/search, HTTPS fetch, requested screenshot,
  typed answer actions and Case key names. The existing action preference
  agent.opencode.allowActions is preserved: Allow file edits and commands is
  on by default; off removes and rejects write_file/run_command. Case keeps its
  own approvals through the signed helper and scoped child PID registrations.
  Commands use a dedicated process group, 30-second deadline and bounded output;
  cancellation signals that group. Stop waiting within a bounded drain if a
  detached child holds output open, and report that it may still be running.
  Child environments exclude model keys and unrelated app descriptors. This is
  an action policy, not a filesystem
  sandbox. Approve and bypass modes are a later phase, not implemented here.
  The loop has bounded steps/tool calls/context, explicit failures and no automatic
  retries that could repeat side effects. Files, selections, web/tool output and
  screenshots are untrusted evidence. Never treat them as user authorization.
  WhytapCustomizationContext.promptInstructions retains Monitor/source-kit contracts.
  WHY: .project-docs/decisions/2026-10-22-native-agent.md

Meeting Assistant Beta:
  A passive right-hand module uses the approved native design: ready Space picker,
  plain input, bounded questions/answers, structured replies, two continuations
  and up to six explicit screenshot attachments. A Toolbox/search tool and
  whytap://tool/meetingAssistant only show it. With both model routes and a ready
  Space configured, a metadata-only observer exposes the wand during recognized
  meetings. Listening starts off on every meeting and requires an explicit wand
  click; configuration, opening the module and hover never enable it.
  Meeting Assistant and Meeting Assistant audio have independent initially unset
  routes. A native provider loop uses only scoped read/list/search tools, without
  the ordinary Agent's workspace/history, shell, writes, network or Case tools.
  Coding agents create/edit local manifests with scripts/meeting-space.py; users
  select ready Spaces. Each file is validated independently; descriptor-relative
  reads reject traversal, symlinks, hidden/credential paths and out-of-scope access.
  Database declarations remain unavailable metadata in this Beta. Explicitly
  enabled listening sends system audio (not microphone) to the selected realtime route,
  retains only bounded in-memory finals and extracts questions through the chosen
  answer model. No audio, transcript, images or conversations are written by this
  feature. Space changes/edits cancel work and revalidate context; closing answers
  keeps listening. Sleep/quit stop audio and monitoring; wake rechecks the current
  meeting without resuming capture. Removing a required model stops capture. Protection recreates
  the panel using the existing Other setting. Guide: docs/meeting-assistant.md.
  Once both routes and a Space are configured, hover reveals a magic icon right
  of the recording timer during recognized meetings/Notes (also during a manually
  active Assistant session). It is translucent off and softly glowing while listening.
  This secondary action uses a temporary 36pt right wing; base compactWidth and
  drawer stay matched, so their right edges temporarily differ while it is shown.
  The wand enables/disables only the current meeting; each later meeting starts
  off. Errors stop listening until another explicit enable. The module and its
  API & Models group visibly mark the feature Beta.
  An observed context ending for 15s stops capture; initial/unrecognized manual
  sessions need the wand to stop. This mic-activity heuristic cannot identify every call.
  WHY: docs/decisions/2026-10-26-meeting-assistant-beta-opt-in.md
  WHY: docs/decisions/2026-10-24-meeting-assistant-session-switch.md
  WHY: docs/decisions/2026-10-23-meeting-assistant-pilot.md

Translation tools:
  Translate and Subtitles are optional catalog action tools opening one native
  floating window (TranslationWindowController). Text mode is a compact two-row
  palette: plain input submits on Return/Command-Return; output includes loading
  and errors. A full-width lighter input band meets the darker result with no
  gap or inset field container. Each floating Text show requests input focus,
  guarded against late focus after dismissal/mode changes. The input has no
  hint/border and text mode has no window title bar.
  Escape or a click outside the floating text palette closes/cancels it; pointer
  observers are scoped to visible text mode, pass the click through and suspend
  during native menu/modal interaction. Subtitles retain floating persistence.
  Saved targets and secondary actions stay in the
  context menu; long output scrolls. TextTranslationModel cancels
  edited/replaced requests and rejects late results; automatic text direction
  is RU to EN for Cyrillic input and EN to RU otherwise. Explicit targets use
  AppLanguage. LiveSubtitleModel captures only CoreAudio system audio, never
  the microphone, on the subtitlesAudio real-time route; final-only phrases
  go to its independent subtitlesTranslation LLM route. API & Models groups
  Subtitles Speech/LLM selectors; typed text uses only translation. New routes
  start unset. Migration v2 copies the previous shared text route once only
  for configured subtitles; later edits, clears and launches stay independent.
  Partial v1 documents expose this split in memory without rewriting raw bytes;
  their first real edit retains a backup and persists the split before the edit.
  Never borrow other routes at runtime or migrate standalone credentials.
  Eight queued phrases, forty retained lines and a bounded audio relay stop
  visibly on backlog. Stop uses opt-in CoreAudio terminal EOF after capture
  quiescence and an IO queue barrier, then naturally drains the relay before
  provider endInput. Ordinary meeting/VAD stop keeps streams reusable; hardware
  start/stop/route restart are serialized. Cancel, window close and sleep
  tear down capture and requests. No audio/history is saved. Visible translation work
  (including unsent input) or an active session blocks app-initiated update restart. Guide: docs/translation.md. WHY:
  .project-docs/decisions/2026-10-20-translation-tools.md

Meeting Notes:
  Meetings opens an overview of the five newest notes with a History button.
  History keeps the full date-grouped list. Back from a note preserves its list
  origin; the Settings Meetings entry and direct note links return to overview.
  Both use MeetingListModel and retain refresh, status and confirmed deletion.
  Load failures preserve existing rows and offer Retry. The vertical overview
  layout leaves room for future Meeting Assistant presets without showing
  unfinished controls. UI rationale and behavior: docs/DESIGN.md.
  Always-on detector (mic activity + CoreAudio system audio + FluidAudio
  Silero VAD, the only remaining Core ML model, downloaded from Hugging Face
  on the first speech check; fires only when a recognised meeting app writes
  the mic)
       -> island nudge: Take notes / Skip (20s) -> MeetingRecorder (mic +
          system audio, 16 kHz PCM16; the system-audio tap exists only while
          recording, WHY: docs/decisions/2026-06-16-system-audio-tap-on-record-only.md)
       -> processing: BYOK processor only (routes of the meetings and
          meetingNotes features: Soniox file API with speaker-attributed
          turns and durable job/transcript checkpoint; other providers use
          their adapters, then the LLM route the user chose for notes).
          Speaker labels come from the provider; there is no on-device
          diarizer. Without a route for Meetings and Meeting notes
          (including the retired Local route) the meeting is marked failed
          with `MeetingsCoordinator.processorNotConfiguredMessage` and its
          audio stays staged; a `MeetingFinalizeManifest` re-dispatches it
          later with the language captured at Stop time, for at most 24 hours
          after the last chunk. A recording without
          speech is not a failure: a completed Soniox job without segments
          stores a "No speech detected" note without the LLM and releases the
          staged audio, so it is never retried. Model failures remain errors.
          WHY: .project-docs/decisions/2026-10-18-silent-meetings.md,
          .project-docs/decisions/2026-10-18-remove-local-models.md
       -> MeetingsStore (local SQLite) -> notes window (BlockNote in WKWebView)
  Delete: a finished meeting (ready or failed) has "Delete…" in its row
  context menu behind a confirmation whose default button is Cancel.
  MeetingsCoordinator.deleteMeeting removes the staged recording first (while
  its manifest exists, launch recovery would bring the meeting back), then the
  row and its note and transcript files; a meeting still processing is
  refused. The row's delete commits only after the transcript and then the
  note are gone, so a failed Delete leaves the meeting listed with its note.
  A note save that lands after Delete writes nothing (MeetingsStore.update
  checks the row first). Launch recovery frees the whole staged directory of
  a stored meeting, including a ready row whose note is missing. Remote Soniox
  resources are not cleaned by Delete. WHY:
  .project-docs/decisions/2026-10-18-delete-meeting-and-staged-audio.md
  Audio is kept only while it can still become a note. Launch and full wake
  (also with Meeting Notes off) first run releaseUnneededStagedRecordings: a
  failed recording goes 24 h after its last chunk (failedRecordingRetention;
  the meeting stays failed with recordingExpiredMessage and is never
  retried), a UUID-named directory without manifest.json 1 h after its last
  write (24 h with an undecodable manifest). An expired Reconnect part sets
  its meeting ready again when the note exists and no other part is pending.
  The active or still-starting recording, a live Reconnect part and
  recordings being processed are skipped; file work runs off the main thread.
  Restored older archives' parked recordings count as manifest-less. WHY:
  .project-docs/decisions/2026-10-22-no-retained-meeting-audio.md
  Manual start: Option M (configurable) or the Record hover tile; both
  converge in MeetingsCoordinator.toggleManualRecording(). With the
  Meeting Notes capability off, the manual start shows the nudge as an
  enable-prompt. Auto-end when the system mic is released for 3s (not before
  the 30s startup grace). Every completed call starts processing immediately;
  an auto-ended part remains a Reconnect candidate for three minutes and any
  detector re-fire inside that window asks "Notes | Reconnect | Skip".
  Reconnect captures a fresh part in a separate staging directory. When it ends,
  the same meeting shows Updating… while the earlier note stays readable; only
  fresh audio is transcribed, and its findings/transcript supplement the note.
  Per-meeting processing order, durable recording receipts/content snapshots and
  versioned additions protect recovery and edits. Both Notes hosts refresh the
  selected note/transcript after the list fetch and preserve its current tab.
  Active drafts defer refresh; Done waits for the latest store-save acknowledgment,
  while Cancel applies the deferred refresh. Speaker labels stay scoped to each
  part. Manual Stop is final; timeout/Skip never resume recording. WHY:
  .project-docs/decisions/2026-10-20-meeting-continuations.md
  A BYOK key read that fails with errSecInDarkWake (no Keychain prompt
  possible: dark wake or the lid closing) defers the meeting instead of
  failing it: no failure event, the earlier failure reason is restored and
  the manifest stays for the next pass (startReady() after a full wake, or
  the next launch). WHY:
  .project-docs/decisions/2026-10-18-meeting-recovery-dark-wake.md

  Internal opt-in research (no Settings controls): the local
  sidekey.meetings.liveTestCapture flag adds a separate Soniox stt-rt-v5 stream
  only when Meetings uses Soniox, and only in source dev builds (9999 / -dev);
  packaged builds ignore it and remove Sidekey/meeting-assistant-tests at
  launch. Preserve its explicitly chosen value. It saves
  private aligned source PCM, signal activity, final diarized tokens and receipt
  times under Sidekey/meeting-assistant-tests. Normal notes remain unchanged;
  no automatic suggestions are enabled. The independent 100ms test mixer uses
  a 150ms jitter allowance and approximate callback timing; source-role labels
  are experimental. Per-source background calibration warms up for two seconds;
  unique-time speaker anchors check surrounding audio and never override current
  overlap or an opposing source. Meeting mic capture keeps its quiet-input boost
  with a peak limiter and gradual gain release. Guide: docs/meeting-assistant-testing.md. WHY:
  .project-docs/decisions/2026-10-20-meeting-source-noise-floor.md,
  .project-docs/decisions/2026-10-19-live-meeting-test-capture.md,
  .project-docs/decisions/2026-10-22-no-retained-meeting-audio.md

Case secrets manager:
  The Case drawer has a 320 pt content viewport (the outer hit band includes
  its gap/music strip) and retains the notch-derived width. Connected clients
  appear as app icons; clicking one opens that client's policy. An always-visible
  Connect button offers Whytap Agent plus installed Claude Code and Cursor with
  bundled logos, then grouped project scope and Accept/Bypass before registration.
  Codex is not offered. There is no arbitrary program picker; existing legacy
  registrations stay editable. WHY:
  .project-docs/decisions/2026-10-21-case-connect-claude-code.md. Mode
  and project headings have thin horizontal dividers above their controls.
  Selected projects has a metadata search that preserves the full draft selection;
  All projects includes future projects, with its explanation in native help.
  Mode explanations live inside their choices, and Touch ID help belongs to Save. Codex highlights blue, Claude orange and Cursor white
  on hover/keyboard focus. Search matches project and key names/descriptions,
  including empty projects and General. A matching project shows all its keys;
  key-only matches show only those keys. Results put the project with the best
  match first (equal ones keep project order); a query word starting a word of a
  project name lets the rest match that project's keys (`whytap github`); later
  words of 3+ letters tolerate one typo (`github_lan`). + Key opens a separate creation field,
  including from a project search result; typing/Return in search never writes. Navigation is white and explanations are
  short. Case has no Doppler integration or import screen.
  All explicitly opened hover submenus survive pointer exit until Back, an
  outside click or bare Escape. The root tools grid follows ordinary hover;
  hardware brightness glances still expire. System authentication and native
  menu/file-picker interaction suspend outside dismissal. Activity/preemption
  policy remains authoritative. UI design: docs/DESIGN.md.
  The encrypted schema-3 vault has projects, descriptions and registered AI
  clients with Accept (stored as approve)/Bypass per app and project. A client's
  allowedProjectIDs is nil for all current/future projects or an explicit set
  (empty denies all). The broker filters listings/ambiguity and enforces scope
  again before value/grant release. Scope/mode changes revoke timed grants.
  Schema 2 migrates without changing existing access; older apps refuse schema 3.
  WHY: docs/decisions/2026-10-20-case-connect-and-scope.md. `Contents/Helpers/whytap`
  exposes `case ls`, `case run [-p project] [--only A,B] '<command>'` and
  names-only `case mcp` (`WhytapCaseKit` / `WhytapCLI`). `case_list_keys(query:)`
  searches authorized key names/descriptions and project names directly; a known
  key uses `case run --only KEY` without listing projects first. The app's local Unix
  socket broker accepts only its bundled helper by audit-token cdhash and
  dynamic validity. It validates every bundled architecture and compares the
  running peer with a valid signed slice, including x86_64 under Rosetta. It
  resolves the caller from its process ancestry; Developer ID identities
  require an Apple anchor. Unregistered known AI clients are refused; human
  requests require Touch ID. Before releasing values or creating a timed
  grant after authentication/approval, the broker revalidates the current
  caller, registration and project. Revoking or rebinding a registration
  invalidates its pending requests, including queued approvals.
  Approve uses a non-activating island panel with physical Y (allow once),
  N/Escape (deny) and A (temporary Bypass). Only the minutes field accepts
  digits, rejecting letters and mixed pastes before insertion. The panel's
  default first responder is the neutral card; opening a prompt does not select
  the duration. WHY: docs/decisions/2026-10-21-case-approval-minutes-input.md. It keeps
  300 ms of keyboard quiet before arming, a 60 s timeout and memory-only timed
  grants. Temporary Bypass is a separate button beside a native editable
  1–240 minute field (default 15), without stepper arrows; the bottom row has
  Deny/Allow only. The command's native hover help contains its full original
  text. While editing minutes the approval keys are suspended; Return commits
  the edit and Escape restores its starting value. Invalid drafts disable timed
  approval and revert to the last valid value on blur. Explicit field focus is
  released on prompt replacement/hide. Buttons expose hover/pressed/focus and
  disabled states. Each new prompt resets its duration. Registration configures the client's names-only MCP entry. The
  helper injects authorized values into the child command's environment and
  applies best-effort masking to stdout/stderr. Deliberately transformed
  output, files and values shorter than four bytes can expose values; this is
  protection against accidental transcript leaks, not a command sandbox.
  The broker's decrypted vault cache outlives the panel's idle lock. WHY:
  docs/decisions/2026-10-19-case-secrets-broker.md

Hover capsules and materials:
  The 2026-10-17 user correction requires hover and the compact island to have
  exactly the same width, with three smaller capsules per row. Follow the actual
  notch-derived compactWidth (310/312 pt examples), not a fixed 457 pt drawer.
  IslandHoverPanelControl.swift defaults to a 90x52 foreground capsule with a
  30 pt white icon disk with 17 pt blue symbols and a normal-case 11 pt title.
  No small status captions are drawn; current values remain in VoiceOver.
  Record lights its icon red with a soft glow while recording, alongside the
  existing right-wing indicator. The grid supplies each instance's exact width through
  IslandHoverControlsLayout.tileWidth(panelWidth:): (panelWidth - 24 - 16) / 3.
  User feedback on 2026-10-18 called the 24 pt disks and 12 pt symbols too small;
  larger icons retain the same capsule and text sizes.
  Historical 2.2.5 icon-refinement proof covers 101 focused tests and 18
  source-matched offscreen renders with no visible/key windows (layout/text only).
  Bundled icon assets retain their own presentation. HoverToolPresentation
  resolves state purely from mode, languages, recording and brightness:
  Fast/Smart, input Auto/language, output Smart only/Off/language,
  Recording/Not recording, and NN%/Extra (none for an unreadable display).
  Stateless navigation tools have no invented status.
  HoverLayoutStore.columns=3. Shared geometry uses 68 pt rows, a 76 pt row
  stride, 8 pt row/column gaps, 12 pt horizontal and 8 pt vertical insets.
  Default six tools occupy two rows and a 243 pt host band. At most four rows
  are visible (312 pt grid viewport); 13 tools retain 388 pt of scroll content.
  Settings stays last; persistence remains. Feature hotkeys use stable tool IDs.
  Settings Toolbox keeps a fixed header outside the catalog and tool pane.
  Saved tools scroll horizontally; Add and locked Settings remain visible.
  Add accepts drops and offers a click chooser. Catalog tiles remain selectable
  and draggable when pinned; their header/context menu supports Add/Remove.
  Translate/Subtitles embed the shared translation models in compact views;
  History disables the island keyboard-paste monitor; Monitor and Record expose
  working panels. Other tools have explicit actions instead of blank panes.
  Embedded translation has token-based ownership, cancels on departure/Settings
  close unless its floating window is visible, and blocks update relaunch while
  visible. WHY: .project-docs/decisions/2026-10-20-toolbox-mini-apps.md.
  Drop targeting highlights without moving targets or saving. Native hosted
  destinations set animatesToDestination=false in prepare, before AppKit removes
  its preview and perform commits the current target identity. Settings has no
  registered drop types; cancel/invalid/stale sessions do not save. No timers or
  manual preview replacement. The 2.2.8/1460 candidate was not published after
  the user reported a duplicate cursor/inserted image. Grid changes
  ease over 0.18 s and highlights over 0.1 s; Reduce Motion disables both.
  The editor can be hosted independently of Case/Vocab/provider stores. WHY:
  `.project-docs/decisions/2026-10-18-toolbox-drag-feedback.md`.
  Drawer, compact pill, music, detached inline panels and native hit zones all
  use the actual compactWidth. Hints overlay stable targets without moving them.
  History needs no drawer overhang: its 300 pt left reservation still fits a
  280 pt preview and 8 pt gap without moving the island's right/top anchors.
  Each card has one native .regular backdrop in an independent background shape
  on macOS 26+, with passive rims and foreground lenses, never child glassEffect.
  Explicit hover/press/magnetic feedback respects Reduce Motion. Older material
  fallback is unchanged. Do not show test windows over the user's work; use
  offscreen checks and state compositor limits. Historical 2.2.4 compact
  candidate passed 69 focused tests and the full 2,947-test suite (8 skipped,
  0 failures, 45.315 seconds). Eighteen actual capsule/search-layout renders cover
  310/312 pt layouts with source-hash match and no visible/key windows.
  Dark text-audit backing is test-only. These checks do not prove native glass,
  real pointer, physical input/focus or live Monitor-button behavior; production
  acceptance remains separate. Historical 2.2.3 evidence (2,947 tests: 8 skipped,
  0 failures; 21 renders) covers the earlier 139x64/457 pt layout. WHY:
  .project-docs/decisions/2026-10-17-native-hover-glass.md

Monitor inside hover:
  Monitor registry kind is inlinePanel and HoverSlotRouter resolves
  .openPanel(.monitor). Capsule, catalog search and feature hotkeys all open
  MonitorHoverPanel in the same compact-width drawer: dashboard picker -> Server
  status or custom dashboard -> Back to picker -> Tools. The 2026-10-18 user
  clarification keeps the Monitor heading and centers it precisely, using equal
  88 pt navigation/refresh slots. Do not remove the heading or grow the drawer
  with dashboard count. IslandView .controls/.monitor share
  controlsHoverPanelHeight(toolCount:): six tools give a 243 pt host band/235 pt
  content; three tools give 167/159 pt. Music adds 50 pt to the host band for its
  strip and gap. The picker scrolls vertically in a bounded LazyVStack; long
  dashboard lists stay within the normal controls height. Keep user-facing
  dashboard choices here; setup instructions and local paths belong in the guide.
  Its compactPresentation uses vertical CPU/RAM/load/GPU metrics and one flexible
  column of custom widgets; the legacy window keeps its existing presentation.
  The view starts MonitorStore when shown and stops it on disappearance;
  Refresh calls requestRefresh and reuses existing collectors/snapshot rendering.
  Hover launch and the legacy openMonitor callback both request inline .monitor
  with programmatic expansion; neither opens a window. The legacy window class
  is retained for compatibility only. Historical 2.2.6 Monitor/search proof:
  2,949 tests, 8 skipped, 0 failures (45.711 s); search-focused 9/0 (3.901 s).
  Source-matched offscreen checks cover 16 Monitor fixtures/20 current PNGs and
  40 search PNGs with no visible/key windows. Synthetic no-op stores avoid real
  collectors/user data; native glass, real pointer/focus and installed-app
  acceptance remain separate. Guide: docs/customization/dashboards.md.

Brightness inside hover:
  Brightness is an inlinePanel tool offered only from the Toolbox catalog and
  search; its capsule title is Display, which fits one line of the narrowest
  capsule. HoverLayoutStore.defaultSlots and saved layouts are unchanged.
  HoverSlotRouter resolves .openPanel(.brightness) to IslandBrightnessStrip:
  Back, a white capsule backlight slider and an Extra switch. A status line
  appears only for a notice or unavailable brightness. The switch is the Settings MacSwitch
  at its 30x18 compact size, blue while on: the island is never the active
  app's key window, where the native switch draws its on state gray. The strip
  is 68 pt (76 pt band, 126 pt with music) and needsKeyboardFocus for its
  controls. Opened from a lower tile, the band keeps the previous height as
  transparent hover space under the top-aligned drawer until the pointer is
  over the drawer's final frame (onContinuousHover with
  IslandView.releasesHeldHoverZone): the shrinking drawer's animated frame
  still covers the held zone, and releasing there closed the drawer under a
  quick move up from the third row.
  ScreenBrightnessController follows the island display (IslandScreenResolver)
  and reads/writes its backlight through private DisplayServices (dlopen); an
  unreadable display gets a disabled slider and no switch. Showing the strip
  only reads, polling every 0.5 s while it is visible or Extra is on; a pinned capsule
  refreshes its NN%/Extra VoiceOver status when hover opens. Extra exists only
  for potential EDR headroom > 1.01 and never writes the backlight. As Vivid
  does it, GammaBrightnessBoost scales the display's own transfer table by
  min(1.45, the sRGB-encoded current headroom), Vivid's measured factor on the
  same panel (white about 2.35x SDR), and BrightnessHeadroomTrigger keeps that
  headroom engaged: a click-through shielding-level 1x1 pt window in the
  display's top-right corner, hidden by a built-in display's rounded corner,
  with an rgba16Float extended-linear MTKView cleared to 2 and sharingType
  none. The display applies the table after WindowServer composites, so an app
  switch cannot dim it; the former full-screen multiply layer dimmed on every
  ⌘Tab. Nothing is written until the headroom exceeds 1.05 (none within 5 s
  ends Extra as unavailable). While the headroom first rises or returns, each
  step is followed at once; any other change applies once it holds 1.5 s.
  Without headroom the display has exactly its own table (a factor within
  0.005 of none is none) and Extra stays on; its current table, a new
  profile's included, is the one boosted when the headroom returns. A table
  already above SDR white (Vivid) or rewritten by another app is left alone
  and ends Extra with "Another app is adjusting this display."; a reset by a
  reconfiguration or profile change is boosted again, and a third reset within
  10 s counts as another app. Ending or suspending gives a table back only
  while the display still has the boosted one. BrightnessBoostFrameTimer presents a trigger
  frame every 0.2 s, strip open or not, then checks the table: without focus
  WindowServer keeps the headroom only ~0.8 s after the last frame. Frames
  pause during display sleep, system sleep and another user's session, each
  until its own end notification, and a gap over 1 s between frames restarts
  the 5 s wait for headroom and the 1.5 s hold; another user's session also gets the
  display's own table until this one is active again. Extra is a fixed boost;
  external backlight changes, including automatic brightness, battery dimming
  and native macOS controls, keep it enabled even with the strip closed.
  Readback cannot distinguish automatic changes from native manual controls.
  The first Whytap slider decrease
  or intercepted brightness-down press only ends Extra, leaving the backlight
  and slider unchanged for that whole drag or held press. The next adjustment
  lowers the backlight normally, including accessibility adjustments and fine
  key steps; outside changes
  are followed within the 0.5 s poll, after the 0.75 s write-settle window.
  Float readback round-off is ignored. Enabling Extra reads a fresh baseline;
  increasing brightness never enables it. Its switch (strip or Settings) also
  ends it, as do serious thermal state, a
  display change or lost EDR support, another app's table, a boost failure and
  quit. Ending it gives the display its own table back (ColorSync's if Quartz
  refuses it; Quartz also restores it when the process exits) and leaves the
  backlight as it is. Extra is never persisted or resumed after relaunch.
  Settings -> Toolbox -> Display (ToolboxDisplayPane) holds the Extra and
  Brightness keys switches without a slider; it reads the display on appear,
  never polls and fits the 188 pt Toolbox area in every state. Brightness keys
  are off by default and saved. BrightnessKeyEventTap, a head-insert session
  tap for system-defined events on a SpaceHoldMonitor.TapThread, takes the
  brightness key presses from macOS, so its indicator does not show: sixteenth
  steps (Option-Shift: 64ths), two brightness-up presses at the maximum within
  1.5 s (timed when the tap sees them) turn Extra on, and each press opens the
  strip as a glance (2 s, no keyboard focus, never over another panel under
  the pointer or a focused search; a pointer reaching it holds the drawer).
  Other modifier combinations, hidden hover widgets and an unadjustable
  display leave the keys with macOS. A press stays with whoever got its first
  event, also across the hotkeys' rebuild; after a gap over 0.1 s or a tap
  macOS disabled, the presses in progress finish with macOS. The tap needs
  Accessibility, is reinstalled with the hotkeys and retried when the Settings
  pane appears. They are the Mac's keys, not a Whytap hotkey: no Help row.
  The battery percentage and runtime line were removed at the user's request
  on 2026-10-21 because the displayed values were unreliable. The estimator,
  IOKit battery reader and background history sampling are removed too.
  Brightness key events are never written to disk, logged or sent. WHY:
  .project-docs/decisions/2026-10-18-brightness-tool.md

Hover tool search and pointer routing:
  Search all tools searches the full catalog (titles, descriptions and aliases),
  including tools not pinned in Toolbox. Activation shares HoverSlotRouter and
  never changes the saved layout. Only clicking the field acquires keyboard
  focus; ordinary hover and active visual treatment leave the user's app focused.
  On macOS 26+, NSSearchField uses a custom cell drawInterior without the black
  bezel, keeping native text/search/cancel geometry; its field editor is clear.
  Its NSViewRepresentable.sizeThatFits explicitly returns the declared 30 pt
  height rather than AppKit's 24 pt intrinsic height. This keeps the native
  24 pt button rect inside the hosted field (y=4), avoiding a measured 1 pt
  overflow at the smaller height. The user-reported Monitor -> Back top slice
  was not reproduced offscreen. Live user feedback on 2026-10-18 confirmed it
  still occurs in the locally installed 2.2.6 candidate: the 30 pt fit is a
  partial correction, not a completed visual fix. Publication was stopped;
  GitHub v2.2.6 remains a draft with no publishedAt. Earlier tests/renders do not
  override this live feedback. The 2.2.7 candidate retains that 30 pt fit and the
  original searchButtonCell, setting only its isTransparent=true for the macOS 26
  glass cell. A separate NSImageView draws the public 13 pt SF loupe in a 14 pt
  square centered inside native searchButtonRect. Its hitTest returns nil and it
  is not an accessibility element. Native button identity, geometry, image,
  target/action, text/cancel and recents behavior are retained; older fallback
  and parent transitions are unchanged. Setup runs in init/layout without focus.
  Current proof: 10 focused tests/0 failures (3.933 s); final integrated full
  suite 2,953 tests, 8 skipped/0 failures (51.673 s), plus 60 source-matched
  native/transparent/explicit-glyph comparison PNGs with invisible/non-key
  windows. Exact clipping was not reproduced offscreen. On 2026-10-18 the user
  separately confirmed the loupe fully visible after installed 2.2.7 Monitor ->
  Tools. Public 2.2.7 build 1459 was published from sealed a35ca9d5778c65e9dbb861535178696c887293ee;
  independent public source/feed, both DMG hashes/signatures and read-only app
  checks passed. Do not claim a proved compositor cause.
  A translucent input lens/rim supplies the foreground surface without child
  native glass. History shares the drawer's Regular backdrop, uses translucent
  rows/hints and a separate preview backdrop. macOS 14/15 fallback is unchanged;
  Case/Vocab/Filler retain their existing transparent panels.
  Internal endEditing does not resign the key window between button down/up;
  captured activation or actual window resignation releases text-entry focus.
  Up/Down select, Return activates, Escape clears the query then releases focus.
  IslandHoverHitBridge measures target NSView frames at event time and clips
  results to their visible scroll viewport. NSWindow down/up must target the
  same unchanged control; drag-out, context/layout change, Escape and panel
  closure cancel activation. Drag/context/Escape cancellation keeps ownership
  of the eventual mouse-up; hiding the panel discards the sequence.
  Geometry reporters and decorative overlays never catch clicks themselves.
  The 42 pt search band and fixed overlaid shortcut hints participate in shared
  layout; hints do not shift buttons. Output language retains its Smart-mode
  requirement. WHY:
  .project-docs/decisions/2026-10-17-hover-tool-search.md,
  .project-docs/decisions/2026-10-17-native-hover-glass.md

whytap:// links:
  CFBundleURLTypes registers the whytap scheme; AppDelegate handles kAEGetURL
  (registered in applicationWillFinishLaunching, queued until launch ends).
  WhytapLink parses only whytap://tool/<HoverTool rawValue> and
  whytap://settings/<SettingsWindowTab rawValue>; its switches over both enums
  are exhaustive, so a new tile or tab needs a destination to compile. The enums
  are the public registry of linkable places: never rename raw values. A link
  only shows a place: inline tools open their HoverPanelRequest, navigate tools
  and tabs open Settings with setHighlight, Translate/Subtitles
  windows open idle, Drop Mode/Record/Screenshot select their Toolbox pane
  (SettingsWindowSelection.focus), Case opens Toolbox without selecting its
  Touch ID pane and Quit highlights the Quit row (Invariant 7). Unknown ids
  or kinds only wake the island; other schemes, credentials, ports, empty or
  extra segments and non-alphanumeric ids are rejected and not logged.
  whytap://hotkey/<HoverTool>?keys=option+shift+s proposes a tool hotkey: the
  key needs ⌃ or ⌥ (A-Z, 0-9, US punctuation, F1-F20), Quit is excluded and an
  unsafe or malformed request only opens Settings -> Hotkeys. Whytap's own
  dialog asks first; taken keys show a conflict and change nothing. WHY:
  .project-docs/decisions/2026-10-20-whytap-links.md,
  .project-docs/decisions/2026-10-21-whytap-link-hotkeys.md

Island display selection (multi-monitor):
  IslandScreenResolver.selectDescriptor is a pure function: user preference
  (Settings -> Other -> "Show island on") -> screen with a real notch ->
  primary display -> first. NSScreen.main is NEVER used (it is the key
  window's screen and moves with every click). All overlay panels position
  through currentDescriptor()/currentVisibleFrame() and follow
  selectionDidChangeNotification. WHY:
  docs/decisions/2026-07-07-island-display-selection-not-nsscreen-main.md

Now Playing:
  MediaRemoteNowPlayingSource runs the vendored adapter as a long-lived child
  (`perl run.pl <framework> stream --no-diff --micros`). The AppleScript
  source is the fallback. applicationWillTerminate calls
  NowPlayingCoordinator.shutdown(), which terminates that child synchronously
  (the async stop() would never run before exit()); the stream keeps running
  through sleep. For SIGKILL/crash the stream runs under a perl guard
  (parentWatchGuardScript) that ends it when the app's end of the guard's
  stdin closes; vendored run.pl stays untouched. WHY:
  .project-docs/decisions/2026-10-19-nowplaying-adapter-shutdown.md
  Missing artwork triggers a background get --micros with a 2s deadline,
  one request at a time and a 5s retry cooldown. Recovery copies only the image
  into current metadata, matching player/process/content item/title/artist/album
  and the request generation; track changes, clears and lifecycle resets reject
  stale results. No Automation prompt is added. WHY:
  .project-docs/decisions/2026-10-19-nowplaying-artwork-recovery.md

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
  Scheduled check -> "Update" pill -> hover: Download | Skip -> download
  with a CALayer spinner (IslandUpdateSpinner; SwiftUI .repeatForever would
  freeze during main-thread stalls) -> requested install + relaunch while idle
  -> "Updated" indicator for 5s on the next launch (JustUpdatedIndicator,
  one-shot marker). A meeting recording, dictation or agent activity defers the
  app-initiated relaunch into Ready with Restart / Later; returning to idle alone
  never restarts it. Ready-stage Later replies .skip, cancelling the current
  installation without permanently skipping the version. The user approved
  applying a prepared, already downloaded update on ordinary application quit,
  unless Later cancelled it. Restored downloads use the same Ready actions and
  ordinary-quit policy. This does not guarantee behavior after force quit,
  crashes, process kills or power loss. A final Sparkle delegate guard rechecks
  activity before an app-initiated relaunch. Feed = GitHub Releases
  (`BuildConfig.appcastURL`).
  Update/Skip and Restart/Later use measured NSWindow down/up dispatch for
  first mouse, including alongside a different open hover tool. Native buttons
  retain keyboard/accessibility activation and hover/pressed/focus feedback.
  A download click publishes the spinner immediately, before Sparkle reports
  its first bytes; repeated or stale clicks do not repeat the action. Moving
  off the button or changing its stage/build cancels the captured press.
  Community archives use our independent Sparkle Ed25519 signature. The app
  is signed with the Developer ID certificate of the
  team in Resources/developer-id-team.txt (team designated requirement and
  keychain partition, so TCC grants and Keychain access survive updates);
  without that file with Whytap's self-signed community certificate when
  Resources/community-signing-certificate.pem is committed, otherwise ad hoc.
  Published team builds are also Apple-notarized and stapled (app and DMG).
  Source dev builds (9999 / -dev) do not start the binary updater. WHY:
  docs/decisions/2026-10-21-notarized-releases.md,
  .project-docs/decisions/2026-10-17-community-updates.md,
  .project-docs/decisions/2026-10-19-community-signing-identity.md,
  .project-docs/decisions/2026-10-21-developer-id-team-signing.md,
  docs/decisions/2026-06-17-update-download-on-action.md,
  docs/decisions/2026-07-08-update-download-spinner-and-post-relaunch-updated-indicator.md
```

Presentation: Settings -> API & Models has four internal tabs: API keys,
Models (the initial tab), Costs and API hints. API keys holds the provider keys (Soniox,
Deepgram, ElevenLabs, OpenRouter, OpenAI, Anthropic, and the user's
OpenAI-compatible servers) and one model per AI feature (Drop Fast, Drop
Smart, Drop Smart cleanup, Meetings, Meeting notes, Agent, Agent voice, Voice
search); Local was removed. Models come from provider catalogs plus the
built-in registry; a model outside the registry is checked with a synthetic
probe when picked or on Check now. The first launch migrates the old choices
into per-feature routes (AIRoutingMigration) and leaves the old UserDefaults
keys untouched so a rollback sees them; nothing is switched to another
provider or model automatically. WHY:
.project-docs/decisions/2026-10-19-api-and-models.md Preserve saved
processing routes: never switch where existing users send audio or text. A
retired Local choice shows "not set up" banners until the user saves a
provider. WHY: .project-docs/decisions/2026-09-10-byok-and-local-builds.md,
.project-docs/decisions/2026-10-18-remove-local-models.md

Costs: the local ai-usage.sqlite journal records only feature/provider/model,
request ID, time, duration, currency and expense metadata from actual runtime
calls. Historical routes are captured before sending; switching models does not
rewrite past usage. Only used feature groups appear for the selected local-date
period; hover/click/keyboard focus reveals their models. One Price column
retains explicit USD and ElevenLabs credit units, both when mixed. Each visit
starts at This month; matching neutral From/To controls open a dismissing native
calendar. No permanent bottom explanation or sticky text-segment highlight.
OpenRouter response costs are reported. Direct Anthropic text/Agent calls
estimate USD from response usage tokens with published per-model rates
(AnthropicUsagePrices, marked ≈); unknown models, fast mode or missing usage stay
unavailable. WHY: .project-docs/decisions/2026-10-27-anthropic-token-costs.md
Soniox reads exact request cost_usd from
usage logs by random client reference and historical model; missing/delayed API
prices retain public hourly estimates marked ≈. New meeting checkpoints retain
the same reference across retries. Exact prices upgrade estimated journal rows
once, never duplicate or downgrade reported costs. ElevenLabs feature estimates
use recorded audio minutes times a cached STT model credit/minute rate, marked ≈.
Only model rates/update time are cached; rate refresh failures retain usable
rates. First-use models without a rate stay unavailable. Recording never makes
a billing read. No workspace Reported usage block, balance deltas, account-total
allocation or USD-to-credit conversion. Missing prices are never zero; partial
totals show +. OpenCode's computed step prices remain estimates.
Tracking starts with this update; synthetic model checks are excluded. WHY:
.project-docs/decisions/2026-10-20-feature-costs.md

API hints: the fourth tab contains five offer cards with allowances and official
links, including Tavily web search for Agent (1,000 monthly search credits,
basic search costs one credit, no card required). It distinguishes starter
credit, monthly allowance and paid-plan benefits. Dates are per-card: Tavily
October 22, 2026; the four earlier offers October 19, 2026. The odd final card spans
two columns; narrow surfaces use one column. Add API key opens the
existing API-key form. Tavily has its own search tile there, without model routing.
Opening hints never checks balances or changes routes. WHY:
.project-docs/decisions/2026-10-19-api-hints.md

Model selection uses ModelPicker: a searchable native popover sharing the 30 pt
MacPopupLabel. Name/size terms match in any order (`qwen 27`, `qwen27`), ignoring
case/separators. Search never changes routes; explicit picks retain verification.
Known catalog dates appear under model IDs: Anthropic Released, OpenAI Created,
OpenRouter Added to OpenRouter. Unknown/epoch dates stay hidden.
Speech models: Deepgram Updated uses cached newest version dates;
Soniox/ElevenLabs Released uses exact stable IDs with verified official launch
dates in ModelRegistry. Unknown models/aliases inherit no release date. Nonempty search
breaks equal-relevance ties by newest date, unknown last, within provider groups;
equal dates and empty queries keep catalog order. Older caches refresh once for dates.
Up/Down and Return choose enabled results; Escape clears then closes. Opening
the picker refreshes stale/failed catalogs automatically; the footer has no
Refresh models or Other model ID actions. Custom servers without /models offer
a contextual model-name field. API keys uses square provider tiles opening an
inline Save/Remove form with no extra helper/status copy; a short Key accepted
or Key not accepted notice reports the result. Failed checks keep the previous key. WHY:
.project-docs/decisions/2026-10-21-provider-key-tiles.md;
.project-docs/decisions/2026-10-20-model-search.md

Other selection menus use MacMenu/MacPopup: a 30 pt neutral control with 8 pt corners
and one down chevron, retaining native menu tracking. Provider menus,
Backup, display, account/key sheets and translation share this label; the
screenshot toolbar uses its AppKit counterpart MacPopupButton. Notifications
centers the menu and enable switch, moving Notification type into the adjacent
question-mark tooltip/popover. Bindings and saved selections are unchanged.
WHY: .project-docs/decisions/2026-10-20-compact-selection-menus.md

Settings follows macOS light/dark appearance while open. MacSettingsTheme owns
dynamic SwiftUI/AppKit colors; the shell uses inset groups and text-only sidebar
rows with a 140 ms background hover fade (immediate with Reduce Motion).
MacSwitch adapts the supplied glass switch in SwiftUI with click/drag,
keyboard and native Toggle accessibility, respecting Reduce Motion/Transparency.
The island keeps its compact blue switch and explicitly dark Toolbox previews.
UI decisions and verification limits: docs/DESIGN.md.
API & Models separates function rows; missing setup uses a static orange contour
and soft glow instead of Not set/triangle status lines. Actual problem text and
recovery actions remain. Shared settings rows use spaced, full-point dividers.

First run: no sign-in and no onboarding wizard. Launch and reopen show the
island immediately. The first GUI launch on each Mac also opens Settings ->
Permissions once if any listed permission is missing. Already authorized Macs
skip this presentation; a dismissed screen is not reopened at every launch.
The local presentation marker is excluded from settings backups. Showing the
screen requests no permission automatically. WHY:
.project-docs/decisions/2026-10-26-first-launch-permissions.md.
Configure provider keys and endpoints in
Settings -> API & Models (the agent's model is chosen there too; Settings ->
Agents configures native connection and action settings), and permissions in
Settings -> Permissions. A feature can request the permission it needs when
invoked. Drop without a chosen provider, key or endpoint opens
Settings -> API & Models on that feature's row. Settings opens on API &
Models; screenshot protection is in
Other (default off). The former tour, resume state, preview target and
voice demos were removed. WHY:
.project-docs/decisions/2026-10-17-local-workspace.md

Notify includes a built-in Meeting notes source, enabled by default for new and
existing users unless explicitly switched off. MeetingReadyNotifications sends
successful newMeetingAvailable events to the local queue/history with the
packaged Whytap app icon in color. Settings -> Notifications has a persistent switch; Notify ->
Sources also has the switch. An optional internal meetingID in the archived
event opens that exact note through SettingsWindowController.selectNoteMeeting;
scripts cannot supply this target. Failed processing does not announce success,
and loading history does not replay old popups. WHY:
.project-docs/decisions/2026-10-20-meeting-ready-notifications.md

Notify: agent-configured local scripts emit JSON lines with title, body, event
ID, optional link, color, logo and duration. NotifyScriptSupervisor reads private
sources/<id>.json manifests, supervises child process groups only during the app
lifetime, restarts with bounded backoff and stops on disable, removal, sleep or
quit. A perl stdin-EOF guard (NotifyProcess.parentWatchGuardScript) leads each
group and ends it when the app is killed or crashes. WHY:
.project-docs/decisions/2026-10-19-notify-parent-death-guard.md. No backend or built-in provider connectors are restored. The original
IslandNotificationPill / nonactivating panel sits left of the island, using the
selected screen and screenshot-protection preference. All notifications use
cards (8 seconds by default), queued in arrival order with at most 33 presented
or queued events. Hover pauses dismissal, brightens and enlarges the card by 3% from its
top-trailing corner (except with Reduce Motion). Transparent panel overflow
fits the transformed card on notched and unnotched displays, and the hosting
hit region follows its visible size. The 8 pt island gap stays fixed. Small notification
rendering, stacks and type controls are removed. Legacy presentation fields are
ignored; missing titles use the source name, preserving former icon-only sources.
Notify retains 500 history events. Unseen events show a red dot only on Notify in
hover/search until history is opened, including after a restart. Clear All is
text-only and immediately clears history and current events, preserving sources.
NotificationSoundSettings persists Off (default), Glass, Ping or Pop per source;
Settings selection previews the sound. LocalNotificationHub signals fresh accepted
arrivals within the presentation limit. Duplicates, restored history and suspended
delivery stay silent. NotificationSoundPlayer bounds bursts to one sound per
0.75 seconds and never overlaps sounds; scripts cannot enable them. WHY:
.project-docs/decisions/2026-10-20-notification-cards-and-sounds.md.
Existing Codex chats support click-through
via codex://threads/<thread-id>; no query/fragment or new-chat/action links.
Claude Desktop local Code sessions accept
claude://code/continue?session=local_<uuid>, restricted to that one parameter.
Native sessionId is resolved from Desktop metadata by the hook's cliSessionId;
it is not the hook ID with a prefix. Other Claude routes are rejected.
Bundled logos include codex and claude-code. Actual agent event sources are
configured separately. WHY:
.project-docs/decisions/2026-10-19-icon-notifications.md. Hover pauses dismissal.
LocalNotificationHub persists up to 500 events, deduplicates scoped IDs and keeps
content in history; unreadable history is never silently overwritten. Notify
opens through hover search, Toolbox and assigned feature hotkeys without
changing saved layouts. Settings -> Notifications lists connected sources with
their name, logo, runtime status and individual persistent enable switches.
Disabling stops the source and keeps its setup/history for re-enabling.
Agents get a resolved setup-guide path on every turn.
Guide: docs/customization/notifications.md. WHY:
.project-docs/decisions/2026-10-19-script-notifications.md

To-do opens a compact inline hover list with Return-to-add, click-to-complete/reopen
and a History mode with completion date/time. Completed tasks move below active
ones for the current opening, then appear only in History. Native tooltips expose
full truncated titles. Drafts survive closing; saved Toolbox slots remain unchanged.
Calendar opens a 350pt inline Hover agenda on today. Tile, search, assigned hotkey
and whytap://tool/calendar use the same surface; reopening resets to today.
Day navigation, full event details, feed selection and Connect stay in Hover.
Connect starts the provider browser or macOS permission prompt directly, using
the same CalendarConnectionFlow as Settings → Integrations. No intermediate
form, account-name field, Advanced app setup or Whytap account is shown.
Unavailability/errors stay inline; progress and Cancel remain on the source list. Toolbox uses the same inline entry; there are no runtime
PlannerWindowController calls. CalendarConnectionFlow keeps permission work alive
through temporary Hover hiding. Only Hover-owned connections pin its menu;
Settings connections do not. Repeat opens preserve an active connection.
Success reactivates Hover only if visible; failures retain a retry path.
WHY: .project-docs/decisions/2026-10-21-calendar-hover.md
PlannerStore atomically saves private local tasks
and Whytap events; unreadable archives block writes. CalendarConnections combines
selected EventKit calendars with direct Google Calendar, Microsoft Graph (including
Teams links) and Zoom Calendar Service connections. Remote events are read-only;
visible-range recurrence is provider-expanded, refresh runs only while the calendar
view is visible, and matching UID/occurrence bounds collapse duplicate sources.
OAuth uses browser S256 PKCE/state, a numeric loopback listener (Microsoft redirects
to localhost), and Keychain credentials with durable refresh-token rotation.
Short-lived access tokens stay in memory and are excluded from backup; only a
refresh-token/client change updates the saved authorization. Token rotation alone
does not create a settings version or full backup; subsequent backups capture the
latest token, and restored sign-in can require reconnecting. No
shared OAuth registrations are created by the app itself; the owner supplies
registered native clients during packaging through configure-calendar-clients.py.
Settings → Integrations lists Google Calendar, Outlook Calendar, Apple Calendar
and Zoom Calendar separately, with feature permissions and direct provider authorization.
Shared Google and Zoom clients cannot start new browser sign-in until actual
provider approval is recorded by the publicAccessApproved packaging string.
The owner's verification recording has an explicit process-local Google-only
review opt-in with a maximum two-hour deadline; ordinary launches stay closed,
and no packaged approval or saved preference changes. The builder owns its
safe launch; docs/google-calendar-verification.md describes activation. Expiry
blocks new sign-ins but does not revoke completed grants.
Missing or malformed approval remains closed outside that review session; source users
can supply independent native clients at build time. Connection activity is shared across Settings
and Hover, serializes sign-in, and defers restore/update restart until completion.
Backup work, staged restore and pending maintenance also block new connection
changes so restore cannot overwrite a newly connected account.
Live accounts require provider setup and separate acceptance. Encrypted backups
include local Planner content, calendar metadata and saved credentials. Old backups
preserve current calendar settings. A visible Calendar/Planner, inline To-do, or retained task draft
defers update restart and restore; ordinary backups still run. Closing the panel
stops calendar polling; another tool hotkey preserves an attached editor. Tests
use fake providers and temporary stores. Guide:
docs/planner.md. WHY: .project-docs/decisions/2026-10-19-planner.md,
.project-docs/decisions/2026-10-20-todo-hover.md,
.project-docs/decisions/2026-10-21-calendar-integrations.md

Customization: any local coding harness can use the same source checkout.
Run `python3 scripts/customize.py discover --json` for commands, change
contracts and source entry points; `doctor --json` checks build prerequisites.
Build/run use the canonical dev bundle script; hover and dashboard scaffolds
are drafts. Guide: docs/customization/README.md. Update the capability map
when moving its source entry points. Do not publish private monitoring
configuration, project contents or credentials with the source.

Application control: `plugins/whytap` bundles separate local stdio MCP servers:
`Contents/Helpers/whytap app mcp` for app controls and `whytap case mcp` for
authorized Case project/key names and descriptions, never values. Case retains
its existing registrations, project scope and approvals; secret use stays in
`whytap case run` through the agent's own terminal. The app-control server reads
live build/activity/route metadata and changes allowlisted models, provider pins,
Drop mode, languages and idle
auto-hide through existing app stores. Every write requires the current value;
async model checks recheck the route and cancellation before assignment. It
shares Case's authenticated bundled-helper transport but never loads its vault
or uses its registrations/grants. Any local process running that helper as the
user can access these non-secret settings; no arbitrary defaults, keys,
security controls, user content, recording, shell execution or quit are exposed.
Guide: docs/customization/app-control.md. WHY:
.project-docs/decisions/2026-10-21-app-control-plugin.md

Agent answers: native Whytap Agent keeps intermediate text hidden and publishes
the completed answer and show_actions metadata after successful completion.
Text alongside successful presentation-only calls survives an empty final;
a nonempty final wins, and evidence/action tools invalidate the fallback.
Recent context includes returned card descriptions/destinations, and History
persists visible text together with cards in both blocks and Markdown.
The compatibility extractor also handles a trailing useful.actions fence.
NativeAgentAnswerArtifacts also turns ordinary final HTTP(S) links and returned
absolute/tilde paths into the same keyboard-action cards if the model omits
show_actions. Explicit metadata wins; destinations deduplicate and cap at 20.
The fallback scans at most 32,000 characters, skips ordinary code/config fences,
and does no network/file I/O or extra model call. It formats returned paths,
not verifies their existence; nothing opens or inserts before user interaction. A
folder answer provides the verified absolute path in a copyable code fence
and a path action for open/insert. Simple answers use 1–2 short sentences;
longer answers remain available when requested.
The native capture_screen tool calls AgentScreenCapture directly, independent
of Case and the edit/command switch. It uses the app's Screen Recording grant,
selects the island display, and returns JPEG (long edge <=1920, <=2 MB) within
10 seconds, with cancellation and a busy guard. No file, clipboard or input tap
is created. Pixels go to the selected model only within the current tool loop;
the provider may retain them according to its policy. Never substitute a vision
model. The separate screen MCP helper remains for compatibility; the settings
MCP scope does not accept capture. WHY:
.project-docs/decisions/2026-10-22-native-agent.md

Clipboard history retains the newest 50 local entries across launch, quit and
sleep/wake. Do not reintroduce automatic lifecycle wipes. New copies evict only
the oldest excess rows and their image sidecars; the current History feed shows
20 clipboard entries in a scrollable five-row viewport (Agent/Drop keep 10),
without deleting other retained rows. A clipboard row's context menu offers
Delete… in hover History, Toolbox History and the ⌥V strip; ClipboardEntryDeletion
asks Cancel-first like meeting delete and never quotes the copy. deleteClipboardEntry
removes the image sidecar, then the row with secure_delete and a truncating WAL
checkpoint, in one store-queue hop; a sidecar that cannot be removed keeps the
row listed. History key monitors ignore keys while a modal alert is open.
Uploaded backups are unchanged (pre-2026-10-21 archives restore History). WHY:
.project-docs/decisions/2026-10-22-clipboard-entry-delete.md
The History connection sets secure_delete=ON, so cap evictions, agent trimming
and Delete… zero freed bytes and pages. After store setup,
scrubFreePagesInBackground VACUUMs each database file once off main (version in
its own history_maintenance table, so a restored older copy is scrubbed again),
keeping every row and id, then truncates the WAL. Too little space (2x live rows
+ 64 MB) or an incomplete checkpoint records nothing and retries next launch.
WHY: .project-docs/decisions/2026-10-22-history-free-page-scrub.md Startup seeds only the current
pasteboard change counter; dictation write/restore suppression remains. Before
replacing a running older binary with the old quit purge, preserve local
clipboard data privately and restore only clipboard rows/assets after quit.
WHY: .project-docs/decisions/2026-10-18-clipboard-retention.md
Changes marked with nspasteboard.org Concealed, Transient or AutoGenerated types
on any item (password managers, Backup's recovery-code copy) are excluded
from storage. Initial markers skip payload reads; a second type check discards
markers added during a read. The watcher advances its change count and logs
only marker names. WHY:
.project-docs/decisions/2026-10-21-clipboard-privacy-markers.md

Installation: SidekeyAppMain checks InstallationGuard before constructing the
app delegate. A read-only or AppTranslocation copy shows Finder installation
instructions and quits before permissions, provider discovery or updates.
ApplicationInstanceCoordinator then acquires one common prod/beta/worktree lease
before constructing AppDelegate. A second copy offers to activate the owner and
quits without starting permissions, providers or hotkeys. Legacy binaries launched
later cannot honor the lease. The Settings footer shows only the actual app name
and display version, separated from website and GitHub links by a thin rule.
All footer text uses the same size; the links have icons, a pointing-hand cursor,
hover/press highlights and destination tooltips. Detailed build identity stays
in bundle metadata, outside this compact footer.
WHY: .project-docs/decisions/2026-10-19-one-running-copy.md
`--installation-check` loads the packaged executable and verifies resources
without starting the app runtime. User guide: `docs/install.md`. Policy:
`.project-docs/decisions/2026-09-10-public-installation.md`.

Targets: library `Sidekey` (all app code) + thin executable `SidekeyApp`
(product `Sidekey`, `SidekeyAppMain.run()`) and `SidekeyTests`. Flavors: `prod` (default) and `beta` (`-DBETA`: separate
bundle id, keychain service and feed), see `Sources/Sidekey/BuildConfig.swift`.

## User artifact backup

Settings → Integrations connects GitHub using an existing CLI login or an access
token. Settings → Backup shows its synchronization status, a GitHub Releases link and Back up /
Restore backup. Back up always includes all supported user data and stored keys,
except meeting audio and the History database (see below), uploads and verifies ciphertext, then displays the recovery code without a
paste-back step. Restore takes only that code and stages every included section
from the newest completed matching-key GitHub snapshot by authenticated capture
date, without a selection/confirmation wizard. A new Mac restores existing
copies before uploading under another recovery key. Repeat code display requires Mac
authentication; a never-presented first code keeps a save-code status visible.
A normal quit and relaunch applies it; the running stores are never replaced.
The only backup setting is a visible Automatic backup switch; there are no
management/history disclosures or folder picker. Existing automatic schedules,
folder destinations, local encrypted history and unfinished maintenance recovery
remain compatible internally. The first successfully created GitHub backup enables
automatic sync. Existing verified GitHub copies adopt it once. Pausing (the switch
or cancelling a sync) persists across restart, is re-read each poll, and Back up
then saves one copy without resuming. Pending edits, failed transfers,
pauses and maintenance never show Backup synced. Background sync keeps the same
recovery credential without revealing it. WHY:
`.project-docs/decisions/2026-10-20-backup-auto-sync.md`.
The 60-second poll only marks detected changes pending. Automatic complete
captures start at most hourly, changed or not, and need room for one more archive
plus a 10 GB reserve (2 GB for Back up); transfer retries keep their own backoff.
Local archives are only unsent snapshots, resumable transfers, restore checkpoints
and the newest copied archive (the next delta parent), released after each upload
and at launch; entries whose archive vanished are forgotten. GitHub copies are
never deleted automatically. WHY:
`.project-docs/decisions/2026-10-21-backup-capture-pacing.md`.
Backups carry meeting text only (catalog, notes, transcripts) and no History
database (clipboard, recent dictations, agent answers): retained audio is
debugging material and made every snapshot gigabytes; clipboard can be copied
again. The history section holds Costs. Neither meeting audio nor the History
database churns the change probe; Costs changes remain tracked.
Restoring a newer archive leaves this Mac's recordings and History untouched;
older archives still restore them, recordings parked. WHY:
`.project-docs/decisions/2026-10-21-backup-essentials-only.md`.
At least hourly while running and idle, coherent content is hashed even without
metadata changes. Only changed content creates a new encrypted archive. Calendar
refresh-token rotation uses the same client-identity comparison as settings
history; the next real snapshot still contains the current authorization. Capture
precedes network transfer: retain the freshest pending automatic generation and
a resumable upload, coalescing only superseded unprepared automatic snapshots
after a verified replacement is durable. Network failures back off, including
a connection check after an offline launch, while
actual authentication/permission/public-repository failures require reconnecting.
GitHub rate-limit deadlines are respected. A missing saved draft falls back to
the verified snapshot tag or a new managed draft. Unchanged unsupported inputs
retry at most hourly. Startup removes recognized abandoned scratch generations
and unindexed transfer files, preserving indexed/resumable/recovery data and
files protected by unreadable or explicitly parked catalogs.
Older schema-4 archives restore retained recording originals and repair
checkpoints as inert files, excluding active provider jobs. Inactive configurations and
coexisting older copies survive repeated restores; schemas 1–3 remain readable. Local Case application
policies precede imports, including matching identities with different UUIDs.
WHY: `.project-docs/decisions/2026-10-21-backup-reliability.md`.
A resumed upload accepts an existing draft part when GitHub's reported
`sha256:` digest matches the local part, without downloading it; a mismatch
replaces it, and assets without a usable digest are compared by one download.
New parts and the index are still read back before publishing. Settings shows
"Uploading backup part N of M…". WHY:
`.project-docs/decisions/2026-10-21-backup-resume-digest.md`.
GitHub connection checks are read-only; Connect is the only action that can
create the private Exodia-Backup repository. Connection alone never backs up data.
API & Models routes, server registrations and their provider keys are included.
Costs history is exported by the live AIUsageStore actor and verified with a
strict schema/row validator. Restore retains target-only spending and the best
known price per request ID; older archives without Costs leave it untouched.
WHY:
`.project-docs/decisions/2026-10-20-simple-github-backup.md`.
Workspace traversal and change detection honor valid regular `CACHEDIR.TAG`
markers on nested Monitor/Notify directories. Tagged runtime dependencies are
excluded with an archive warning; nearby scripts, configuration and working
data remain included. Names alone never exclude a directory and links are not
followed. WHY:
`.project-docs/decisions/2026-10-21-backup-tagged-caches.md`.

ArtifactBackupEngine receives the actual live MeetingsStore/AIUsageStore
instances, whose export methods freeze database/sidecar generations. Restore
validates into a parked transaction and applies before any stores or jobs open,
with durable rollback of files, preferences and provider keys. Committed
transactions resume finalization after a crash; replaced generations and their
encrypted before-state keys are retained. Never discard an unfinished rollback
because Keychain retries are exhausted. The startup recovery UI accepts the
saved code without opening stores. Case merges into the target's own vault/key. Imported
jobs and Notify/Monitor configurations stay inert pending review. No Whytap
backend, automatic GitHub Actions, silent source changes or forced restart.

Guide: `docs/backup.md`. WHY:
`.project-docs/decisions/2026-10-19-config-backup.md`.

## Screenshots

Screenshot is an action tool in hover search/Toolbox with an optional named
hotkey. ScreenshotCoordinator explicitly captures displays with ScreenCaptureKit,
then shows a frozen selection canvas and a wrapping native toolbar exposing all
commands, Copy & exit with a centered Return keycap, and Download. The keycap
uses HotkeyHintView through a click-through hosting view inside the same native
button; its label and keycap group are centered together. Color/width and other contextual controls
live in a separate adjacent ScreenshotToolSettings panel. Capture requests the
filter's full Retina pixel dimensions with best resolution; PNG export keeps
those pixels without resizing. Repeated activation
preserves the editor; unchanged display notifications are ignored. Capture has
its own 10-second deadline with retry, cancelled before editing. Unknown keys
are consumed locally to avoid recursion through ScreenshotCapturePanel; Tab
traverses both bars. Generated-fixture capture tests inject private notification
centers and no foreground app through ScreenshotCaptureEnvironment, isolating
real Space/display changes and focus. Production uses the system environment.
Both bars avoid the display's top safe area. PNG stores
Retina point scale as well as full-resolution pixels. The visible Hover state
is held until capture freezes its pixels; Whytap surfaces are included, and no
island wake or dismissal happens first. Only a dragged area is exported: Enter
without selection does nothing, double-click does not select a full display,
and the passive instruction strip is removed. Return copies the selected area
and closes, waiting for pending Blur. Download writes collision-safe timestamped
PNG files into Downloads and shows the actual filename without closing. Arrow,
Shape, Pen, Text, Blur, Numbered steps, Copy text and system sharing remain on the main
toolbar. There is no Select/crop button or V shortcut; initial area selection
remains a drag. Clicking the active tool again stops drawing and permits
selection/annotation adjustment without an extra selector. Highlighter,
Spotlight, Pin above windows and
Output size are removed, including their commands/shortcuts. Copy text uses accurate
on-device Vision recognition on the flattened, edited crop, including Blur,
then copies plain text and closes. Empty/error results keep the editor open;
Escape cancels and generation checks reject late results. Rendering and OCR
run off the UI thread. Copy text can also be assigned to an arrow without
changing existing bindings. Cmd-Z / Shift-Cmd-Z undo/redo screenshot edits
from every screenshot panel through both key-equivalent and direct window dispatch,
using physical Z so Russian input works; focused text fields retain native text undo.
ScreenshotToolbar contains four grouped shortcut buttons, each enclosing its tool icon and arrow keycap: Up Blur, Left Shape, Right Pen, Down Text by default.
The whole pair shares its border, hover, pressed, focus and drop target; wider gaps separate assignments.
Drag a toolbar tool/action or an existing assignment onto a pair to replace
only that destination, or click anywhere in the pair for a native assignment menu and per-arrow
reset. Changes save immediately through HotkeyPreferences.screenshotArrowBindings;
Help and settings backups share it. Custom mappings survive this placement change; the previous unmodified stock map
migrates once to the new four drawing defaults.
The earlier Settings-only assignment surface is removed. Bare arrows use those actions,
Shift-arrows move the crop and Option-arrows resize it. Agent Useful Links
releases its Carbon registrations while Screenshot is active, restores the
latest visible actions afterwards, and invalidates stale callbacks. Blur defaults to Text and numbers, including
standalone digits, using fast Vision regions plus a bounded isolated-glyph atlas
without language correction. Dark crops are
normalized only for detection; output keeps original colors. Each text region
gets its own blur strength, with stronger masks applied last. Crop-first compositing, Blur and PNG export run off the UI
thread; a shared hardware Core Image context avoids per-gesture setup.
Entire area is the alternative. Detection is
best-effort and the visible result must be checked. Exports flatten edited
pixels. No capture is persisted before an
explicit export. Active editing/processing/dialogs block app-initiated update
restarts; screen/Space changes and sleep cancel stale captures. This system OCR
is separate from the removed app-managed speech/LLM models. Guide:
`docs/screenshots.md`. WHY:
`.project-docs/decisions/2026-10-20-screenshot-toolbar.md`.

## Permissions

- **Screen Recording** for explicit screenshot capture (Screenshot tool only).
  Settings -> Permissions shows a green circled checkmark when granted, or
  the same Allow button used by the other permissions when missing, without
  status chips or an action on a granted row. Only explicit capture or Allow
  actions request access, never launch or refresh. Settings Allow uses an async
  ScreenCaptureKit content request without capturing pixels or audio, then
  opens System Settings if access remains denied. A pending request shows
  progress and ignores repeated clicks. WHY:
  .project-docs/decisions/2026-10-26-first-launch-permissions.md. Returning
  from System Settings refreshes the status; it never gates launch/Drop readiness.

- **Accessibility** gates `NSEvent.addGlobalMonitorForEvents`
  (`RightCmdGestureMonitor`; `EscapeCloseEventMonitor` consumes only the first
  bare Escape press for a visible Agent answer, drains its repeats/key-up and
  releases the next press to the user's app. It yields during Drop recording, Screenshot,
  Case approval and shortcut recording, and stays off in agent recording,
  composing, acting-only and idle without an answer. WHY:
  docs/decisions/2026-10-23-agent-answer-escape-consumption.md), the AX check
  of the focused field (`PasteTargetValidator`) and, empirically, the active
  `CGEventTap` in `SpaceHoldMonitor` and the optional Brightness keys tap
  (`BrightnessKeyEventTap`) and the Case approval tap (`CaseApprovalKeyTap`,
  only while a prompt is queued; clicking remains available without the tap).
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

Drop reconciles failed installations and permission changes on activation,
reopen, Settings Refresh/Retry and a bounded quiet polling session. Carbon tap
shortcuts remain registered without AX so invocation can show permission repair.
Permission checks guard Start only; Stop is always available. Rebuilding active
capture monitors waits until capture ends. Background polling never asks for a grant.

## Commands

```bash
# Source build: existing local Sidekey Dev identity, or ad-hoc fallback.
# No Apple Developer account. macOS may require permissions again after rebuilding.
# Use the packaged app, not `swift run`, for permissions and resources.
./scripts/dev-run.sh --run

# Tests
swift test

# Harness-neutral change discovery and environment check
python3 scripts/customize.py discover --json
python3 scripts/customize.py doctor --json

# Explicit ad-hoc local build if no local certificate is desired
SIDEKEY_DEV_CODE_SIGN_IDENTITY=- ./scripts/dev-run.sh --run

# Community binary: local universal build, Developer ID team signing;
# a run that publishes also notarizes (EXODIA_NOTARIZE, key from Whytap Case)
FLAVOR=prod ./scripts/user-release.sh --preflight-only
# Commit relevant build inputs before the build; retain the adjacent DMG manifest.
# The team's Developer ID certificate comes from the login keychain.
FLAVOR=prod ./scripts/user-release.sh --build-only
# A publishable build-only archive is notarized and stapled:
FLAVOR=prod EXODIA_NOTARIZE=1 ./scripts/user-release.sh --build-only
# Publishing also needs the project's Sparkle signing key and GitHub access
FLAVOR=prod ./scripts/user-release.sh --upload-only
```

Whytap stays open source and uses ready-made community builds for normal installs
and updates. The default DMG/Sparkle pipeline builds and signs locally with the
Developer ID certificate of the team committed in `Resources/developer-id-team.txt`
(UVBKCN5PPV). A run that publishes also has Apple notarize and staple the app and
the DMG (`EXODIA_NOTARIZE`, default 1 when publishing a team build; `--build-only`
local refreshes skip it unless set). The App Store Connect API key comes only from
Whytap Case project `whytap` (`ASC_API_KEY_ID`, `ASC_API_KEY_ISSUER_ID`,
`ASC_API_KEY_P8`), injected per submission by `whytap case run` into
`scripts/notarize-submit.sh`; never Doppler, the repository or output. A team
upload requires a notarized manifest and stapled DMG unless `EXODIA_NOTARIZE=0`.
Publishing requires our independent Sparkle Ed25519 signing key and GitHub
access. Keep archive signature verification and app integrity checks. The older
notarized mode remains optional behind `EXODIA_LEGACY_SIGNED_RELEASE=1`. WHY:
`docs/decisions/2026-10-21-notarized-releases.md`. Do not disable Gatekeeper or other OS
protections. First downloads may require user approval. Never change the team:
it is in every build's designated requirement and keychain partition, so another
team makes every install regrant macOS permissions and approve each Keychain
item. Without the team file the build signs with the public community
certificate, whose private key lives only in Doppler
(`EXODIA_COMMUNITY_SIGNING_KEY`, `sidekey/dev`) and is never committed or
printed. WHY:
`.project-docs/decisions/2026-10-17-community-updates.md`,
`.project-docs/decisions/2026-10-19-community-signing-identity.md`,
`.project-docs/decisions/2026-10-21-developer-id-team-signing.md`.

Release provenance is required: commit and clean Sources, Resources, Package.swift,
Package.resolved, VERSION and scripts before building. Capture build-time HEAD;
seal archive SHA-256/size, version, build, flavor, code-signing identity and
notarization in `<DMG>.manifest.json`.
Upload-only requires the adjacent manifest. Reject missing/inconsistent
provenance, changed HEAD or archive bytes before signing-key access/uploads, and
target the release at the verified manifest's build commit. Rebuild after changing
HEAD; do not relabel an old archive. Candidate validation remains a release gate.

Source users still pull and rebuild locally for their own customizations. Dev
9999/-dev bundles opt out of packaged updates so a binary cannot overwrite their
modified app. Older Whytap installs using the retired update host need a manual installation.
Exodia GitHub URLs redirect to the renamed repository; preserve releases and
archive names already published.

GitHub Actions is disabled to avoid hosted-runner costs; do not enable or dispatch
it. Run appropriate local build/tests and record the results in the PR. BYOK
presentation and local validation remain required:
`.project-docs/decisions/2026-09-10-byok-and-local-builds.md`.

Details and the fork checklist: `docs/build-and-release.md`.

## Documentation

Everything lives in the repository: `CLAUDE.md` (architecture, commands,
invariants), `README.md` (user-facing), `docs/SPEC.md` (product spec),
`docs/hotkey.md`, `docs/privacy.md`, `docs/build-and-release.md`,
`docs/customization/` (coding harness workflow and capability contracts),
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
`HotkeyTapCombo` uses uppercase US English physical-key labels regardless of
input layout, including live recording and previously saved non-English titles.

## Invariants

1. **No Whytap-owned services.** The app never contacts a Whytap backend,
   has no account and sends no telemetry. Network traffic is limited to
   the meeting detector's Silero VAD download from Hugging Face, providers
   and monitoring sources the user configured (including their credential store),
   notification sources accessed by user-configured local scripts, calendar providers
   explicitly connected by the user (Google, Microsoft and Zoom), direct agent provider
   traffic, public OpenRouter model-author artwork (without keys or user content),
   optional Tavily search queries/usage checks and requested tool destinations, the model catalogs and free key checks of providers the user added
   a key for, OpenRouter's provider list (latency, throughput) for a model
   selected on an OpenRouter route, synthetic model probes (silence or a one-word prompt, never user
   audio or text) sent only to that provider when a model is picked or on
   Check now, its official OpenCode native package downloads from the npm registry, `google.com` opened in the
   browser, the Sparkle feed on GitHub Releases, and optional encrypted backups
   to the user's own GitHub repository or selected sync folder.
   `Tests/SidekeyTests/CloudRemovalTests.swift` fails the build on any
   Whytap hostname or removed cloud symbol under `Sources/`.
2. **Keys and content never leave through logs.** Active BYOK keys live in
   the Keychain (`BuildConfig.keychainService`). Optional recovery archives
   include them only inside locally authenticated encryption under an
   independently saved recovery credential. `os_log` never receives
   transcripts, prompts, replies or keys (`LocalPathLoggingInvariantTests`).
   Key contents read by the hotkey tap or the Brightness keys tap are never
   logged or persisted.
3. **No on-device models and no silent route change.** Speech, cleanup and
   meeting processing run only on providers or endpoints the user chose. A
   stored retired `local` level, or no stored level on Apple Silicon (where
   Local was the default), reads as not configured even when a key is stored;
   Intel keeps its Your key default (`SelfKeyPreferences`,
   `RetiredLocalRouteTests`). Each feature's data, including its fallback and
   probe, goes only to the provider of its own route in Settings -> API &
   Models; a removed key leaves the feature Not set and moves nothing. WHY:
   .project-docs/decisions/2026-10-19-api-and-models.md FluidAudio stays only for the meeting detector's
   Silero VAD; launch removes the retired models' weights under
   Application Support/Sidekey once per flavor and never touches FluidAudio's
   cache (`LegacyLocalModelCleanup`, WHY:
   .project-docs/decisions/2026-10-18-legacy-model-cleanup.md). There is no
   paid gate anywhere.
4. **Sparkle never shows a window.** Scheduled checks only show the island
   pill; nothing downloads before the user clicks. Requested downloads may
   install and relaunch while idle. Active meeting recording, dictation or
   agent work or translation defers app-initiated relaunch; becoming idle alone does not restart
   it. Ready-stage "Later" cancels the current installation via .skip. A prepared
   download may apply on ordinary user-initiated app quit unless cancelled.
   Do not promise installation after arbitrary process termination. No manual
   "Check for Updates" menu or status bar item.
5. **Drop is remappable but hold Space by default.** Record a combo or bare
   Space in Settings -> Hotkeys (Raycast-style release-to-commit recorder).
   Space is hold-only; combos support hold or toggle; hold Drop goes through
   the generalised `SpaceHoldMonitor` (swallows the typed character, Escape
   cancels), tap/toggle Drop through Carbon, modifier Drop through
   `ModifierOnlyHotkeyMonitor`. One physical key = one action, except the
   right modifiers' tap/hold split (Right Command = agent text / voice).
   Every HoverTool can have an optional named shortcut in Settings -> Hotkeys ->
   Tools, including unpinned tools. `toolShortcuts` binds stable tool IDs, so
   reordering/removing tiles never reassigns keys. New installs reserve no digit
   shortcuts; explicitly saved old slot keys migrate once to their current tools.
   Hints and Help read the same config; clearing/reset persists an empty map.
   WHY: docs/decisions/2026-10-19-feature-hotkeys.md
6. **Case authorizes secret use at the broker boundary.** Only the bundled
   helper receives values for an authorized child command's environment.
   Never put values in argv, MCP responses, client configuration, repository
   files or app logs. Output masking is best effort, not a guarantee against
   deliberate extraction by an approved command. Revalidate current caller
   authority after approval/authentication before granting or releasing
   values. WHY: docs/decisions/2026-10-19-case-secrets-broker.md
7. **whytap:// links show, or propose an allowlisted change.** Any web page
   can open a link, so a link never records, captures, toggles, copies,
   pastes, authenticates (no Touch ID: Case links stop at Toolbox) or quits,
   and reports nothing back. Every `WhytapLinkDestination` is classified
   show-only in `WhytapLinkTests`; the handler is source-checked for action
   calls. A change is a `WhytapLinkChange` case, applied only after the
   user's Assign in `WhytapLinkConfirmation` (Cancel default, Assign armed
   after 1 s) through the same validated path as Settings. Today only tool
   hotkeys with ⌃ or ⌥ (not Quit). Never allow a change that reads or
   exports data (keys, Case, meetings, clipboard, backups) or changes where
   data goes (provider routes/endpoints, notification scripts, Monitor,
   backup destination). WHY: .project-docs/decisions/2026-10-20-whytap-links.md,
   .project-docs/decisions/2026-10-21-whytap-link-hotkeys.md
