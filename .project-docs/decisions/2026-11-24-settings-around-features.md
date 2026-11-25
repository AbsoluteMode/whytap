---
id: settings-around-features-2026-11-24
type: decision
title: Settings is rebuilt around features; the feature catalog is data with honest statuses
summary: Settings moves from tabs that follow the code (API & Models, Hotkeys, Permissions, Other) to a list of features and one screen per feature. The first step is FeatureCatalog, the list of features as data, each with its name, one phrase, clip, shortcuts, requirements with a readiness check and one action, and a status in words (Ready, Off, Needs setup, Not set up) that never claims more than the app can check.
status: confirmed
tags: [settings, features, onboarding, status, hotkeys, permissions, models]
canonical_for: [settings-feature-catalog, feature-status-words]
verified_at: 2026-11-24
sources:
  - type: user-confirmed
    reference: On 2026-11-24, after the first outside tester of 2.2.27 could not find his way in Settings, the maintainer decided to make features central, "so that people find it as simple as possible to live and find their way in our settings" (translated), with what a feature does and how to connect it on one screen, and asked that a feature's hotkey and its Hold or Toggle be changed on that feature's screen. He accepted the second clickable mockup with "Yes, I like everything about the settings" (translated). ORCH-TASK 97 REV 16, ORCH-TASK 99.
    confirmed_at: 2026-11-24
  - type: repository
    reference: Sources/Sidekey/Settings/Features/FeatureCatalog.swift
    confirmed_at: 2026-11-24
  - type: repository
    reference: Tests/SidekeyTests/Settings/FeatureCatalogTests.swift
    confirmed_at: 2026-11-24
  - type: repository
    reference: Sources/Sidekey/Settings/Features/SettingsFeaturesView.swift
    confirmed_at: 2026-11-24
  - type: repository
    reference: Tests/SidekeyTests/Settings/SettingsFeaturesTests.swift
    confirmed_at: 2026-11-24
  - type: repository
    reference: Sources/Sidekey/Settings/Features/DropFeatureView.swift
    confirmed_at: 2026-11-24
  - type: repository
    reference: Tests/SidekeyTests/Settings/DropFeatureTests.swift
    confirmed_at: 2026-11-24
related: [2026-11-20-other-feature-videos.md, 2026-11-23-keyboard-control-protection-override.md, 2026-11-24-feature-screen-videos.md]
---

## Context

The first outside tester of 2.2.27 opened Settings and closed it: one feature
was spread over four or five tabs, the switches of features lived in a tab
named Other, the first screen showed orange outlines without words on models
of features he did not use, and short names (Agent voice, Voice search,
Translation) said nothing about what they were for. His request: say what a
feature does, show how it works and let him set it up in the same place.

A council of three models read the code and proposed a structure; a clickable
mockup was made, reviewed against the code and corrected. The maintainer
accepted the second version.

## Decision

- Settings gets a Features list and one screen per feature: what it does, its
  clip, its shortcut, what it needs with the action in place, its options.
  The work goes in steps; older tabs stay and work beside the new screens
  until each of their settings has moved.
- The list of features is data: `FeatureCatalog` holds, for each `AppFeature`,
  the name, a plain word for what it is, one phrase, the bundled clip if one
  exists, its shortcuts (`FeatureHotkey`, keys read live from
  `HotkeyConfiguration`), how it is turned on, where its settings are shown
  today, and its requirements.
- A requirement is a model route, a macOS permission, the OpenAI key of
  Subtitles, or Drop's shortcut being delivered. Each has a readiness check
  over `FeatureSetupSnapshot` (plain values, no stores) and at most one action.
- Status is words, not colour:
  - **Ready**: every required step is done. A note narrows it ("typing only"
    for search without a voice model).
  - **Off**: the feature has a switch and it is off. Nothing is asked.
  - **Needs setup**: the feature is on and a required step is missing; the
    list names the first one and how many more.
  - **Not set up**: an island tool (Translate & Subtitles, Screenshots) that
    lacks something. It is quiet, like Off: these have no switch, and a tool
    the person never used is not a problem to report.
- A switch exists in the catalog only where the app has one: Agent, Meeting
  Notes, Google search. Drop always waits for its shortcut.
- The free way comes first: where this Mac can run the on-device speech model
  and the feature can use it, the action of a missing speech model is the
  download (or "Use the model on this Mac" once it is there). On an Intel Mac
  the action is a model of a keyed provider, or a key.
- "Choose a model" is offered only when the picker holds a model that would
  work (`modelAlternatives`: a listed model other than the selected one, or a
  typed name, under a key that is not refused). A refused key with nothing
  else to pick gets "Fix the key"; a removed or unsupported model with
  nothing else gets the free model or "Add a key".
- A sentence about a missing part names only what stops: Fast's model while
  Smart is on stops Fast, the Agent's and search's voice parts stop talking,
  not typing. "Switch to Fast" is offered only when Fast's model works.
- Translate and Subtitles start on their own, so the shared row says which
  one works: Ready "Translate only", Ready "Subtitles only", Ready for both,
  Not set up for neither. System audio never decides it.
