---
id: whytap-preview-before-validation-2026-11-26
type: decision
title: The owner checks a preview of the feature first; the full suite and merge follow the approval
summary: A preview lane builds main plus the unmerged PRs the owner is checking as a local arm64 app, with no full suite, and installs it under the usual safety gates beside validation work. Only PRs whose every changed input is of a preview-safe kind and that build on nothing unmerged are previewed; everything else goes to normal validation. The installed app records its own composition, which is the queue's source of truth for what the owner sees.
status: confirmed
tags: [agents, queue, builder, watcher, preview, approval, packaging]
canonical_for: [builder-preview-lane]
verified_at: 2026-11-26
sources:
  - type: user-confirmed
    reference: On 2026-11-26 the owner set the order preview first, tests after approval ("I have to review the FEATURE itself — that it satisfies user scenarios and nothing lags. For that I don't need tests. Tests can be done after I approve the feature"), and that the builder does no code review before his approval either; the target is minutes from a worker's push to the fix running in his app.
    confirmed_at: 2026-11-26
  - type: user-confirmed
    reference: On 2026-11-26 the orchestrator split the builder changes into quick wins and this lane, and asked that every finding of the builder's review of ticket 628 be fixed, preferring simplicity; a rule that cannot be enforced sends the PR to normal validation.
    confirmed_at: 2026-11-26
  - type: repository
    reference: scripts/build-queue.py
    confirmed_at: 2026-11-26
  - type: repository
    reference: scripts/build-queue-watcher.py
    confirmed_at: 2026-11-26
  - type: repository
    reference: scripts/build-dmg.sh
    confirmed_at: 2026-11-26
related: [../processes/shared-app-development.md, 2026-11-26-release-batches.md, 2026-11-26-builder-quick-wins.md]
---

# Preview before validation

## Context

The owner's own pain is the loop of small fixes ("this window lags", "this
should look different"): each one waited for review, the full suite, the merge
and an install, often hours. He checks the feature itself; tests and code
review can follow his approval. Two earlier versions of this lane (tickets 626
and 628) were blocked by the builder's review: a filename and changed-line
filter that indirect calls, opaque files and symlinks passed; decisions not
bound to the build the owner runs; a recorded composition that an interrupted
swap or a later decision made stale; stacked previews that outlived a rejected
parent; and boundaries checked at claim time but not at the handoff.

## Decision

- **Preview lane.** A worker submits a reviewed head with `enqueue --preview`
  after its own branch build and targeted tests. A second LaunchAgent
  (`run-preview`, loaded by `activate --preview-lane`) starts a short preview
  session beside a validation session, with its own lock, state and warm
  worktree. It never reviews, runs the full suite, merges or pushes. It
  composes `origin/main` plus the **train** (every unmerged PR the owner's app
  must carry: previews awaiting his check, approved features waiting for a
  release, a release in progress) plus the ticket, builds a local arm64 app
  (`EXODIA_LOCAL_INSTALL=1`, incremental) and installs it under the meeting
  gate, `whytap-app.lock` and the safety checks: signature, identity and
  designated requirement, `arm64` slices, higher build, native
  `--installation-check`, one running instance, a known-good rollback bundle.
- **Admission fails closed on input kinds.** A preview may change only
  regular files (mode 100644) of these kinds: Swift sources under `Sources/`,
  Swift tests, Markdown documentation, images under `Resources/` whose bytes
  match their type (PNG, JPEG, PDF) and text resources (strings, string
  catalogs, SVG) without binary content. Any changed Swift file is read whole:
  no line in it may reach stored data, credentials, permissions, signing,
  updates, files, processes or code loaded at run time, directly or through a
  type named like a state gateway (`…Settings`, `…Store`, `…Defaults`,
  `…Preferences`, `…Database`, `…Repository`, `…Credential`, `…Backup`,
  `…Archive`, `…Migration` and similar). Anything else, and anything that
  cannot be read, goes to normal validation. `preview-claim` checks each PR;
  `preview-admit --base <main> --commit <composed>` checks the whole
  composition, for previews and for every builder install that carries the
  train.
- **Restore-point tier** (added the same day, owner's decision REV 6): with
  an installed app that makes restore points, settings and stores changes
  are previewed too, protected by a restore point of the outgoing app; what
  a restore point cannot undo stays in normal validation for both tiers.
  Details: decision record `preview-restore-points-2026-11-26`, merged with
  the app change.
- **No stacked previews.** A preview that declares an unmerged dependency or
  contains another open PR's head in its history goes to normal validation.
- **The installed app is the record.** A local build stores its composition
  (`ExodiaBuildComposition`: main base and member tickets with heads) in its
  `Info.plist`; `build-dmg.sh` refuses a composition whose base or heads are
  not in the built source. The queue reads the installed app for the rebuild
  decision, for `awaiting_approval` (refused unless the app carries exactly
  the train plus this ticket) and for every decision. An interrupted swap
  needs no recovery record: whatever is installed is what is compared.
- **One handoff gate.** Right before the Quit, under the app lock,
  `preview-handoff --base --members --build [--ticket]` refuses when merged work waits
  for a local install (a retry flag or pending protected-data tests; a
  historical receipt without a flag does not count), when the ticket is no
  longer the preview to build or a newer head was submitted, when the
  members are not the current train, when the installed app's main is not in
  this base, when a member is already in main, or when the installed build is
  not lower than the candidate's. It also refuses whatever it cannot prove
  (ticket 655 item 3): an installed app whose build, base or composition
  cannot be read (composition members are unique positive integer tickets
  with full SHAs), and a base that does not contain the current fetched
  `origin/main`, so an install never puts older code over data a newer
  build migrated. `preview-claim` checks the
  same local-install condition before it returns an active preview; a
  recovered preview then goes back to the queue with its place.
- A declined Quit or a permission prompt blocks the preview for a person. A
  fix pushed while its preview builds supersedes that build. Switching the
  lane off, or deactivating the watcher, sends queued and active previews to
  normal validation and turns `preview_lane` off in the configuration.

## Rationale

The owner's time goes into the preview loop; the code gates exist for what
reaches main. Only a rule the helper can enforce protects his data, so the
lane accepts what a lexical check can prove harmless and nothing else. On the
commits of main up to 2026-11-26 this admits 1 of the last 40 and 5 of the
last 100 (most changed Swift files name a settings or store type somewhere):
the lane is narrow on purpose, and its scope can widen only with a different
protection (for example separate data for preview builds), not with a
cleverer filter.
Reading the installed app instead of a queue record removes every class of
stale or lost composition.

## Alternatives

- A path and changed-line filter: passed indirect calls, opaque files and
  symlinks (ticket 628).
- Recording the installed composition in the queue: lost or stale after an
  interrupted swap or a concurrent decision.
- Stacked previews with dependency closure across lanes: most of the
  recovery defects of ticket 628 came from it.
- Previews of every PR with a data snapshot and manual restore: wider, but
  unreviewed code would still reach the Keychain and permissions; left for
  the owner to decide.

2026-11-26
