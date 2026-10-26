---
id: whytap-project
type: project
title: Whytap desktop application
summary: Native macOS voice input, meeting notes and a customizable local agent workspace.
status: confirmed
tags: [macos, swift, dictation, meetings, agent]
canonical_for: [project-overview]
verified_at: 2026-10-19
sources:
  - type: repository
    reference: README.md
    confirmed_at: 2026-09-07
  - type: repository
    reference: Sources/Sidekey/PostProcessor.swift
    confirmed_at: 2026-09-07
related: [decisions/2026-10-26-first-launch-permissions.md, decisions/2026-10-22-native-agent.md, decisions/2026-10-19-planner.md, decisions/2026-10-20-backup-auto-sync.md, decisions/2026-10-20-compact-selection-menus.md, decisions/2026-10-20-screenshot-toolbar.md, decisions/2026-10-20-translation-tools.md, decisions/2026-10-19-whytap-name.md, decisions/2026-10-19-config-backup.md, decisions/2026-10-19-script-notifications.md, decisions/2026-10-19-remove-projects.md, processes/shared-app-development.md, decisions/2026-10-19-shared-working-app.md, decisions/2026-10-19-community-signing-identity.md, decisions/2026-10-19-one-running-copy.md, bugs/2026-10-19-permission-stability-audit.md, bugs/2026-10-19-input-language-audit.md, decisions/2026-10-19-strict-drop-modes.md, decisions/2026-10-18-brightness-tool.md, decisions/2026-10-18-clipboard-retention.md, decisions/2026-10-18-toolbox-drag-feedback.md, decisions/2026-10-17-community-updates.md, decisions/2026-10-17-source-first-distribution.md, decisions/2026-10-17-hover-tool-search.md, decisions/2026-10-17-exodia-name.md, decisions/2026-10-17-native-hover-glass.md, decisions/2026-09-07-smart-latency.md, decisions/2026-09-07-codex-model-registry.md, decisions/2026-09-07-soniox-meeting-files.md, decisions/2026-09-08-transcript-copy.md, decisions/2026-09-10-byok-and-local-builds.md, decisions/2026-09-10-onboarding-models.md, decisions/2026-09-10-public-installation.md, decisions/2026-10-17-local-workspace.md, decisions/2026-10-18-remove-local-models.md, decisions/2026-10-18-legacy-model-cleanup.md, decisions/2026-10-18-no-default-realtime-host.md, decisions/2026-10-18-provider-batch-transcription.md, decisions/2026-10-20-simple-github-backup.md, decisions/2026-10-20-meeting-continuations.md]
---

# Whytap

Whytap provides native macOS dictation, meeting notes, and integration with
a built-in native agent with optional Tavily search. Speech and text run only on the user's provider keys (BYOK) or their own
OpenAI-compatible endpoints; on-device models were
[removed](decisions/2026-10-18-remove-local-models.md). Architecture and build instructions live in `agent-context.md` and
`../docs/build-and-release.md`.

The existing `../docs/` records remain the entrypoints for historical decisions.
New reasoning-policy and finalization behavior is recorded in
[the Smart latency decision](decisions/2026-09-07-smart-latency.md).

Drop honors [the selected Fast or Smart mode](decisions/2026-10-19-strict-drop-modes.md) throughout the take and Retry; Smart never silently substitutes raw text.

Build and publication policy: [local builds](decisions/2026-09-10-byok-and-local-builds.md).

Launch opens the island directly; setup lives in Settings.
[Projects and automatic project context are removed](decisions/2026-10-19-remove-projects.md).
Existing project-library files are retained, unused. The ordinary agent uses
its [dedicated neutral workspace and bounded native conversation](decisions/2026-10-22-native-agent.md).

Coding harnesses share the [source customization workflow](../docs/customization/README.md).

Distribution: [community binaries and updates](decisions/2026-10-17-community-updates.md), signed with the Developer ID team and, for published releases, [notarized by Apple](../docs/decisions/2026-10-21-notarized-releases.md), with source builds retained for customizations.
The earlier [Apple-notarized DMG policy](decisions/2026-09-10-public-installation.md)
is historical; runtime installation and resource checks remain current.

Hover uses [three-column native-glass capsules](decisions/2026-10-17-native-hover-glass.md),
with current status inside each control and a legacy material on older macOS.
The current development candidate follows the user's 2026-10-17 correction:
smaller capsules in a drawer matching the actual compact island width.
Monitor opens its dashboard picker inside the same hover drawer; see
[dashboard contracts](../docs/customization/dashboards.md).
Brightness, added from the catalog, opens a backlight slider with an Extra
(EDR) switch: [brightness tool](decisions/2026-10-18-brightness-tool.md).

Public source: [AbsoluteMode/whytap](https://github.com/AbsoluteMode/whytap).
Naming and storage compatibility: [restored Whytap name](decisions/2026-10-19-whytap-name.md).

Hover search launches any catalog tool without adding it to the user's saved
buttons: [tool search](decisions/2026-10-17-hover-tool-search.md).

Clipboard retention: [bounded local history survives restarts](decisions/2026-10-18-clipboard-retention.md).

Parallel feature sessions share one installed application and report exactly
what to check: [shared application development](processes/shared-app-development.md).
Rationale: [one working app](decisions/2026-10-19-shared-working-app.md).

Permission and hotkey reliability: [audit and implementation acceptance](bugs/2026-10-19-permission-stability-audit.md).
Input language: [provider transport audit and Deepgram corrections](bugs/2026-10-19-input-language-audit.md).

Release signing: [the Developer ID team certificate](decisions/2026-10-21-developer-id-team-signing.md), with [the self-signed community certificate](decisions/2026-10-19-community-signing-identity.md) as the fallback without the team file.
Application ownership: [one running copy](decisions/2026-10-19-one-running-copy.md).

[Notify](decisions/2026-10-19-script-notifications.md) restores left-side pills and agent-configured local script sources.

Encrypted recovery copies: [GitHub integration and one-action backup](decisions/2026-10-20-simple-github-backup.md); [encryption and recovery gates](decisions/2026-10-19-config-backup.md).

Text translation and floating system-audio subtitles: [translation tools](decisions/2026-10-20-translation-tools.md).

Screenshot capture and text/number blur: [screenshot editor](decisions/2026-10-20-screenshot-toolbar.md).

Meeting notes process each call immediately and supplement the existing note after confirmed reconnects: [three-minute continuations](decisions/2026-10-20-meeting-continuations.md).

[Planner](decisions/2026-10-19-planner.md) adds local tasks/events and a common view of selected native and directly connected calendars.
