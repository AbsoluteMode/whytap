---
id: whytap-first-launch-onboarding
type: decision
title: A short onboarding on a new Mac, up to the first dictation
summary: The first launch on a Mac opens up to five short pages in the former paid onboarding's dark two-pane look (speech with language and every provider's key and offer, permissions with optional Screen Recording, try Drop, shortcuts and hover tools, Google/Meetings/Agent and coding agents) instead of Settings -> Permissions; done pages are hidden, every page can be skipped and every page but the first has Back, the On this Mac button sets Drop only, and updated Macs never see it.
status: confirmed
tags: [onboarding, first-launch, permissions, drop, on-device, screen-recording, automation]
canonical_for: [first-launch-onboarding, first-launch-permission-setup]
verified_at: 2026-11-22
sources:
  - type: user-confirmed
    reference: On 2026-11-21 the maintainer asked to bring back a first-launch onboarding (the old one was badly outdated), without filler, clean and good-looking. A council (Fable 5.2, Astra 6.2) read origin/main and proposed pages; the maintainer chose a separate permissions page hidden when access exists, a short skippable fourth page with Google/Meetings/Agent and videos, an On this Mac button that sets Drop only and says so, Screen Recording removed from the first launch, the onboarding replacing the first-launch Permissions screen, no onboarding for updated Macs and no synced flags. Calendar is not offered.
    confirmed_at: 2026-11-21
  - type: user-confirmed
    reference: On 2026-11-21 the maintainer called the first build's screens ugly and asked to rebuild it on the former paid onboarding (removed in 2cc4caa7), beautiful, simple and making an impression. Reviewing offscreen renders on 2026-11-21 and 2026-11-22 he asked for one speech page with the download, every provider's key with its offer and a searchable language, a page showing tool shortcuts and hover editing with two clips, much less text on the left, the coding-agent plugin inside an existing page, Screen Recording as optional for Shot, and one muted colour for the tile badges; then approved it ("the onboarding is fine").
    confirmed_at: 2026-11-22
  - type: user-confirmed
    reference: Trying build 1700 with clean data on 2026-11-22, the maintainer found no way back from Customize and approved adding Back.
    confirmed_at: 2026-11-22
  - type: user-confirmed
    reference: Trying build 1701 with Whytap's data cleared and keys left in the Keychain on 2026-11-22, the maintainer saw every tile marked Saved but no Continue and asked to merge Continue with Set up later; the orchestrator relayed one footer place, saved speech keys as a choice with a preselection rule, the free key check before use and footer renders.
    confirmed_at: 2026-11-22
  - type: repository
    reference: Sources/Sidekey/Onboarding/OnboardingFlow.swift
    confirmed_at: 2026-11-21
  - type: repository
    reference: Sources/Sidekey/Onboarding/OnboardingModel.swift
    confirmed_at: 2026-11-21
  - type: repository
    reference: Sources/Sidekey/Onboarding/OnboardingSetup.swift
    confirmed_at: 2026-11-21
  - type: repository
    reference: Sources/Sidekey/Onboarding/OnboardingTheme.swift
    confirmed_at: 2026-11-22
  - type: repository
    reference: Sources/Sidekey/Onboarding/OnboardingCodingTools.swift
    confirmed_at: 2026-11-22
  - type: repository
    reference: Sources/Sidekey/Onboarding/OnboardingBackKey.swift
    confirmed_at: 2026-11-22
  - type: repository
    reference: Tests/SidekeyTests/OnboardingTests.swift
    confirmed_at: 2026-11-21
related: [../project.md, 2026-10-26-first-launch-permissions.md, 2026-11-19-permission-request-before-settings.md, 2026-11-19-on-device-dictation.md, 2026-11-18-drop-into-whytap-editors.md, 2026-10-17-local-workspace.md, 2026-11-20-other-feature-videos.md, 2026-11-20-settings-sync.md, 2026-11-20-input-language-suggestion.md, 2026-11-22-shot-single-permission-prompt.md, 2026-11-22-onboarding-journey.md]
---

# Context

