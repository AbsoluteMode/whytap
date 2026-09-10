---
id: byok-and-local-builds-2026-09-10
type: decision
title: Present BYOK first and build updates on the maintainer's Mac
summary: Lead with user-supplied keys, keep local models available, and avoid GitHub runner costs.
status: confirmed
tags: [byok, local, settings, builds, releases, github-actions]
canonical_for: [processing-presentation-order, official-build-location]
verified_at: 2026-09-10
sources:
  - type: user-confirmed
    reference: User instruction in the 2026-09-10 Whytap task to put BYOK before local and build every update on this Mac because GitHub is expensive.
    confirmed_at: 2026-09-10
  - type: repository
    reference: Sources/Sidekey/Settings/SettingsModelsView.swift
    confirmed_at: 2026-09-10
  - type: repository
    reference: docs/build-and-release.md
    confirmed_at: 2026-09-10
related: [../project.md]
---

# BYOK presentation and local builds

## Context

The initial open-source copy led with local models. Both Models segments
displayed Local before Your key. Releases were already packaged locally,
but pushes and pull requests still triggered GitHub-hosted build/test jobs.

## Decision

Present Your key (BYOK) first, then Local, in the product description, setup
instructions and both Models segments. Existing saved routes and fresh-install
processing defaults are unchanged by this presentation change.

Build, test, sign and package official updates on the maintainer's Mac.
Disable the repository's GitHub CI workflow and remove its automatic triggers.
Do not use GitHub Actions for builds or validation. GitHub remains the source
repository and the host for completed DMGs and the signed Sparkle appcast.
The exact local commands live in `../../docs/build-and-release.md`.

## Alternatives

Keeping Local first would not match the requested product emphasis. Keeping
automatic hosted validation would continue consuming GitHub runner capacity.

## Rationale

The user explicitly requested BYOK before local and local update builds to
avoid GitHub costs. Reordering presentation does not require migrating an
existing user's processing route.

## Sources

The user instruction above, the Models view and the release guide establish
the requested order and build location.

## Comments and objections

No objections were recorded. The user specifically identified GitHub cost.

## Resolution

Use BYOK-first presentation and local validation and release packaging.

## Consequences

Pull requests need recorded local build/test results. No hosted CI run will
verify a push automatically. Release downloads and in-app updates continue
using GitHub Releases.

## Supersedes / superseded by

Supersedes the initial Local-first presentation and automatic hosted CI.
No later decision is known.
