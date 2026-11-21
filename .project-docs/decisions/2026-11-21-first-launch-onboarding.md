---
id: whytap-first-launch-onboarding
type: decision
title: A short onboarding on a new Mac, up to the first dictation
summary: The first launch on a Mac opens four short pages (speech, two permissions, try Drop, Google/Meetings/Agent) instead of Settings -> Permissions; each page that is already done is hidden, every page can be skipped, the On this Mac button sets Drop only, Screen Recording and the other permissions are asked at first use, and updated Macs never see it.
status: confirmed
tags: [onboarding, first-launch, permissions, drop, on-device, screen-recording, automation]
canonical_for: [first-launch-onboarding, first-launch-permission-setup]
verified_at: 2026-11-21
sources:
  - type: user-confirmed
    reference: On 2026-11-21 the maintainer asked to bring back a first-launch onboarding (the old one was badly outdated), without filler, clean and good-looking. A council (Fable 5.2, Astra 6.2) read origin/main and proposed pages; the maintainer chose a separate permissions page hidden when access exists, a short skippable fourth page with Google/Meetings/Agent and videos, an On this Mac button that sets Drop only and says so, Screen Recording removed from the first launch, the onboarding replacing the first-launch Permissions screen, no onboarding for updated Macs and no synced flags. Calendar is not offered.
    confirmed_at: 2026-11-21
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
    reference: Tests/SidekeyTests/OnboardingTests.swift
    confirmed_at: 2026-11-21
related: [../project.md, 2026-10-26-first-launch-permissions.md, 2026-11-19-permission-request-before-settings.md, 2026-11-19-on-device-dictation.md, 2026-11-18-drop-into-whytap-editors.md, 2026-10-17-local-workspace.md, 2026-11-20-other-feature-videos.md, 2026-11-20-settings-sync.md, 2026-11-20-input-language-suggestion.md]
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
four pages, in this order:

1. **Speech.** Apple Silicon: an On this Mac card (Parakeet v3, about 470 MB,
   no account) whose button reads "Download and use for Drop" and says that it
   sets the speech model of Drop only. The download starts on the click and
   continues while the next pages show. When it lands, `OnboardingDropSpeech`
   assigns On this Mac to Drop Fast and Drop Smart rows that cannot run; a row
   that already works keeps its choice, and no other feature changes. Links:
   "I have an API key" (Soniox, Deepgram or ElevenLabs; saving the key sets
   that provider's recommended live model for Drop, an already saved key is
   used with one button; the no-card offers of API hints are listed) and
   "Restore from another Mac" (Settings -> Backup). Intel starts on the key
   form. Hidden when Drop's speech route already runs.
2. **Two permissions.** Microphone and Keyboard control only, on
   `PermissionsSettingsViewModel`: the first Allow asks macOS, the next press
   opens its pane. The page is done when `dropHotkeyStatus == .ready`, not when
   both checks are green; with both granted and no shortcut it shows
   `DropShortcutStatusSection` (Retry, Hotkeys, Input Monitoring). It polls for
   at most two minutes and rereads on activation. Hidden when access is given
   and the shortcut is installed.
3. **Hold Space and speak.** The user's own Drop shortcut and gesture, a native
   text field that has the keyboard, and the real island. "That's Drop" appears
   only when Drop reports an insertion into this field
   (`sidekeyDropInsertedIntoLocalEditor`, sent by `DropLocalEditor` with the
   editor, never the text), not for typing. While the model downloads the page
   shows its progress; a press before Drop can run says so on the page instead
   of opening Settings over it, and a press with a permission missing returns
   to the permissions page instead of a second repair window.
4. **More on the same keyboard.** Google search, Meeting Notes and Agent, each
   with its video and its switch. Meeting Notes needs a running speech and
   notes model, Agent its model; otherwise the row offers "Add a model", which
   opens API & Models on that row. Done closes the window. Calendar is not
   offered.

Every page can be skipped. Set up later on the speech page also passes over the
try page when nothing is on its way to dictate with. Closing the window counts
as Done.

Permissions asked at first use, not at launch: Screen Recording (the first
screenshot or Agent screen capture), System Audio Recording (the first meeting
or Subtitles), Input Monitoring (only when the hold tap could not be created),
Automation (Now Playing) and Calendar.

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
- Screen Recording can make macOS ask to reopen Whytap. In the middle of a
  first launch that cut the onboarding; at the first screenshot it costs
  nothing.
- Updated users already know Whytap; showing them a tour after an update was
  the old onboarding's failure. Per-Mac markers keep a restored or synced
  second Mac's own setup honest.

# What was tested

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

2026-11-21 · supersedes the first-launch presentation of
`2026-10-26-first-launch-permissions.md`.