Whytap had no onboarding since 2026-10-17: the first launch on a Mac only
opened Settings -> Permissions when something was missing. On a clean Mac that
left a person without a speech model (the first Drop opened API & Models), and
without Keyboard control hold-Space never installed, so pressing it did nothing
at all and no repair window could appear. The old onboarding could not come
back as it was: its models screen used APIs that no longer exist, it spoke and
demoed instead of letting the person dictate, and its permission layer asked
macOS and opened System Settings in one click, the pattern removed on
2026-11-19.

# Decision

The first GUI launch on a Mac opens one window beside the island with up to
five pages, in this order. The window is always dark, 960 × 600 pt, in the
former paid onboarding's look: a 380 pt left pane with a step caption, an
Instrument Serif headline with one italic word, at most one short line and the
page's controls; a stage on the right with a soft purple wash that shows what
the page is about.

1. **Speech.** "I speak" sets the dictation language (the Input Lang setting,
   Auto by default) from a searchable list: typing filters by English or
   native name, arrows move, Return picks. Apple Silicon: an On this Mac card
   (Parakeet v3, about 470 MB, free and offline) whose button reads "Download
   and use for Drop". The download starts on the click and continues while
   the next pages show. When it lands, `OnboardingDropSpeech` assigns On this
   Mac to Drop Fast and Drop Smart rows that cannot run; a row that already
   works keeps its choice, and no other feature changes. Under it, "Or use
   your keys": one tile per provider Whytap takes a key for (Soniox, Deepgram,
   ElevenLabs, OpenRouter, OpenAI, Anthropic, Tavily) with a muted
   Speech/AI/Search badge and its offer from API hints (green when free;
   "Plan credit" for subscription credit; nothing invented where API hints
   list none). A click opens that provider's key field, saved through the same
   path as Settings -> API keys, and "Get offer". A speech key also sets that
   provider's recommended live model for Drop; other keys are only saved.
   "Restore from another Mac" opens Settings -> Backup. The stage plays a
   scripted, silent Drop with the real island orb. Hidden when Drop's speech
   route already runs.
2. **Permissions.** Microphone and Keyboard control on
   `PermissionsSettingsViewModel`: the first Allow asks macOS, the next press
   opens its pane. The page is done when `dropHotkeyStatus == .ready`, not when
   both checks are green; with both granted and no shortcut it shows
   `DropShortcutStatusSection`. A third, visually secondary row offers Screen
   Recording as optional, for Shot: `ScreenRecordingAccess.requestOnce()`, the
   launch's one ScreenCaptureKit request shared with Shot (never
   `CGRequestScreenCaptureAccess`); nothing of ours is shown beside macOS's
   dialog, the next press opens System Settings, and it never holds Continue. It polls for at most
   two minutes and rereads on activation. Hidden when access is given and the
   shortcut is installed.
3. **Try Drop.** The one page with numbered steps (Click, Hold, Let go): the
   user's own Drop shortcut and gesture, a native text field that has the
   keyboard, and the real island. "That's Drop" appears only when Drop reports
   an insertion into this field (`sidekeyDropInsertedIntoLocalEditor`), not
   for typing. While the model downloads the page shows its progress. A press
   before Drop can run says so on the page; a press with a permission missing
   returns to the permissions page.
4. **Make it yours.** Shortcuts (any tool on its own keys) and Hover tools
   (what the island shows), each with a bundled clip on the stage and Open for
   Settings -> Hotkeys or Toolbox.
5. **Turn on more.** Google search, Meeting Notes and Agent, each with its clip
   and switch, or "Add a model" when its model does not run. When Claude Code
   or Codex is installed, a Coding agents row connects them to Whytap with the
   same client setup as Case -> Connect (`CaseClientSetup.connect`: the
   `whytap` command and the agent's one `whytap` MCP entry, `<helper> mcp`,
   which retires the older Case-only `case` entry), without a Case
   registration.
   Done closes the window. Calendar is not offered.

Every page can be skipped. Set up later on the speech page also passes over the
try page when nothing is on its way to dictate with. Closing the window counts
as Done.

