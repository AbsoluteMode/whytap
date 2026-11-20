---
id: harness-access-2026-11-20
type: decision
title: A coding harness asks once and then reads meetings through the plugin
summary: The Whytap plugin's content tools work for the coding harness that started the plugin's MCP server itself (Claude Code, Codex) after the user's one Yes in an island prompt. The answer is remembered per Mac. Meeting search, note, transcript and open are the first tools behind it. Case secrets keep their own registrations and approvals.
status: confirmed
tags: [agents, plugin, app-control, meetings, privacy, case]
canonical_for: [harness-access]
verified_at: 2026-11-20
sources:
  - type: user-confirmed
    reference: On 2026-11-20 the user asked for a plugin through which Claude Code and Codex have full control of Whytap, except unauthorized access to Case; the first scenario is "find / look at a meeting". Connecting needs no clicks in Settings: the user adds the plugin, Whytap shows "give Claude Code access", Yes is remembered and No makes the plugin get a refusal. The user chose that one Yes covers everything except deleting data.
    confirmed_at: 2026-11-20
  - type: repository
    reference: Sources/Sidekey/AppControl/HarnessAccess.swift
    confirmed_at: 2026-11-20
  - type: repository
    reference: Sources/Sidekey/AppControl/AppControlMeetings.swift
    confirmed_at: 2026-11-20
  - type: repository
    reference: Sources/Sidekey/Meetings/MeetingsAgentRead.swift
    confirmed_at: 2026-11-20
  - type: repository
    reference: Tests/SidekeyTests/AppControl/HarnessAccessTests.swift
    confirmed_at: 2026-11-20
related: [2026-10-21-app-control-plugin.md, 2026-11-03-todo-helper.md, 2026-10-20-whytap-links.md]
---

## Context

The application-control server (2026-10-21) answers any local process that runs
the bundled helper as the user. That is why it exposed only non-secret settings
and, later, To-do titles: no notes, transcripts, recording or deletion. The
user now wants a coding harness to do in Whytap what they do by hand, starting
with finding and reading meetings, and wants connecting to cost one answer.

## Decision

- **Who is asking.** The harness is the helper's direct parent process, matched
  by Apple-vouched team and signing identifier: Claude Code
  (`Q6L2SF6YDW` / `com.anthropic.claude-code`) and Codex (`2DC432GLL2` /
  `codex`). Anything else gets `unsupported_client` without a prompt.
- **One question.** The first time a harness needs a gated tool, or right after
  its MCP server connects to a running Whytap, the island shows "Let Claude
  Code use Whytap?" with No and Yes. It is the Case approval card and queue:
  one prompt at a time, armed after 0.3 s of a quiet keyboard, Y / N / Escape,
  denied as unanswered after 60 s. Yes shows "Claude Code connected" for 1.4 s.
- **The answer is remembered** per Mac, for Yes and for No, in
  `harness-access.json` beside the broker socket. Its contents carry an
  HMAC-SHA256 made with a device-bound Keychain key, so a process of the same
  user can delete the file (the harness is asked again) but cannot write an
  `allow`. Settings -> Agents -> Coding tools lists the answers with a switch;
  the gate reads the answer on every request, so off stops an open session.
- **What Yes covers.** Every current and future content and action tool of the
  plugin, except deleting data, which will ask each time when it exists.
  Today: `whytap_meetings_search`, `whytap_meeting_get`,
  `whytap_meeting_transcript`, `whytap_meeting_open`. Settings and To-do tools
  keep the 2026-10-21 boundary and need no answer.
- **Case is separate.** The gate never loads the Case vault or reads its
  registrations, and a Case registration (even Bypass) gives no access to
  meetings. Secret values stay behind `whytap case run`.
- **Meeting links.** `whytap://meeting/<id without dashes>` shows one note
  (Invariant 7: show only). Tools return it as `link`.

## Why

- A prompt the plugin triggers itself is the whole setup: there is no screen to
  find and nothing to paste.
- The MCP server answers `initialize` at once and asks for access afterwards
  through a client that never launches Whytap. Hosts drop a server that is slow
  to initialize, and a user-scoped server starts with every harness session;
  it must not open a closed Whytap in the background.
- The prompt belongs to the gate, not to the request that caused it: a harness
  session that ends does not take the question away, and sessions that start
  together share one card.
- Only the direct parent counts. Verified on 2026-11-20 on running processes:
  Claude Code and Codex Desktop both start `whytap … mcp` as their own child.
  A script in the harness's shell (`claude -> zsh -> node -> whytap`) has
  another parent and does not inherit the answer.
- Reusing the Case card keeps one queue of island prompts and its tested
  arming, timeout and key handling. Two panels could overlap.
- Search is a bounded scan (400 newest meetings in range) inside the
  `MeetingsStore` actor. Every query word must be in the title, note or
  transcript; long words lose their ending so an inflected form matches. The
  answer carries a note snippet and the three best replies with speaker and
  time, so "where did we discuss X" is usually one call.

## What was tested

- `HarnessAccessTests`: Yes asked once and remembered; No remembered and never
  asked again; an unanswered prompt grants nothing; sessions starting together
  share one prompt; `request_access` returns `pending` without waiting; a
  client that left gets nothing; a script in the harness shell is refused even
  after Yes; a forged or re-signed file is ignored; without the Keychain
  nothing is trusted or overwritten; the Settings switch stops and restores
  access without a prompt.
- `HarnessAccessPromptTests`: Y only after the quiet keyboard, A is not an
  answer, N and Escape refuse, timeout, the confirmation and its replacement by
  the next question; offscreen renders of every face.
- `AppControlMeetingsTests`: search by inflected words, dates, limits, paging
  by segments and bytes, cut notes, unknown ids, a missing store.
- `CaseBrokerTests`: the gate decides before the controls and without the vault.
- Not tested: the installed app with a live harness, the real key tap and the
  compositor. Source tests do not show that a host's plugin connection updated.

## Rejected

- A Connect button in Settings: the user asked for no clicks there.
- Case registrations as the gate: it would load the vault for every content
  request and tie meetings to secret access.
- Waiting for the answer inside `initialize`: hosts time the handshake out.
- Any known ancestor as the harness: a script run by the agent would inherit it.
- A plain file or UserDefaults for answers: any process could grant itself.
- Asking again for recording, settings and other actions: the user chose one
  Yes for everything except deletion.
- A terminal, Cursor or an unknown program as a client in this step: a lasting
  answer needs an identity Apple vouches for; a terminal's would cover every
  script run in it.
- SQLite FTS5 now: a scan is enough at this size; add an index if it gets slow.

## Limits

The answer is consent for the plugin's tools, not protection of files: notes
and transcripts are files any process of the user can read. A harness the user
allowed is trusted as a whole, including its own configuration and extensions.

2026-11-20 · branch `feature/harness-access`
