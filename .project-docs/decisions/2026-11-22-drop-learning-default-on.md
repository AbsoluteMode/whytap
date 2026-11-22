---
id: drop-learning-default-on-2026-11-22
type: decision
title: Learning from edits is on by default, and the first Settings Other group is named Drop
summary: "Learn from my edits" reads as on when its key was never written and stays off once the user switches it off, with no migration. The Settings, Other group with Lower other audio, Stop Drop automatically and Learn from my edits is renamed from Recording to Drop.
status: confirmed
tags: [drop, settings, privacy, defaults]
canonical_for: [drop-learning-default, settings-other-drop-group]
verified_at: 2026-11-22
sources:
  - type: user-confirmed
    reference: ORCH-TASK 72 REV 17 forwarded by the orchestrator. The user asked why the switch sat under Recording, then decided to turn learning on by default, add a feature video and rename the group to Drop.
    confirmed_at: 2026-11-22
  - type: repository
    reference: Sources/Sidekey/DropLearning/DropLearningSettings.swift
    confirmed_at: 2026-11-22
  - type: repository
    reference: Sources/Sidekey/Settings/SettingsOtherView.swift
    confirmed_at: 2026-11-22
  - type: repository
    reference: Tests/SidekeyTests/DropLearning/DropLearningScenarioTests.swift
    confirmed_at: 2026-11-22
related: [2026-11-22-drop-edit-learning.md, 2026-11-22-drop-learning-drops.md, 2026-11-11-drop-auto-stop.md]
---

## Context

Learning from edits after Drop shipped off by default behind a switch in
Settings, Other, Recording. The user decided it should be on for everyone
who has not turned it off, and that the group holding the three Drop
switches should say Drop.

## Decision

- `DropLearningSettings.isEnabled(in:)` returns the stored value when the
  key `sidekey.dropLearning.enabled` exists and `true` when it does not.
- No migration. The key is written only by the switch in Settings (and by
  tests), so a missing key means the user never touched it, which now
  reads as on; an explicit `false` from a user who switched it off is kept.
- Calibration stays off and hidden; nothing else changes in what is read
  or stored.
- The first group in Settings, Other is titled Drop: Lower other audio while
  speaking, Stop Drop automatically, Learn from my edits.

## Why

- A missing key versus an explicit `false` already separates "never
  touched" from "switched off", so default-on needs no flag of its own and
  cannot override a choice the user made.
- All three switches change how Drop behaves; Recording also suggested
  meeting recording, which lives under Features.

## What we tested

No key: enabled, the field is captured and read. Explicit `false`: no
capture and no read. `true` again: captured. The Settings source has a Drop
group containing the three switches and no Recording group.

## Rejected

- A one-time migration writing `true`: it could not tell a user who switched
  it off in build 1718 from one who never saw the switch.
- Keeping the Recording title: it did not say what the group is about.

2026-11-22 · ORCH-TASK 72 REV 17
