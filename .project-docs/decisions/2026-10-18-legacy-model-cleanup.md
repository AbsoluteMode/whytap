---
id: legacy-model-cleanup-2026-10-18
type: decision
title: Remove leftover on-device model weights once at launch
summary: Launch removes Application Support/Sidekey/LocalTranscriptionModels, LocalLLMModels and LocalDiarizationModels once per flavor. Nothing else is touched, including FluidAudio's cache with the meeting detector's Silero VAD.
status: confirmed
tags: [local, models, disk, migration, meetings]
canonical_for: [legacy-model-cleanup]
verified_at: 2026-10-18
sources:
  - type: user-confirmed
    reference: User choice in the 2026-10-18 cleanup task after the local route's removal; option (b), a one-time launch cleanup of only the three Sidekey/Local*Models folders plus a release-note line; FluidAudio is not touched.
    confirmed_at: 2026-10-18
  - type: repository
    reference: Sources/Sidekey/LegacyLocalModelCleanup.swift
    confirmed_at: 2026-10-18
  - type: repository
    reference: Tests/SidekeyTests/LegacyLocalModelCleanupTests.swift
    confirmed_at: 2026-10-18
related: [../project.md, 2026-10-18-remove-local-models.md, 2026-11-19-on-device-dictation.md]
---

# Remove leftover on-device model weights

## Context

PR #22 removed the on-device route. Its three model stores had downloaded
weights into `Application Support/Sidekey`:

- `LocalTranscriptionModels`: Parakeet TDT 0.6B v3 (Core ML);
- `LocalLLMModels`: MLX Qwen3 4B Instruct at 4 bits, about 2.3 GB on its own;
- `LocalDiarizationModels`: the on-device speaker-diarization Core ML bundles.

Nothing reads these folders after #22, so a user who downloaded the models
keeps a few GB of dead data. Every flavor (prod, beta, dev) resolved the same
path. FluidAudio keeps its own cache in
`Application Support/FluidAudio/Models`; the meeting detector's
Silero VAD lives there and is still needed.

## Decision

- `LegacyLocalModelCleanup.run()` runs from `applicationDidFinishLaunching`,
  right after the credential migration, on a utility-QoS background queue.
- It removes exactly those three folders, resolved the way the retired stores
  resolved them. The rest of `Sidekey` and all of `FluidAudio` stay.
- A symlinked folder loses only the link; its target stays.
- The pass is recorded in UserDefaults
  (`com.sidekey.legacyLocalModelCleanup.completed`) only when no removal
  failed. A folder that is absent counts as done. A failed removal leaves the
  marker unset, so the next launch retries.
- The log line carries counts only (`removed`, `failed`), no paths.
- Release note, in the prose style of the 2.2.7 notes: "On the first launch
  after the update, Whytap deletes the on-device model files that earlier
  versions downloaded to Application Support/Sidekey, freeing up to a few GB.
  Meeting detection files are kept."

## Why

- Disk space: after #22 the weights are dead data, a few GB in a folder users
  rarely open.
- Only these three folders: the retired stores owned them alone. FluidAudio's
  cache holds the Silero VAD the meeting detector needs. The user asked not to
  touch FluidAudio at all, so an older Parakeet copy there is also left alone.
- Once, with a marker: the flavors share the folder but not their UserDefaults
  domain. Without the marker, someone still running an older build that uses
  local models would lose its re-downloaded models on every launch of the new
  one.
- Retry until a clean pass: a partial failure must not mark the job done and
  leave gigabytes behind.
- Background queue: removing gigabytes can take a moment on a slow disk;
  launch does not wait for it.

## What we tested

- `LegacyLocalModelCleanupTests`, 6 tests on a real temporary folder tree with
  an isolated UserDefaults suite:
  - the three folders with nested weights are removed;
  - `Sidekey/Meetings`, `Sidekey/meetings-staging` and `FluidAudio/Models`
    (Silero VAD and an old Parakeet copy) stay;
  - a symlinked folder loses only the link;
  - the pass runs once: a folder recreated after it stays;
  - absent folders count as done;
  - a removal blocked by permissions is retried on the next launch.
- TDD: the tests first failed to compile without the type. Against a no-op
  stub, 5 of 6 failed on assertions; the absent-folders test guards a specific
  mutation. All 6 then passed.
- Mutations, each reverted byte for byte:
  - also deleting `../FluidAudio/Models` failed the keep test;
  - resolving the symlink failed the symlink test;
  - dropping the once-only guard failed the once test;
  - setting the marker only when something was removed failed the
    absent-folders test;
  - setting the marker despite a failure failed the retry test.
- A trailing slash on the folder URL (`isDirectory: true`) kept all 6 green:
  Foundation strips it today, so the code avoids it only as a precaution.
- Full suite on main `0283042` plus this change: 2,829 tests, 5 skipped,
  0 failures (47.639 s).
- Not verified: the call from `applicationDidFinishLaunching` in a running app
  (compiled and reviewed only), and an upgrade of a real install with
  downloaded models.

## Rejected

- Move to the Trash: the space is not freed until the user empties it.
- Run on every launch: it would delete models that an older build sharing the
  folder downloads again.
- A Settings button: most affected users would never find it.
- Only a release note: gigabytes stay on disk for everyone who skips it.
- Also delete `FluidAudio/Models`: the meeting detector needs its Silero VAD.

2026-10-18, PR https://github.com/AbsoluteMode/exodia/pull/27.
