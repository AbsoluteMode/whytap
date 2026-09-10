---
id: public-installation-2026-09-10
type: decision
title: Ship a notarized universal DMG with a guided first launch
summary: Public installation uses a ready-made DMG, rejects temporary launch locations and verifies packaged runtime resources locally.
status: confirmed
tags: [installation, macos, release, gatekeeper, onboarding]
canonical_for: [public-installation]
verified_at: 2026-09-10
sources:
  - type: user-confirmed
    reference: User request in the 2026-09-10 Whytap task to open-source the app and make installation work smoothly for other users.
    confirmed_at: 2026-09-10
  - type: repository
    reference: Sources/Sidekey/InstallationGuard.swift
    confirmed_at: 2026-09-10
  - type: repository
    reference: scripts/build-dmg.sh
    confirmed_at: 2026-09-10
  - type: url
    reference: https://developer.apple.com/library/archive/technotes/tn2206/
    confirmed_at: 2026-09-10
related: [../project.md]
---

# Public installation

## Context

The user approved public distribution after adding BYOK-first onboarding.
The existing local packaging flow already signs, notarizes and staples a
universal DMG with an Applications shortcut and a drag-to-install background.
However, a user could launch the temporary disk-image copy before installing.

## Decision

Use the ready-made universal DMG as the main download. Document a Finder
installation with no terminal or developer dependencies. Keep agent CLIs
optional. Show keys and model setup before the first dictation.

Before constructing AppDelegate, stop app bundles on read-only volumes or in
AppTranslocation. Show installation instructions and an Open Applications
button, then quit the temporary copy. Do not overwrite an existing app or
request permissions for a temporary copy. Writable installed, external-drive
and development copies continue normally.

Make Gatekeeper rejection a hard packaging failure. Add an installation-check
mode that loads the executable and its frameworks, verifies essential bundled
resources and exits before user-state initialization. Use it to verify the
actual release executable without reading keys or contacting providers.

## Alternatives

A source-only install would require Xcode and compilation. An automatic move
could overwrite an existing installation or require privileged file actions.
The normal Finder copy handles installation and replacement explicitly.

## Rationale

Keep the first installation familiar and prevent permission setup on a
temporary disk-image copy. Signing and notarization allow normal macOS checks
to remain enabled. Packaging checks catch missing runtime files before upload.

## Sources

The user request, installation guard, packaging script and Apple's code-signing
guidance listed above. User instructions are in `../../docs/install.md`.

## Comments and objections

The user explicitly required local builds because of GitHub runner cost.

## Resolution

Build and verify on the maintainer's Mac; distribute the resulting DMG on
GitHub Releases and make the source repository public.

## Consequences

Launching from a read-only volume requires installation first. Packaging and
test evidence on the maintainer's Mac do not replace a physical clean-Mac test
on every supported macOS version or Intel hardware.

## Supersedes / superseded by

Supersedes permissive launch from disk-image copies and warning-only handling
of Gatekeeper rejection during packaging. No later decision is known.
