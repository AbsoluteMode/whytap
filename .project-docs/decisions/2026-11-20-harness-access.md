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
related: [2026-10-21-app-control-plugin.md, 2026-11-03-todo-helper.md, 2026-10-20-whytap-links.md, 2026-11-21-one-whytap-mcp-server.md, 2026-11-23-agent-drop-lists.md, 2026-11-24-drop-live-for-dictation-clients.md, 2026-11-25-helper-follows-new-build.md, 2026-11-26-coding-tools-switches.md]
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
  its MCP server connects to a running Whytap, the island shows one line,
  "Give Claude Code access to Whytap?", with No and Yes. It is the Case approval card and queue:
  one prompt at a time, armed after 0.3 s of a quiet keyboard, Y / N / Escape,
  denied as unanswered after 60 s. Yes shows the connection being made for
  1.9 s: the dots between the two marks turn green one by one, then "Claude
  Code connected" with a checkmark (Reduce Motion: the finished state).
- **The answer is remembered** per Mac, for Yes and for No, in one Keychain
  item of the app (`harness_access.answers`). Settings -> Integrations -> Coding
  tools lists the answers with a switch. The gate reads the answer before a
  request and again before its response leaves, so off stops an open session
  and a request already reading. An answer the Keychain refused to store
  holds for this launch and is retried on every read.
- **A stored Yes needs its seal.** The Keychain item and
  `harness-access-seal.json` beside the broker socket carry the same random
  token, renewed on every successful save. The seal is written atomically and
  read back from disk before it counts. At launch a stored Yes applies only
  when the tokens match; a missing, unreadable or different seal fails
  closed and the harness is asked again. A stored No never needs the seal.
  When the Keychain refuses a No, the seal gets a new token, so the Yes still
  in the Keychain matches nothing on disk any more, and the No is listed in
  the seal so it denies after a relaunch. Only Nos are read from the seal; a
  Yes written there by another process is ignored. If the seal cannot be
  written either, it is removed, which cancels the stored Yes as well; only
  when that fails too does Settings say that access may come back after a
  restart. A No given while the Keychain is locked therefore also makes
  other tools be asked again.
- **Nothing stored is cached.** Every decision is worked out from what the
  Keychain and the seal hold at that moment, plus the answers of this launch
  (which always apply here). So a Yes that lost its seal during the launch
  is not honoured or written back, a seal that was unreadable at launch
  still counts once it can be read, and the Settings warning is computed
  from what a relaunch would actually do. A save merges the seal's Nos; it
  does not run while the Keychain is locked or the seal is unreadable. The
  card's answer is dropped when the user answered in Settings meanwhile.
- **Where the item is.** Checked on the signed app on 2026-11-20
  (`codesign -d --entitlements`, `security find-generic-password` metadata of
  the Case vault key): the app has no entitlements and its items are in the
  user's file-based login keychain. The data-protection keychain and
  `kSecAttrAccessible` classes are not available to this build, so the
  attribute is not set. The item is not synchronized and is read without a
  prompt only by code its access list trusts, the app that created it.
- **What Yes covers.** Every current and future content and action tool of the
  plugin, except deleting data, which will ask each time when it exists.
  Today: `whytap_meetings_search`, `whytap_meeting_get`,
  `whytap_meeting_transcript`, `whytap_meeting_open`. Settings and To-do tools
  keep the 2026-10-21 boundary and need no answer.
- **Case is separate.** The gate never loads the Case vault or reads its
  registrations, and a Case registration (even Bypass) gives no access to
  meetings. Secret values stay behind `whytap case run`.
- **Meeting links.** `whytap://meeting/<id without dashes>` shows one note
  (Invariant 7: show only). Tools return it as `link`. Neither the link nor
  `whytap_meeting_open` replaces a note the user is editing: the tool answers
  `busy`, the link shows nothing.

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
  after Yes; unreadable stored answers allow nobody; while the Keychain is
  locked nothing is trusted or overwritten; a No the Keychain refused still
  denies after an immediate relaunch, also with the Keychain locked, and is
  stored once it is writable; after that refused No a missing, unreadable or
  different seal leaves the stored Yes unhonoured and the harness is asked
  again; the refused No replaces the seal token; a No that reached neither
  place is reported; a Yes survives a relaunch only with its seal and a No
  always; the seal file counts only as read back from disk; access turned off during a read returns nothing; a
  cancelled request stops waiting while the prompt stays; the Settings switch
  stops and restores access without a prompt.
- `HarnessAccessPromptTests`: Y only after the quiet keyboard, A is not an
  answer, N and Escape refuse, timeout, the confirmation and its replacement by
  the next question; offscreen renders of every face.
- `AppControlMeetingsTests`: search by inflected words, dates, limits, paging
  by segments and bytes, cut notes, unknown ids, a missing store.
