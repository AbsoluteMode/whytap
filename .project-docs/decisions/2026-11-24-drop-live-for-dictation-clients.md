---
id: drop-live-for-dictation-clients-2026-11-24
type: decision
title: An allowed app shows the Drop take in its own field, and the wing stays quiet
summary: whytap_drop_live gives one separately allowlisted app (Whycode, by Apple-vouched Team ID and identifier of the helper's parent, after the one-time Yes) the running take's phase, partial text, level and orb energy. Words go only to the app the take is going into. While that app keeps asking to show the text itself, the island's wing gets no partials. The Yes opens nothing else.
status: confirmed
tags: [drop, app-control, privacy, plugin, whycode, orb]
canonical_for: [drop-live, live-dictation-clients]
verified_at: 2026-11-24
sources:
  - type: user-confirmed
    reference: On 2026-11-24 the maintainer asked, about the Whycode orchestrator his brother builds, that dictating into Whycode put the words straight into its input instead of the island's right wing, and that Whycode's orb react to the voice like Whytap's; he approved changing Whytap through a pull request so that it gives this data to Whycode specifically.
    confirmed_at: 2026-11-24
  - type: repository
    reference: Sources/Sidekey/AppControl/DropLiveFeed.swift
    confirmed_at: 2026-11-24
  - type: repository
    reference: Sources/Sidekey/AppControl/HarnessAccess.swift
    confirmed_at: 2026-11-24
  - type: repository
    reference: Tests/SidekeyTests/AppControl/DropLiveTests.swift
    confirmed_at: 2026-11-24
related: [2026-11-20-harness-access.md, 2026-10-21-app-control-plugin.md, 2026-11-21-one-whytap-mcp-server.md]
---

# Live Drop take for an allowed app

## Context

Whycode is an Electron window with its own composer field and a canvas copy
of Whytap's orb. It already reads `activity.drop` from `whytap_get_state`.
While the maintainer dictates into it, the words appear in the island's right
wing and reach the field only as the final paste, and its orb cannot react
because Whytap gives no level. The live partial is the user's speech before
they decided to send it, the most sensitive thing Drop holds; until now no
external process could read it.

## Decision

- **A separate list.** `DropLiveFeed.allowedClients` holds the apps that may
  read the live take: Whycode, Team ID `UVBKCN5PPV`, identifier
  `com.rootwise.whycode`. It is not `CaseCallerResolver.knownAIApps`.
  `HarnessCallerResolver` recognises it the same way (the helper's direct
  parent, Team ID only when an Apple chain vouches for it) and marks it
  `HarnessScope.liveDictation`. The gate refuses such a client every gated
  tool (meetings, Vocab, Filler) with `unsupported_client`, and refuses a
  coding harness `drop_live` the same way. Case never sees it.
- **The same Yes, its own words.** The first call, or `request_access` right
  after the server connects, shows the harness card and store, but the card
  asks "Let Whycode show your dictation?" and VoiceOver reads what that
  covers (only takes into Whycode; no other apps' dictation, meetings,
  settings or Case keys). The Settings -> Integrations -> Coding tools row
  says the same. No is remembered, the switch turns it off, and the gate
  rechecks the answer before the reply leaves.
- **Words only for their destination and their take.** The take's target
  pid is captured at `startDropTurnTelemetry`, right after
  `rememberDropTarget()`. `text` is sent only while the take can still deliver
  (recording through inserting/finishing) and that pid is the caller's own
  process; for a take into any other app (or a Whytap editor, which has no
  pid) the caller sees the phase and the level, never words. A session's
  partials carry its take id, so a late on-device decode from a cancelled
  session cannot reach a later take. `endTake()` drops the words and the
  target: `endDropTurn` calls it before looking at the diagnostic trace, and
  the feed also ends the take itself whenever the Drop phase becomes `idle`
  or `deliveryFailed` (`endTakes(on:)`), so a take whose trace the 640 s
  watchdog already dropped cannot hand old words to a Retry. Energy is 0
  outside `recording`. The task allowed the partial for any take; this is narrower
  and costs Whycode nothing, because it only needs its own takes.
- **The wing.** `showsLiveText: true` keeps an opt-in for 1.5 s. While it holds
  and the running take goes into that same process, `onTranscriptUpdate`
  skips `dropTranscriptUpdated`; the orb, phase and paste are untouched. When
  the app stops asking (composer blurred, app quit or hung), the next partial
  reaches the wing again with the text the provider normally supplies.
- **Long on-device takes.** `OnDeviceTranscriptionSession` re-decodes only
  its trailing ~14 s for the island ticker. It now also reports, per partial
  (`onTranscriptWindow`), whether that window still starts at the beginning
  of the take. Such a frame, like every cloud partial, is the whole take and
  replaces the text (growth, a revised first word, any script). Only a
  shifted window is joined onto the words already sent where it overlaps
  them: longest run compared without case or punctuation, latest on a tie,
  by words, or by characters when the window has hardly any spaces
  (Japanese, Chinese, Thai); no overlap appends, so the field keeps the start
  of the take. Guessing a shift from the text alone was tried first and
  rejected by review: it duplicated short growing takes, revised leading
  words and unspaced text. The client shows a preview either way; the paste is
  final. Showing only the trailing window was rejected: the field would lose
  the start of a long take while the person is still speaking.
- **Energy.** `VoiceOrbView.voiceEnergy` is the orb's adaptive gate and
  normalisation, moved out of `displayEnergy` unchanged; the island orb and
  `drop_live` use the same function, and the client applies the follower's
  smoothing itself.
- **Not advertised.** `whytap_drop_live` is callable by name but not in
  `tools/list`, so no coding harness carries a tool it can never use. Only
  the gate answers it; `AppControlController` returns `unknown_operation`, so
  the built-in Agent and any ungated path cannot read the take. Nothing in
  it is logged.
- **Numbers.** `AppControlValue` gained `.double` for `level` and `energy`;
  whole numbers still decode as `.int`.

## What was checked

`DropLiveTests` (27; the builder's reviews added failed, ended, late-partial,
watchdog-then-Retry, short, revised, unspaced and long on-device, and
wording cases) and an on-device session test of the shifted flag: an ad-hoc build, another certificate with Whycode's
identifier and a script in Whycode's terminal are refused without a prompt;
Whycode's Yes opens no gated tool; Claude Code with a Yes is refused
`drop_live`; No is kept and cannot quiet the wing; payload for a take into
Whycode, into another app and into a Whytap editor; text gone after the
take, new `takeId` per take, blank partials latched; argument checks; wing
quiet only for the opted-in client's own take, back after 1.5 s or
`showsLiveText: false`; access turned off returns nothing; the controller
alone does not know the tool; energy equals the orb's gate. MCP tests: the
tool is not listed and is forwarded by name; fractional numbers round-trip.
Live checks with a running build and a signed Whycode are in the pull
request.

## Rejected

- Adding Whycode to `knownAIApps`: one Yes would have opened meetings and
  Vocab/Filler writes to an app that needs only its own dictation.
- Live fields in `whytap_get_state`: every client would read them, and the
  state call is not gated.
- Partials of every take: Whycode does not need words spoken into other apps.
- A pushed stream: the helper opens one authenticated socket per request; a
  10 Hz poll costs a small JSON reply and no new channel.
- Matching the target by bundle identifier: the pid of the helper's parent is
  what the gate verified; another process with the same identifier is not
  the caller.
