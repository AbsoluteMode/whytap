# Privacy

Whytap has no accounts, no Whytap-operated servers and no telemetry. This
document lists every way data can leave the Mac, so that "no Whytap servers"
is a verifiable claim rather than a slogan.

## What stays on the device

- Audio captured for dictation (Drop) and for meetings is processed in memory
  and, for meetings, staged as WAV chunks under `~/Library/Application
  Support/` only while the meeting is recorded and its note is created. If
  processing fails, the recording is kept for retries for at most 24 hours
  after it ended and then deleted; the meeting stays listed as failed.
  Packaged builds keep no research recordings.
- Transcripts, agent history, clipboard history and meeting notes live in
  SQLite databases under `~/Library/Application Support/`. Delete them from
  Settings, History, or by removing the files.
  Clipboard keeps up to 50 recent text, image and file-path entries across
  restarts, with image attachments stored beside the database. New copies
  evict the oldest excess entries and their images. It does not import the
  existing pasteboard payload on launch. Copies that the source app marks
  concealed, transient or auto-generated (password managers, text expanders,
  Whytap's recovery code) are never recorded.
  History → Clipboard displays the latest 20 retained copies with scrolling.
  To remove one entry, right-click it in History and choose Delete…; only a
  click on Delete in the confirmation removes it. Its saved image goes with it; for a copied file list
  only the entry is removed, never the files. SQLite overwrites the deleted
  row and folds its write-ahead log back into the database, so the copy is
  not left readable in those files. Deleting does not change encrypted
  backups already uploaded: archives made before 2026-10-21 contain the
  History database, and restoring one brings its entries back. Time Machine
  and other copies of your disk are not changed either.
  Every removal from the History database also overwrites the removed bytes:
  copies pushed out by the 50-entry limit, older dictations and agent chats,
  and Delete…. Earlier versions removed entries without overwriting them, so
  pieces of old copies could stay readable in the database's unused space.
  Whytap therefore rewrites each History database once (SQLite `VACUUM`),
  in the background after launch. Every entry is kept. When the disk lacks
  room for its temporary copy (about twice the size of the kept entries), it
  waits for a later launch. This cleans the files themselves; it is not a
  forensic wipe of the SSD, snapshots or backups.
- API keys you enter in Settings → API & Models ("Your key") are stored in the
  macOS Keychain under the app's own service name (`com.rootwise.sidekey`).
  Key values are never shown again after saving and are never written to
  UserDefaults, plaintext files or logs. UserDefaults holds only which provider
  and model each feature uses, plus the names and addresses of your own servers.
  Encrypted local history and optional recovery archives can also contain the
  Soniox, Deepgram, ElevenLabs, OpenRouter and legacy custom-endpoint keys,
  protected by the independent backup key. No plaintext key export file is created.
- Cached model catalogs (a file in the app's Caches folder) and the results of
  key and model checks (provider, model, status, time; never a key, audio or
  text) stay on the Mac.
- Smart selects a formatting profile locally from the target application and
  focused Accessibility field/document metadata. Document URLs used for that
  selection are not separately attached to model requests or logged. The
  existing bounded screen-context envelope can still contain visible URLs.
  Rich clipboard conversion for recognized chat apps runs on the Mac, using
  the same clipboard suppression and restore as ordinary dictation.
- Logs go to the unified system log (`os_log`, subsystem
  `com.rootwise.sidekey`). They never contain transcripts, prompts, replies
  or keys; `Tests/SidekeyTests/LLM/LocalPathLoggingInvariantTests.swift`
  enforces that for the provider paths that carry this content.
- Planner tasks and local Whytap events stay in a private atomic JSON archive
  under Application Support/Sidekey/Planner. External calendar events are held
  in memory while using the unified calendar, without a persistent event cache.
  Calendar account credentials are stored in Keychain and are not logged.
  Public native OAuth client configuration can be bundled for normal sign-in.
  Planner content, calendar settings and saved account credentials are included
  inside encrypted backups; external events are fetched again after recovery.

The Projects feature has been removed. The app does not open the old project
catalog or index, scan registered folders, or attach saved project notes and
source excerpts to agent requests. Existing project-library files and separate
project-agent workspaces are left on disk, unused; they are not migrated into
the regular agent workspace.

Monitor dashboard snapshots and server connection references also stay locally.
The app runs a fixed read-only Linux metrics collector through SSH; dashboards
cannot embed commands or executable HTML. UT/Sferyx configuration belongs to
the user’s local files and is absent from the source repository.

The Display tool reads and sets the display backlight through macOS DisplayServices
while its hover strip is open (each Brightness keys press opens it), and reads the
level once when hover opens with Display pinned and when Settings -> Toolbox ->
Display appears. While Extra is on, it also reads the selected display's level
every half second with the strip closed, so any decrease turns Extra off.
The tool does not read battery charge or load and keeps no battery history.
While Extra is on, it scales the display's
transfer table through Quartz; macOS gives the display its own table back when
Whytap quits, crashes included. Only the Brightness keys switch is saved. The
tool requests no macOS permissions; Brightness keys use Accessibility (below).

Notify stores notification history (up to 500 events), including text, links,
colors and logo names, locally under Application Support. User-configured scripts
can access the external sources required by their integration with the user's
authorized credentials. They run with ordinary user permissions while the app is
open and stop on quit; Whytap does not send notification content to a model or an
Whytap server. Script output is not logged and stderr is discarded. History and
source controls are in Notify. [Script contract](customization/notifications.md).

## What can leave the device, and only when you choose it

| Route | Where data goes | When |
|---|---|---|
| Meeting detector (FluidAudio Silero VAD) | nowhere; a one-time download from Hugging Face fetches the model | the first time the detector checks for speech |
| Your key: speech (Soniox, Deepgram, ElevenLabs, or a self-hosted endpoint speaking the OpenAI Realtime protocol) and text (OpenRouter, OpenAI, Anthropic or a custom OpenAI-compatible endpoint) | the provider or endpoint chosen for that feature in API & Models, with your key (a custom endpoint may need none). Each feature's data goes only to its own provider, including its recovery path; nothing moves to another provider | while the feature's route is in use |
| Agent (native) | the provider chosen for the Agent row (OpenRouter, OpenAI or Anthropic) and its selected model, using your API key; tool actions may access destinations needed by your request | when you submit an agent request |
| Agent model mark | public image files on OpenRouter for the displayed model author; no API key, cookies, audio, prompt or reply. Bundled marks appear immediately; a small local cache is disposable | asynchronously when the voice mark is shown, at most weekly per cached author; failures retain usable artwork |
| Key checks | the provider of the key: a free request (model list, key or account endpoint) that sends only the key. A restricted ElevenLabs key may need a minimal paid speech request, made only when you save the key or press Check now | when you save a key, press Check now, or open API & Models and the last result is a day old |
| Model catalogs | the public model lists of OpenRouter and Deepgram (no key), and the model lists of Soniox and Anthropic (your key); a custom server's `/models` list. Only the request itself is sent, no audio or text | when you open API & Models and the cache is a day old, save a key, or press Refresh models |
| OpenRouter providers | OpenRouter, with your key: the list of providers serving the model selected for an OpenRouter feature, with their latency and throughput. Only the request itself is sent, no audio or text. A pinned provider then receives that feature's requests alone, with no fallback | when an OpenRouter row is shown in API & Models (reused for 5 minutes) |
| Model probes | the provider of the feature you are choosing a model for: 1 second of digital silence for speech models, the prompt "Reply with OK." (plus one fictitious tool for agent models) for text models. Never your audio, transcripts, prompts or notes. Costs a fraction of a cent | only when you pick a model that is not in the built-in list, or press Check now |
| Encrypted backup | your private GitHub repository or the folder/sync service you selected; only authenticated ciphertext leaves Whytap | after you explicitly configure and enable Backup |
| Connected calendars | the Google, Microsoft or Zoom account provider you explicitly connect; OAuth authorization and event queries for the displayed date range | sign-in in your browser, then while the calendar view is visible or refreshing; local tasks/events are not uploaded |
| Tavily search | the tool’s search query goes to Tavily; returned excerpts and URLs go to the selected agent model | only when the agent calls web_search; a free /usage check runs when saving the Tavily key |
| Monitor | the SSH targets configured locally by the user; optionally Doppler to resolve credential references | while Monitor is open; custom collectors run separately under the user’s control |
| Google search hotkey | a `google.com/search` URL opened in your browser | when you press Right Option |
| Sparkle updates | GitHub Releases (`appcast.xml` and the DMG) | hourly check, download only on your click |

OpenAI itself is not offered for speech. An older saved OpenAI choice reads as
Soniox and sends audio there only with a Soniox key you stored; without one,
dictation opens Settings → API & Models instead of recording.

Each provider has its own data-use terms; check them before pasting a key.
Data-use policies depend on the selected provider and its account settings.

## Permissions

- Accessibility: global hotkeys (hold Space, Right Command), detecting an
  editable text field before recording and, only when Brightness keys is
  switched on in Settings → Toolbox → Display, the Mac's brightness keys.
- Microphone: dictation and meetings.
- System Audio Recording: the other side of a call, only while a meeting is
  being recorded. The audio tap is created at recording start and torn down
  at stop.
- Post Event (part of Accessibility on current macOS): the synthetic
  Command-V used to paste.
- Calendars: only after choosing Apple Calendar in Planner's Connect account.
  macOS requires full event access to read selected system calendars; Whytap's
  current native calendar adapter only reads events. Direct Google, Microsoft
  and Zoom connections use their provider's OAuth consent instead.

The hold-Space detector reads keyboard events only to recognise the trigger
key and Escape. The Brightness keys tap receives only system-defined events,
such as the brightness, volume and media keys, and acts only on the
brightness keys. Key contents are never logged or stored.

## Case and AI assistants

Case adds no network traffic. AI clients you register talk to Whytap through a
local Unix socket in Application Support (owner-only); only the bundled
`whytap` helper, verified by its code hash, is served. An AI sees project names,
key names and your descriptions, never values: `whytap case run` puts values
only in the environment of the command it starts and masks them in its output.
Values never appear in command arguments, MCP responses, client config files or
logs. Masking is best effort: an AI that deliberately transforms a value can
still read it, so register only assistants you trust. Approve mode asks you
before each run; Bypass does not.

## Encrypted recovery copies

Backup is optional. Whytap encrypts the portable workspace before copying or
uploading it, including provider keys and independently recoverable Case data.
The recovery code is saved once outside Whytap; a local Keychain copy allows
routine backups without repeatedly requesting it. GitHub authentication is not
the decryption key. The code is excluded from Whytap's clipboard history when
copied through its recovery-code button, marked private for other clipboard
applications, and cleared after two minutes if the clipboard has not changed.
Other applications decide how they handle private clipboard markers.

Restore verifies a whole archive before applying selected groups on the next
normal launch. Imported jobs and executable configurations do not run on their
own. External clipboard file originals, SSH keys and credentials managed by
other applications are not silently copied. [Coverage and recovery](backup.md).

## Translation and subtitles

Translate sends submitted text to the chosen Translation LLM route. Subtitles
sends system audio to the chosen Subtitles audio speech provider and committed
phrases to the Translation route. It never opens the microphone or creates a
recording/meeting note. Forty recent lines stay in memory, with no automatic
history saved. Copy writes translations only after a click. Window close,
Cancel and sleep stop capture and cancel requests. See [translation](translation.md).

## Screenshots

Screenshot capture is explicit. Screen Recording access can be requested from
the Screenshot tool or its Allow button in Settings → Permissions; refreshing
the displayed status never requests access. Screenshot capture requests permission
on invocation. Captures and edit history remain in memory until the user
copies, saves, pins or chooses a system share destination. Text-and-number
blur and Copy text use on-device Vision; no provider receives the screenshot.
Exports contain flattened edited pixels. Clipboard copies may enter ordinary
clipboard history. OCR and blur do not guarantee irreversible anonymization;
check the visible result. See [screenshots](screenshots.md).

The built-in agent has a requested screen tool. The signed Whytap app captures
one display under its Screen Recording permission and sends the bounded JPEG
to the selected model in the current tool loop. Capture creates no file or
clipboard copy, and the native conversation file stores no pixels, tool output
or provider reasoning. Providers may retain supplied content under their own
policies. OpenAI agent requests explicitly use `store: false`.

The dedicated `Application Support/whytap/agent` folder retains AGENTS.md memory,
session IDs and at most six completed text pairs (12,000 characters) in
`native-conversation.json`. Context older than 15 minutes is not reused; the file
is replaced after a successful later turn, rather than deleted by a timer.
Old OpenCode runtime/history files remain on disk unused and can contain earlier
content, including screenshots; the migration does not erase them. Tavily’s key
uses a separate Keychain item, included in the existing encrypted provider-key
backup contract. Only tool search queries are sent to Tavily, never the whole
conversation, selection or screenshot automatically.
