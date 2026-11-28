---
id: subtitle-engine-choice-2026-11-28
type: decision
title: The user chooses the Subtitles engine; without a choice OpenAI stays
summary: Keys & models -> Models -> Subtitles offers Soniox stt-rt-v6 and OpenAI gpt-realtime-translate in the same model picker as other rows. Only an engine with a readable key is selectable; the other is listed with the key it needs. The choice is saved and is the only source at Start. Without a choice Subtitles use OpenAI, or Soniox when only a Soniox key exists, and the default that first opens is saved. A chosen engine without a readable key is never replaced by the other one. This replaces the silent "Soniox whenever its key exists" rule of 2026-11-25.
status: confirmed
tags: [translation, subtitles, soniox, openai, routing, settings, privacy]
canonical_for: [subtitle-engine-choice]
verified_at: 2026-11-28
sources:
  - type: user-confirmed
    reference: On 2026-11-28, after the release review found that a 2.2.27 user with both an OpenAI key and a Soniox key (for dictation) would have Subtitles audio moved to Soniox by the update without being asked, the owner answered "let the user choose the model himself, add a model choice", relayed by the orchestrating session (task 115). Earlier the owner kept both providers so that a user with only an OpenAI key has a complete setup.
    confirmed_at: 2026-11-28
  - type: repository
    reference: Sources/Sidekey/Translation/SubtitleAudioTranslate.swift
    confirmed_at: 2026-11-28
  - type: repository
    reference: Sources/Sidekey/Settings/APIAndModels/APIAndModelsViewModel.swift
    confirmed_at: 2026-11-28
  - type: repository
    reference: Tests/SidekeyTests/Translation/SubtitleAudioTranslateTests.swift
    confirmed_at: 2026-11-28
related: [2026-11-25-subtitle-soniox-engine.md, 2026-11-22-subtitle-audio-translate-slot.md, 2026-11-28-backup-keys-unknown-to-the-writer.md]
---

# The user chooses the Subtitles engine; without a choice OpenAI stays

## Context

2026-11-25-subtitle-soniox-engine.md made Subtitles use Soniox whenever a
Soniox key could be read and OpenAI otherwise, with no choice in Keys &
models. The last public release, 2.2.27, ran Subtitles on OpenAI only. A user
of that release who also has a Soniox key (for Drop) would, after updating,
have system audio sent to Soniox without any action of their own. The owner
asked for a model choice instead and kept both providers.

## Decision

- **Choice.** `SubtitleAudioTranslate.Choice` stores the engine under
  `sidekey.translation.subtitleEngine` (`soniox` / `openAI`). It is the only
  source at Start (`engineAndKey(saved:from:)`). An unknown value (a newer
  build) reads as no choice and is left in place.
- **Default without a choice.** OpenAI, unless the OpenAI key is absent and
  a Soniox key exists. An unreadable OpenAI key still means OpenAI, so a
  Keychain hiccup never sends audio to Soniox. A fresh install and an update
  from 2.2.27 cannot be told apart reliably (no prior Subtitles preference
  was ever stored), so both get this default; Soniox's speed and price do not
  outweigh not changing a recipient silently.
- **Pinned default.** The first session that opens without a choice saves its
  engine, so adding the other key later never moves the audio. An explicit
  choice made meanwhile, or a stored unknown value, is never overwritten.
- **No silent switching.** A chosen (or default) engine whose key is missing
  or unreadable is not replaced: Start fails before capture with "Subtitles
  are set to <provider> and need its API key…" or "Whytap couldn't read the
  <provider> key…", and opens Keys & models on Subtitles. This follows the
  existing unavailable path; no other feature falls back to another provider
  (routes "never move a feature to another provider").
- **Settings.** The Subtitles row uses the same model control and searchable
  picker as other feature rows (`SubtitlesModelMenu` -> `ModelPicker`), Soniox
  then OpenAI. An engine without a key is a disabled entry with "Add a <key>
  in API keys to use it"; an unreadable key shows "Couldn't read the key" on
  its header. With neither key the picker shows its usual "Add a key for
  Soniox or OpenAI" state and the menu reads "Choose a model". A chosen engine
  without a working key keeps its label, the card shows the setup contour, a
  status line names the key with Open API keys, and it counts in the "features
  have no model" banner.
- **App control.** `get_settings` returns `subtitlesEngine` (the saved value
  or null) without reading the Keychain; `set_setting` accepts `soniox` /
  `openAI` with the usual expected-value check and refuses an engine without
  a readable key (`not_configured`). Subtitles still have no feature route, so
  `set_model` / `list_models` do not cover them.
- **Backup and sync.** The key is in the Keys & models block of
  `ConfigBackupRegistry` (so Settings sync carries it too). Restore uses the
  one mechanism for keys an archive's writer did not know
  (`2026-11-28-backup-keys-unknown-to-the-writer.md`): archives made before
  this change (2.2.27 and earlier, no `knownKeys`) cannot contain it, so it
  is in `keysAddedAfterUnlistedArchives` and restoring them keeps this Mac's
  value. An archive whose writer knew the key restores it like any other
  setting, a missing value included; App defaults resets it. On the release
  branch this replaced the PR's separate `keptWhenAbsent` list.
- **Unchanged.** Costs record each session under the engine's account and
  model (`AIUsageContext .subtitlesAudio`); runtime error messages name the
  engine in use; the one-hour limit.

## Why

- Audio must not change recipient without the user's action; the release
  review found exactly that case.
- The owner asked for the user to choose, and for an OpenAI-only setup to
  stay complete.
- Pinning the default closes the remaining silent switch: someone who
  started on Soniox alone and later adds an OpenAI key keeps Soniox.
- Restoring an old archive must not reset a deliberate choice.

## What was tested

`SubtitleAudioTranslateTests`: only OpenAI, only Soniox, both keys without a
choice (OpenAI), both keys with each choice, the chosen key removed (named,
other engine unused, nothing captured at Start, choice kept), unreadable keys
(named, not replaced; no choice + unreadable OpenAI stays OpenAI), the choice
read back by a new defaults instance (relaunch), the pinned default, an
older archive keeping the choice and a newer one restoring it; the Models row
in each key state (label, summary, picker entries enabled/disabled/selected,
setup contour, banner count, picking an engine without a key refused).
`AppControlControllerTests`: read without a key, refused without a key, set
with a key, expected-value conflict, invalid values. Not checked: the
installed app; the row was not rendered on screen.

## Rejected

- Keep "Soniox whenever its key exists": moves 2.2.27 users' audio silently.
- Soniox as the default with both keys for new installs only: an update and
  a fresh install cannot be told apart reliably.
- Falling back to the other engine when the chosen key is missing: a silent
  change of recipient.
- A schema bump of the settings archive to tell old archives apart: wider
  than needed; the key-level keep-when-absent rule covers it.
- A Subtitles feature route for `set_model`: Subtitles' Speech/LLM routes are
  retired and kept only for rollback (2026-11-22); writing them would alter
  that saved data.

2026-11-28 · branch feature/subtitles-engine-choice
