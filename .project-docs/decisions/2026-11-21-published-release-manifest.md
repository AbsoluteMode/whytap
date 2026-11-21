---
id: published-release-manifest-2026-11-21
type: decision
title: Releases publish their provenance manifest and a verify footer
summary: upload-release.sh attaches the build-time provenance manifest as a third release asset, written release notes end with a committed "Verify your download" footer, and docs/install.md explains spctl, codesign, the Team ID and the manifest check.
status: confirmed
tags: [release, provenance, signing, notarization, install, github]
canonical_for: [published-release-manifest]
verified_at: 2026-11-21
sources:
  - type: user-confirmed
    reference: On 2026-11-21 Maxim approved the second batch of GitHub page fixes from the model council review, including publishing the provenance manifest, a Verify your download section and a permanent release notes footer.
    confirmed_at: 2026-11-21
  - type: repository
    reference: scripts/upload-release.sh
    confirmed_at: 2026-11-21
  - type: repository
    reference: scripts/release-notes-footer.md
    confirmed_at: 2026-11-21
  - type: repository
    reference: scripts/tests/test_latest_release.py
    confirmed_at: 2026-11-21
related: [2026-10-21-developer-id-team-signing.md]
---

## Context

Every release DMG already had a sealed provenance manifest (source commit,
SHA-256, size, version, build, signing identity, notarization), but it stayed
on the maintainer's Mac: GitHub Releases carried only `Whytap-latest.dmg` and
`appcast.xml`, and no user document named the Team ID. A careful user could
not tie a download to a commit or to Whytap's Apple team.

## Decision

- `upload-release.sh` uploads the verified manifest as
  `<Bundle>-latest.dmg.manifest.json` to the versioned release, after
  `generate_appcast` and before the draft is published, and checks its uploaded
  bytes like the DMG and appcast. The rolling beta feed release gets no copy.
- When `RELEASE_NOTES_FILE` is set, the release body is that file followed by
  [scripts/release-notes-footer.md](../../scripts/release-notes-footer.md), with the asset names, signing identity
  and notarization filled in. GitHub-generated notes are unchanged: `gh`
  would put extra text before the generated list, not after it.
- `docs/install.md` → Verify your download gives the `spctl`/`codesign`
  commands, the expected Team ID `UVBKCN5PPV`, and how to compare the manifest
  with `shasum`.

## Why

The manifest contains only public release metadata (no paths, user names or
keys), so publishing it costs nothing and turns an internal gate into evidence
anyone can check. The footer keeps every written release pointing at the same
check without relying on whoever writes the notes to remember it.

## What was tested

`scripts/tests/test_latest_release.py` runs the publisher against fake `gh`
and Sparkle tools: three assets in order, the published manifest byte-identical
to the build-time one and free of local paths, the footer appended with no
unfilled placeholder, generated notes untouched, and a corrupted upload still
leaving the release a draft. The documented `spctl` and `codesign` commands
were run against a downloaded 2.2.17 DMG and the installed app.

## Rejected

- Renaming the manifest's `archive` field to the `-latest` name: it would
  change the sealed schema and break existing verifiers; the guide explains it.
- A separate `SHA256SUMS` file: the manifest already holds the digest together
  with the commit and signing identity.
- Appending the footer to generated notes: `gh` only prepends extra text there.

2026-11-21, docs/github-page-batch2.
