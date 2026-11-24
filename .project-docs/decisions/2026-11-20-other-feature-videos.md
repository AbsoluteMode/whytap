---
id: other-feature-videos-2026-11-20
type: decision
title: Settings Other gets short descriptions, feature clips and the Agent group
summary: Settings descriptions never name a remappable key; Other rows can open a bundled silent clip with the live shortcut; the Agents tab became an Agent group in Other (one switch that enables and connects, plus Allow file edits and commands), Coding tools moved to Integrations and the workspace path is in the plugin's get_state.
status: confirmed
tags: [settings, agent, video, hotkeys, plugin]
canonical_for: [other-feature-videos, agent-settings-in-other]
verified_at: 2026-11-20
sources:
  - type: user-confirmed
    reference: On 2026-11-20 the user asked for the shortest descriptions plus a video per feature in Other, for Agent to become one entry in Other with other settings done through Claude Code or Codex, and then to keep Allow file edits and commands as a separate field in Other.
    confirmed_at: 2026-11-20
  - type: repository
    reference: Sources/Sidekey/Settings/FeatureVideo.swift
    confirmed_at: 2026-11-20
  - type: repository
    reference: Sources/Sidekey/Settings/AgentOtherSection.swift
    confirmed_at: 2026-11-20
  - type: repository
    reference: Tests/SidekeyTests/Settings/AgentOtherSectionTests.swift
    confirmed_at: 2026-11-20
related: [2026-11-21-first-launch-onboarding.md, 2026-11-24-settings-around-features.md]
---

# Settings -> Other: short descriptions, feature clips, Agent in one group

## Context

Settings descriptions named keys the user can remap ("Right Option searches
your selection on Google.", "Right Command: tap for text, hold for voice.").
After a rebind they misled the user. Maxim asked (2026-11-20) for the shortest
possible descriptions plus a video that shows how each feature works, and for
the separate Agents tab to become one Agent entry in Other, with everything
else configured through Claude Code or Codex via the Whytap plugin.

## Decision

- Row descriptions in Settings never name a remappable key; they say
  "Shortcut(s) in Hotkeys" when the key matters (PR #319).
- A row may carry a ▶ `FeatureVideoButton` left of its title. Click opens a
  popover with the bundled clip, muted and looping, and "Your shortcut:" with
  the live keys from `HotkeyConfiguration`. Nothing plays before the click; a
  build without the clip shows no button. The full play target uses the shared
  Settings hover, pressed, keyboard focus and disabled states.
- Clips are the accepted motion videos already published on whytap.ai, copied
  byte for byte (720p, SHA-256 matching the landing `videos.lock.json`):
  `meetings.mp4` (1.4 MB) and `agent.mp4` (0.76 MB) in
  `Resources/FeatureVideos`, copied into the bundle by `dev-run.sh` and
  `build-dmg.sh`.
- Follow-up the same day: Maxim accepted four more clips made for these rows
  ("accept, into the app"): `google-search.mp4`, `drop-auto-stop.mp4`,
  `screen-protect.mp4` and `auto-hide.mp4` (85–460 KB each). They are not on
  whytap.ai yet, so they are 720p re-encodes of the kit's render with the
  landing import settings (H.264, BT.709 limited range, CRF 28). The Drop
  clip shows an example Toggle combo (there is no default one), so its popover
  names the user's own Drop shortcut; Google's names its Text and Voice keys.
  Screenshot protection and Auto-hide have no shortcut line.
- The Agents tab leaves the sidebar. Other gets an Agent group: an Agent switch
  that enables the shortcuts and connects the native Agent in one step (off
  disables and disconnects; no model means a message with Choose model), and
  a separate "Allow file edits and commands" switch.
- `SettingsWindowTab.agentMode` stays as an enum case: `whytap://settings/agentMode`
  and the Agent setup prompt resolve it to Other and highlight the Agent row.
- The model stays in API & Models (and `whytap_set_model`). The workspace path
  is `agentWorkspace` in `whytap_get_state`, replacing Open folder.
- Coding tools (harness access answers) move to Integrations.

## Why

- A key name in prose goes stale after a rebind; a live keycap under the clip
  does not, and the clip explains more than a sentence.
- Bundled clips keep invariant 1 (no Whytap-owned service): Settings never
  fetches from whytap.ai. Two clips add about 2.2 MB to the app.
- One Agent switch: the old shortcuts switch and Connect/Disconnect described
  the same intent twice; connecting cannot move to the plugin, because a user
  without Claude Code or Codex could then never turn the Agent on.
- "Allow file edits and commands" stays in Settings (Maxim, 2026-11-20). It is
  a security control; the plugin's rule that security controls stay outside
  the application-control server is unchanged.
- Coding tools cannot move to the plugin: a coding tool must not grant itself
  access to meetings. Integrations is where external tools connect already.
- The `agentMode` raw value is part of the public link registry, which must
  never be renamed.

## What we tested

- Offscreen renders of Other (light/dark, 560/760 pt, connected/disconnected)
  with the clips looked up from the source Resources folder: ▶ appears on
  Meeting Notes and Agent, the Agent group has two rows.
- Unit tests: tab resolution and highlight, switch state, live shortcut labels,
  bundled clip sizes and packaging, no `http` in the clip code, workspace path
  equals the folder the Agent creates, no source copy points to Settings → Agents.
- Follow-up: an offscreen render shows ▶ on all six feature rows; a test
  requires a ▶ for every bundled clip. The minimum clip size dropped to 40 KB
  because the mostly still Auto-hide clip encodes to 85 KB.
- Not verified: video playback in the popover and the click flow in the
  installed app (offscreen rendering does not draw AVPlayer frames).

## Rejected

- Streaming clips from whytap.ai: a Whytap-owned network dependency.
- Autoplaying clips inline in every row: motion and CPU on a settings page.
- Moving "Allow file edits and commands" to the plugin behind the harness Yes:
  first accepted, then Maxim kept it as a separate row in Other.
- Keeping Connect as its own button: duplicated the switch.

2026-11-20 · PR: Agent group in Other with feature clips