The speech page's footer has one place on the right: Continue when Drop has a
way to run, else the quiet Set up later. A way to run is a saved speech key
(Soniox, Deepgram, ElevenLabs: the providers Drop runs on; OpenAI is not one)
that the provider has not refused, or the downloaded On this Mac model. Saved
keys are a choice, not only a status: one is preselected (the provider Drop
already runs on, else Soniox, Deepgram, ElevenLabs in that order, Soniox being
Whytap's default, else On this Mac), its tile says For Drop with the accent
outline, a tap on another saved speech tile picks it, and the line above
Continue says "Drop will use ElevenLabs". Continue on a provider Drop does not
run on yet first runs Settings' free key check (`checkSavedKey`, no paid
probe); a refusal stays on the page with the provider's reason in that line and
the tile reads Key refused, and the next saved key, if any, takes its place.
Then both Drop rows get the choice (`OnboardingDropSpeech.choose`; a row
already on that account keeps its model) and the page moves on. Saving a speech
key on the page and Use for Drop on a downloaded model are the same choice.
AI and search keys alone keep Set up later.

The latest speech action wins. Picking a tile, Continue, saving a speech key
and the download each take a new number (`OnboardingModel.speechAction`); a
key check or a save that answers after a newer action changes neither Drop's
route nor the page, and a newer action frees Continue from the check it
replaced at once. A save that lands late still keeps its key, so the tile
reads Saved. A key check counts only for the key it checked: when the key is
replaced in Settings while the request runs, `checkSavedKey` checks the new
key again instead of marking it with the old key's refusal or success. Key
tiles are whole-tile controls with hover, press and keyboard-focus feedback,
and look unavailable while a key is being saved.