- No catalog text names a key (`testNoCatalogTextNamesAKey`), following the
  2026-11-20 rule. Drop's lead paragraph follows the gesture: Hold or press.

- Settings opens on Features, the first sidebar row
  (`SettingsWindowTab.features`, `whytap://settings/features`). The older
  tabs keep their identifiers and their place under it. A row of the list
  opens the feature's own screen or, until it has one, the place its settings
  are shown today (`FeaturePlace`): the Other tab with the Agent group marked,
  or the tool's Toolbox pane. The island's Settings tile opens Features too.
- The list shows no reason under Off and Not set up; VoiceOver still reads it.
- Drop is the first feature with its own screen, top to bottom: what it does
  (following Hold or Toggle), a Needs setup box with the first action, the
  shortcut with Hold or Toggle and Change, "Try it here", "What it needs",
  Settings (Mode, Language you speak, Lower other audio, Stop Drop
  automatically) and Your words (Vocab, Filler).
- A shortcut recorded on the screen is saved at once. One that another action
  uses is not saved, the row says which, and recording stays open.
- Choosing the model on this Mac from the screen assigns it to that one
  feature and opens no Assign window for the others.
- ~~There is no video block until a Drop clip exists: no placeholder is
  drawn.~~ Replaced the same day (step 2, "do all of it"): every feature
  screen keeps the clip's place. A made clip plays in place on click; a clip
  not made yet is a quiet "Video coming" row with what it will show
  (`FeatureInfo.clipCaption`). The clips are made in a separate task.
- Step 2 builds every screen from one template (`FeatureScreen.swift`):
  `FeatureScreenContext` (snapshot, view models, environment, the setup
  actions), the header, the switch card with the status in words, the Needs
  setup box, the clip strip, the feature's shortcuts, "What it needs", the
  feature's own settings and its examples. A new screen is one case in
  `FeatureScreens` and `place: .screen` in the catalog; Drop keeps its own
  order around the same parts.
- The Agent, Meeting Notes and Google search get their own screens. Their
  switches stay in Other until Other is taken apart, so both write the same
  flag. The Agent's switch connects first and stays off with the reason
  ("Choose an Agent model in API & Models.") when it cannot. The old Agents
  link (`whytap://settings/agentMode`, the setup prompt) opens the Agent
  screen. The Agent's examples are only things its tools do today (files,
  a command, the screen, web search, To-do, Whytap's own settings).
