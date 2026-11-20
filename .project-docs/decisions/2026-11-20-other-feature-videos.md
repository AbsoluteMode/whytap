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
  build without the clip shows no button.
- Clips are the accepted motion videos already published on whytap.ai, copied
  byte for byte (720p, SHA-256 matching the landing `videos.lock.json`):
  `meetings.mp4` (1.4 MB) and `agent.mp4` (0.76 MB) in
  `Resources/FeatureVideos`, copied into the bundle by `dev-run.sh` and
  `build-dmg.sh`.
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
- Not verified: video playback in the popover and the click flow in the
  installed app (offscreen rendering does not draw AVPlayer frames).

## Rejected

- Streaming clips from whytap.ai: a Whytap-owned network dependency.
- Autoplaying clips inline in every row: motion and CPU on a settings page.
- Moving "Allow file edits and commands" to the plugin behind the harness Yes:
  first accepted, then Maxim kept it as a separate row in Other.
- Keeping Connect as its own button: duplicated the switch.

2026-11-20 · PR: Agent group in Other with feature clips
