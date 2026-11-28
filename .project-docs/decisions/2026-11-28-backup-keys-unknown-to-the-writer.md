---
id: backup-keys-unknown-to-the-writer-2026-11-28
type: decision
title: Restoring settings resets a missing preference only when the backup's writer knew it
summary: Settings payloads and settings-history snapshots now list the preference keys the writing app could back up. A key missing from the values is reset only if that list contains it; a key added in a later app keeps its value. Archives and snapshots from 2.2.27 carry no list, so restoring them keeps the three Google Search hotkeys added since.
status: confirmed
tags: [backup, restore, settings, hotkeys]
canonical_for: [backup-keys-unknown-to-the-writer]
verified_at: 2026-11-28
sources:
  - type: user-confirmed
    reference: On 2026-11-28 the release-batch inquisition (orchestrator card 42) reported that restoring the Hotkeys section from a 2.2.27 archive reset the new Google Search hotkeys because the settings schema stayed 4 and missing keys are removed; the orchestrator asked to preserve keys an older archive could not contain.
    confirmed_at: 2026-11-28
  - type: repository
    reference: Sources/Sidekey/Backup/ArtifactBackupRestore.swift
    confirmed_at: 2026-11-28
  - type: repository
    reference: Sources/Sidekey/Backup/ConfigBackupRegistry.swift
    confirmed_at: 2026-11-28
  - type: repository
    reference: Tests/SidekeyTests/Backup/BackupKeysUnknownToWriterTests.swift
    confirmed_at: 2026-11-28
related: [2026-10-19-config-backup.md, 2026-11-28-subtitle-engine-choice.md]
---

# Backup keys unknown to the writer

## Context

A settings restore writes every value in the payload and removes every
registry key of the restored sections that the payload lacks, so restoring a
section returns it exactly to the backup. That is wrong for a key the writing
app did not have: 2.2.27 archives cannot contain the Google Search hotkeys
added afterwards, and restoring Hotkeys from one reset them. Earlier additions
were handled by bumping the payload schema, but a schema bump makes 2.2.27
refuse every new archive.

## Decision

- `ArtifactSettingsPayload` and `ConfigBackupSnapshot` carry an optional
  `knownKeys`: every registry key the writing app could back up. The current
  app always writes it; "App defaults" lists all keys, so a reset stays a full
  reset.
- On restore, a missing key is reset only when the writer knew it. Without a
  list (archives and snapshots up to 2.2.27), the keys added since, listed once
  in `ConfigBackupRegistry.keysAddedAfterUnlistedArchives`, keep their values.
  That list is closed with the release that ships `knownKeys`: it holds the
  three Google Search hotkeys and the Subtitles engine choice, the keys added
  between 2.2.27 and this release. Later additions are covered by
  `knownKeys`. The Subtitles engine's separate `keptWhenAbsent` list from its
  PR was folded into this mechanism, so restore has one rule.
- The payload schema stays 4. Decoders that do not know the field ignore it, so
  2.2.27 still restores new archives.

## Why

Only the writer knows which keys it could have saved; recording that once
removes the need for a schema bump or a new exception per added setting.

## What we tested

- A 2.2.27-shaped payload restoring Hotkeys keeps the Google Search shortcuts,
  restores the keys it contains and still resets known keys it lacks.
- A payload whose writer knew the keys resets them; any key missing from the
  writer's list keeps its value.
- A backup created now carries its known keys through a real archive.
- A settings-history block from an older snapshot keeps the new keys, and App
  defaults resets them.

## Rejected

- Bumping the settings schema to 5: 2.2.27 would refuse every new archive.
- Never removing missing keys: restoring a section would no longer return it to
  the backup.

2026-11-28 · orchestrator card 42, release-batch inquisition
