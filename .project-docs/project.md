---
id: whytap-project
type: project
title: Whytap desktop application
summary: Native macOS voice input, meeting notes and local CLI agent integration.
status: confirmed
tags: [macos, swift, dictation, meetings, agent]
canonical_for: [project-overview]
verified_at: 2026-09-07
sources:
  - type: repository
    reference: README.md
    confirmed_at: 2026-09-07
  - type: repository
    reference: Sources/Sidekey/PostProcessor.swift
    confirmed_at: 2026-09-07
related: [decisions/2026-09-07-smart-latency.md]
---

# Whytap

Whytap provides native macOS dictation, meeting notes, and integration with
local agent CLIs. Processing uses on-device models or the user's provider
keys. Architecture and build instructions live in `agent-context.md` and
`../docs/build-and-release.md`.

The existing `../docs/` records remain the entrypoints for historical decisions.
New reasoning-policy and finalization behavior is recorded in
[the Smart latency decision](decisions/2026-09-07-smart-latency.md).