Every page but the first has a quiet Back on the left of its footer; ← and ⌘[
(physical keys) do the same while no text field has the keyboard, where the
arrow moves the caret (`OnboardingBackKey`, a local key monitor of the
window). Back walks the same page list as Continue (`OnboardingFlow.previous`):
hidden pages are never reached and the try page is passed over by the same
rule, so the "N / M" caption stays right. Only the page changes: the language,
saved keys (tiles still say Saved), the On this Mac download, the try page's
success, the chosen clip and connected coding agents stay, and the speech page
offers Continue instead of Set up later once Drop's speech route runs.
Permissions already completed do not advance the page again. Doing a step
again is safe: a saved key is chosen again and only the speech page moves on.

Permissions asked at first use, not at launch: Screen Recording when the person
skips it (the first screenshot or Agent screen capture), System Audio Recording
(the first meeting or Subtitles), Input Monitoring (only when the hold tap could
not be created), Automation (Now Playing) and Calendar.

Launch rules (`OnboardingLaunch`): the existing
`sidekey.permissions.firstLaunchPresented.v1` marker, written by every launch
since 2026-10-26, means the Mac ran Whytap before, and such a Mac (also one
with the former onboarding's completion key) never sees the onboarding. A new
Mac gets the marker and `sidekey.onboarding.pending.v1`; the pending marker is
removed by Done or closing the window, so a quit in between shows it again.
Neither key is in `ConfigBackupRegistry`, so no backup or settings sync carries
them. The app stays an accessory; the window does not add a Dock icon.

Two runtime fixes ship with it:

- The first Drop press on a Mac whose microphone was never asked asks it and
  records nothing (`DropHotkeyRecovery.startGate`). Before, the system dialog
  opened while the person was already speaking and ate the first take.
- While the onboarding is visible, Now Playing's AppleScript fallback does not
  raise its Automation dialog over it; the undecided prompt waits for a later
  poll after the window closes (`NowPlayingAutomationConsent.promptsDeferred`).

# Why

- The person's first success is their own sentence in a real field, without a
  key or an account. On this Mac makes that possible on Apple Silicon; the
  only wait is the download, so it starts on the first click and runs beside
  the permissions page.
- The download alone does not make Drop work: without a route the first press
  opens Settings. A button that names Drop and assigns only Drop keeps the
  rule that a route changes only by the user's choice
  (`2026-11-19-on-device-dictation.md`); other features are offered in API &
  Models as before.
- Green checks are not readiness: a restored shortcut can be taken or the tap
  can fail. Waiting for the installed shortcut is the same rule Settings and
  the repair window use.
- Screen Recording is offered, not required: the maintainer wants Shot ready
  from the start, but macOS can ask to reopen Whytap after it, so it never
  blocks the way to the first dictation.
- The look is the former paid onboarding's because it was the polished one:
  the first contact should impress. Text stays short; the stage shows what a
  sentence would explain.
- Every key and offer in one place answers "what do I need and what is free"
  on the first screen, and the offers come from API hints so the two never
  disagree.
- Updated users already know Whytap; showing them a tour after an update was
  the old onboarding's failure. Per-Mac markers keep a restored or synced
  second Mac's own setup honest.

# What was tested

2026-11-22 speech footer: scenario tests for no keys (Set up later as
before), one saved speech key (Continue sets both Drop rows), several (Soniox
preselected, a tile changes it, the running provider preferred and replaced by
a pick), only AI keys (no Continue), a key the check refuses (stays with the
reason, no route, then no longer offered), a refusal falling back to the next
key and the downloaded model as a choice; offscreen renders of Continue with
every key saved, a picked tile, a refusal and Set up later.

2026-11-22 overlapping actions (the build queue's review of PR #397): an
earlier Continue whose check finishes first sets nothing and does not move
the page while a later Continue is checking, which then wins; a key replaced
during its check is checked again, so neither the old refusal nor the old
success counts for the new key; a save that finishes after Continue keeps its
key and leaves Continue's route and page; a save started during a Continue
check makes Continue available again at once. An independent review of the
fix found that last case, which was then fixed.

2026-11-22 Back: scenario tests walk Back from every page to the first (which
has none) with the counter following, with the speech and permissions pages
hidden, after Set up later skipped the try page, keeping every page's result,
staying on completed permissions, and ← / ⌘[ only outside text fields. The
footer was checked in offscreen renders; the key monitor in the live window is
acceptance in the installed app.

2026-11-22 redesign: scenario tests for the five pages, the searchable
language list (English, native and accented names), the key tiles taking
every API hints offer and inventing none, Screen Recording asked once and not
holding Continue, coding agents connecting through the Case client setup and
reporting failures, and both onboarding clips bundled. Offscreen renders of
every page in the real window were reviewed by the maintainer; the language
list renders on its own because a popover is not drawn offscreen. Clips show
their first frame offscreen.

Scenario tests in `OnboardingTests` with temporary defaults, in-memory keys, a
fake model store and fake permissions: clean Mac (all four pages, opens once,
returns after a quit), updated Mac (never; also the former onboarding key),
access already given (no permissions page), Drop already set up (no speech
page), Intel (key form first), every page skipped to Done, Set up later passing
over the try page, a shortcut that did not install (permissions page stays,
Continue off until `.ready`, then the page advances), the download assigning
Drop Fast and Drop Smart only and only after the model exists, a working Drop
row kept, a saved key used for Drop, a Drop press with a missing permission,
the try field confirming only Drop's insertion and not typing, feature rows
offering a model, the microphone start gate, and the deferred Automation
prompt. Offscreen renders of every page in light and dark appearance were
reviewed (`WHYTAP_ONBOARDING_RENDER_DIR`).

These checks do not prove the native TCC dialogs, the real model download,
hold-Space into the onboarding field with the live island, or the window's
behavior beside System Settings; those are acceptance in the installed app.

# Rejected

- A separate key page behind "I have an API key": the maintainer wanted the
  download, every key and the language visible at once.
- A colour per badge kind: only offers stay coloured.
- Continue beside Set up later on the speech page: two ways forward for one
  question; one place that changes with the state reads at once.
- Continue without a key check: a key left from an earlier install can be
  revoked; the free check costs nothing and names the refusal.
- Back in the title bar or as a bare ‹ arrow: the footer keeps every page's
  actions in one place, and a word reads at once.
- A separate page for the coding-agent plugin: one row on the last page is
  enough.

- Permissions above the try field (two screens instead of three): the
  maintainer chose a separate page that hides itself when access exists.
- Assigning On this Mac to every microphone feature: the button would change
  routes the person did not name.
- Ending at the first dictation without a features page: Agent, Meetings and
  Google are off by default while the island already hints at them.
- Reviving the old permission surface, demo audio, language grid, models
  screen, Agent/Skills/Helpers screens or resume store: outdated or replaced
  by state-derived pages.
- A flag synced between Macs: each Mac needs its own permissions and model.

2026-11-21, redesigned 2026-11-22 · supersedes the first-launch presentation of
`2026-10-26-first-launch-permissions.md`.