- `CaseBrokerTests`: the gate decides before the controls and without the vault.
- Full suite on 794a3120 with the console unlocked, 2026-11-20: 4741 tests,
  38 skipped, 0 failures. With the Mac locked the same run fails 74 tests in
  the Planner, To-do, Calendar and backup suites: files written with
  `completeFileProtectionUnlessOpen` cannot be read then (Cocoa 257). They are
  unrelated to this change; run the full suite with the screen unlocked.
- Not tested: the installed app with a live harness, the real key tap and the
  compositor. Source tests do not show that a host's plugin connection updated.

## Rejected

- A Connect button in Settings: the user asked for no clicks there.
- Case registrations as the gate: it would load the vault for every content
  request and tie meetings to secret access.
- Waiting for the answer inside `initialize`: hosts time the handshake out.
- Any known ancestor as the harness: a script run by the agent would inherit it.
- A plain file or UserDefaults for answers: any process could grant itself.
- A file authenticated with a Keychain key (built first): the review showed
  that an old, genuinely signed Yes could be copied back after the user
  turned access off.
- Asking again for recording, settings and other actions: the user chose one
  Yes for everything except deletion.
- A terminal, Cursor or an unknown program as a client in this step: a lasting
  answer needs an identity Apple vouches for; a terminal's would cover every
  script run in it.
- SQLite FTS5 now: a scan is enough at this size; add an index if it gets slow.

## After the first live use

On 2026-11-20 the user accepted the installed card and asked for three
changes: no gap between the island and the card, in the question and in the
confirmation; one line of text; an animation on connecting. The gap had two
causes. A line of the island's edge showed above the card, so the card now
overlaps that edge by 1 pt. And the island rounded its bottom corners as soon
as the question was answered, while the confirmation was still attached under
it; the island now keeps its square edge until the confirmation leaves,
through a separate geometry-only state (`caseCardAttached`). The builder
caught the first attempt, which stretched `caseApprovalActive` over the
confirmation: the prompt's key tap had already stopped, so for 1.9 s a
visible Agent answer did not own Escape and it reached the foreground app. What
Yes covers is no longer written on the card; VoiceOver still reads it.

## Builder review

The builder blocked the first submission on 2026-11-20: a No the Keychain
refused came back as Yes after an immediate relaunch, the Settings switch
showed Off without saying it was unsaved, and the code set
`kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`, which the file-based
keychain ignores. A journal of refused Nos in UserDefaults came first; the
builder blocked it too: preferences are flushed later and unverified, and a
lost or unreadable journal let the old Yes win. The seal above replaced it:
losing it removes access instead of restoring it. The existing Case vault key sets the same ignored
attribute; that is left for its own change.

A third builder pass found two more, fixed with tests: a Yes for another
tool cleared the warning about an Off that was saved nowhere (the warning now
stays until that Off is saved or reversed), and `whytap_meeting_open` moved
the window before the gate's second check (the tool now rechecks consent
through `HarnessConsent.stillAllowed` with no suspension before the window).

Before the fourth submission Codex walked the store through sequences of
failed writes and relaunches and found five that broke it: both writes
refused and the old pair still matching; a seal unreadable at launch losing
its No; a loaded Yes surviving the seal's rotation and being written back;
a warning that did not match what was on disk; the card's Yes overwriting a
later No. The store was rewritten to the model above instead of patched, and
each sequence is a test. A second pass confirmed four closed and added two,
fixed: a seal folder that cannot be looked into was taken for a missing seal
(absence must now be confirmed by a listing), and a No stored nowhere was
not sealed when the seal became writable again (the seal is retried on every
read while a No is unverified). The first one stands as a limit: when the
Keychain write, the seal write and the seal removal all fail, nothing on
disk can change, the old Yes applies after a relaunch, and Settings says so
until then.

## Review

Codex reviewed the branch on 2026-11-20 and found, all fixed here: a signed
answers file could be rolled back; opening a meeting dropped an unsaved note
edit; a response could leave after access was turned off; `maxBytes` did not
bound one very long reply; the access probe ran more than once and was waited
for at EOF; a four-letter Cyrillic word did not match its other cases; ISO
timestamps with fractional seconds were refused. Gemini 4 Carbon discussed
the specification but was unavailable for the code review.

Left open, older than this change: `capture_screen` of the screen-only MCP
server answers any local process running the helper, under Whytap's Screen
Recording permission. A meeting link can now put a known note on screen
first. It needs its own decision.

## Limits

A process of the same user that copied the seal earlier and puts it back
after a No the Keychain refused restores the match. It needs that Keychain
failure and a hostile local process at the same moment; such a process can
read the meeting files directly anyway.

The answer is consent for the plugin's tools, not protection of files: notes
and transcripts are files any process of the user can read. A harness the user
allowed is trusted as a whole, including its own configuration and extensions.

2026-11-20 · branch `feature/harness-access`