- Google search's shortcuts are saved now (`hotkeys.googleSearchTextShortcut`,
  `…VoiceShortcut`, `…VoiceGesture`, also in backup and settings sync). They
  never were: a change on its screen or in Hotkeys was dropped at once and the
  key monitor kept Right Option (builder review of #458). A Google shortcut
  saved as a key combo now registers like an Agent combo, with Google's own
  callbacks and hot-key ids 19/20, and the Agent controller rebinds on a
  Google-only change; the Right Option default stays on the modifier path
  (builder review 537). The rebind builds the monitor's configuration from
  the six emitted values: `@Published` emits before it stores, so rereading
  the preferences left the changed field stale (a Google gesture Hold → Tap
  stayed Hold; builder review 540). An Agent turned on
  elsewhere clears the screen's earlier "why it did not turn on".
- Every catalog feature now has a screen. To-do and Case join the catalog as
  island tools (they need nothing, so they read Ready on a fresh Mac and the
  list's summary counts them). Translate and Subtitles keep one shared screen,
  as in the mockup: they share requirements, a window and a Toolbox pane.
  Drop's Smart mode stays on Drop's screen (Mode), not a screen of its own.
- A screen can hold more than one clip (`FeatureInfo.moreClips`, one strip
  each). Translate & Subtitles shows a Translate clip and a Subtitles clip;
  the Subtitles slot waits for `FeatureVideo.subtitles`
  (Resources/FeatureVideos/subtitles.mp4) and says "Video coming" until then.
- Other is taken apart. Its Drop, Meeting Notes, Google search and Agent rows
  live on their feature screens; what belongs to no feature (auto-hide, which
  display, screenshot protection) stays under the same raw id `other`, now
  titled **General**, so `whytap://settings/other` and the landing's catalog
  parser keep working (the parser reads ids, not titles; the title change
  needs a catalog refresh there).
- API & Models keeps its name for now. The mockup calls it "Keys & models",
  but about fifty messages and eleven documents say "API & Models", some in
  files other sessions own (the window controller, the main menu); a rename
  is its own change, decided by Maxim.

- API & Models is called "Keys & models" (approved mockup): in the sidebar,
  in every message that sends the reader there and in the current documents.
  The raw tab id `apiAndModels`, `whytap://settings/apiAndModels`, type and
  file names stay. Dated decisions and old plans keep the name they had.
  The OpenCode install hint now points to Settings → Features → Agent instead
  of the removed Settings → Other.

- The sidebar is the mockup's: Features, Keys & models, Permissions, Hotkeys,
  General. Meeting notes opens from Meeting Notes ("Open notes") and Toolbox
  from Hover (its tools' panes), with "‹ Meeting Notes" / "‹ Hover" above
  them; Notifications, Backup and Integrations are rows of General → More,
  with "‹ General". Their ids and `whytap://settings/…` links stay, and the
  row they belong to stays selected. The mockup's "Island tools" row is not
  added: Hover is that list now. Backup and Integrations stay two screens
  (the mockup's "Backup & integrations" would merge them; not done here).

## Why

- A newcomer thinks in features, not in providers, routes and permissions.
  The same data drives the list, the screens and later the assistant, so one
  place decides what "ready" means.
- An orange outline on a feature the person does not use reads as an error he
  cannot explain. A missing step is reported only for something that is on.
- "Ready" that ignores the shortcut would send a person away with dictation
  that does nothing. Drop's status therefore includes whether macOS delivers
  its shortcut (`DropHotkeyStatus`): Input Monitoring, a key taken by another
  app, a stale Accessibility entry after an update.
- A status the app cannot check is not drawn as checked: macOS gives no way
  to ask about system audio in advance, so it reads "macOS asks at the first
  recording" and never counts as done or missing.

## Where the mockup and the app differ

The app's behaviour wins, with "simple for a newcomer" as the tie-breaker.

- Drop Fast and Drop Smart keep separate speech routes. In Smart the list
  shows Smart's speech model and text model as required and Fast's model as
  optional; the mockup drew one speech model.
- Input Monitoring is not a separate permission row. Before macOS 27.3 Drop
  works without it and it is asked only when the event tap is refused; on
  27.3 it is part of Keyboard control. The row "Your shortcut is heard"
  covers both, and a shortcut that merely waits for Keyboard control or the
  Microphone is not counted a second time. On 27.3, once Override is on and
  Input Monitoring is the one step left (`KeyboardSetup.inputMonitoring`),
  Keyboard control's row asks for Input Monitoring and the shortcut row waits
  for it: one step, one action, as in Permissions.
- "On this Mac" needs Apple Silicon: an Intel Mac is never offered the
  download.
- Translate & Subtitles and Screenshots have no switch and no Off.
- Google search with no voice model is Ready, "typing only".
- The Agent's web search follows its model and is not a requirement.
- "Stop Drop automatically" acts only on a Toggle shortcut: with Hold the
  switch is disabled and says why.
- Mode, Language you speak, Vocab and Filler lived only in the island. Mode
  and language are now also set on Drop's screen through the island's own
  actions; Vocab and Filler open their island editors (new editors inside
  Settings are a later step).
- On a Mac where Drop is not ready, "What it needs" comes before "Try it
  here"; the mockup had the field first in both states.
- The shortcut row keeps the app's sentence about Space being hold-only: it is
  computed from the key bound now, so it cannot go stale.
- The model dropdown shows the app's label ("On this Mac · parakeet-tdt-v3").

## What we tested

`FeatureCatalogTests`: a fresh install without keys (only Drop needs setup,
the first action is the free model); a downloaded model not yet chosen; a
running and a failed download; Intel; permissions missing, a grant that needs
a restart, Input Monitoring, a shortcut in use, a stale Accessibility entry;
Smart mode; a set model whose key stopped working; features that are off;
and, after the build-queue review of this PR (ticket 519): Smart ready with
Fast missing or broken, the text model missing with Fast working and not,
the Agent's and search's voice parts, Translate and Subtitles each alone,
both and neither, the 27.3 Input Monitoring stage beside Override, restart
and the older-macOS fallback, and refused, removed and unsupported routes
with and without another model to pick; and, after the review of the
Drop screen (ticket 523): a model picked while the free model downloads
is kept, the download is used when nothing changed meanwhile, every key
action opens API keys while the sidebar still opens Models, and the back
link has the shared hover, press and focus feedback;
Meeting Notes and the Agent turned on without models; island tools; a rebound
key and a stale Toggle stored for Space; the summary line; no text naming a
key.

`SettingsFeaturesTests`: the list on a fresh install, an Intel Mac and a usual
Mac read from the live view models; the tab order and identifiers; the
`whytap://settings/features` link; where each row leads; the sidebar fitting
the smallest window; offscreen pictures of the start screen in both themes at
960 x 560 and 1280 x 760.

`DropFeatureTests`: a recorded key saved at once and stored; a key in use
refused with recording left open; Cancel; Space hold-only and another key as
Toggle; the local model chosen in place, for Drop only, and refused when it
is not on the Mac or the feature needs a text model; the words of the Needs
setup box and the requirement counter; offscreen pictures of the screen in
the Settings window (both themes, 960 x 560 and 1280 x 760, usual and fresh)
and of its states (Intel, downloading, Smart, recording a shortcut, a rebound
Toggle key).

Not checked in a running app: dictating into "Try it here" inside Settings,
the real permission prompts, the download itself.

## Rejected

- Features directly in the sidebar (three groups): six features were named
  twice with different names and statuses, and the rows had to shrink.
- Keeping the orange outline and glow as the "not connected" cue: it carries
  no words and lit up for unused features.
- A switch and Off for island tools: the app has no such switch.
- An Input Monitoring row shown as a permission to allow on every macOS: on
  older systems it would ask for something Drop does not need.

2026-11-24 · ORCH-TASK 99 · feature catalog PR
