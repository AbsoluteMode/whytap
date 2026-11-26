---
id: lil-bro-answers-from-whytap-2026-11-24
type: decision
title: Lil Bro may ask whytap.ai, the first Whytap server the app talks to, only after the person turns it on
summary: The "no Whytap servers" invariant gets one exception. After the person presses Turn on answers in Lil Bro's balloon, each question they ask him, the Settings screen and up to three earlier exchanges go to whytap.ai's Ask endpoint, answered by claude-sonnet-5-5 while it is tried out (claude-haiku-5-5 before). Off by default, turned off from the same balloon; no keys, dictated text or identifiers are sent. Offline, unavailable and the daily limit are said plainly and change nothing.
status: confirmed
tags: [settings, lil-bro, privacy, network, invariant, ask]
canonical_for: [lil-bro-answers]
verified_at: 2026-11-24
sources:
  - type: user-confirmed
    reference: On 2026-11-24 the maintainer, after the first outside tester's feedback, asked to bring whytap.ai's answers into Settings "so people can ask right there and get answers", on Haiku ("Sonnet we can't afford for every user, Haiku is fine"), with a guide that leads people through Settings. The orchestrator task (107) asked for answers from Ask on whytap.ai, an honest privacy text, an explicit opt-in, an offline state, and a decision because the no-servers invariant changes.
    confirmed_at: 2026-11-24
  - type: repository
    reference: Sources/Sidekey/Settings/LilBro/LilBroRemoteBrain.swift
    confirmed_at: 2026-11-24
  - type: repository
    reference: Tests/SidekeyTests/Settings/LilBro/LilBroRemoteBrainTests.swift
    confirmed_at: 2026-11-24
related: [2026-11-24-lil-bro.md]
---

# Lil Bro's answers from whytap.ai

## Context

Lil Bro (2026-11-24-lil-bro.md) finds settings by name on this Mac. People ask
real questions ("can it take notes on Zoom", "does dictation work offline")
that a name match cannot answer. whytap.ai already answers such questions on
the site; the maintainer asked for those answers inside Settings, on Haiku.
Until now Whytap had no server of its own that the app talks to, and the
invariant said so.

## Decision

- One exception to "no Whytap-owned services": `LilBroRemoteBrain` posts to
  `https://whytap.ai/api/ask/lilbro` (server: AbsoluteMode/whytap-landing,
  `ask/lilbro.py`). It is the only place in `Sources/` that calls a whytap.ai
  API; a test fails if another file does.
- **Off by default.** Nothing is sent until the person presses **Turn on
  answers** on the disclosure in his balloon, under the text: each question
  then goes to whytap.ai (Claude Sonnet 5.5) with the Settings screen and up to
  three earlier whytap.ai questions with its answers, sent again; whytap.ai
  keeps each question, those earlier questions and answers, and its reply for
  90 days without your address; keys, dictated text and settings
  stay on this Mac. ⋯ → Turn on answers only shows that disclosure (with Not
  now); it never saves the choice itself.
- **One line, details on request (REV 4, 2026-11-26, the maintainer's product
  decision).** He found the full disclosure under three buttons "too much
  information at once". It is now one line ("Real answers come from
  whytap.ai (Claude Sonnet 5.5).") with Turn on answers and **Details**; the
  full text above (required by the builder in ticket 606) is kept unchanged
  under Details, so it can be read before the button is pressed.
- **The model picks the place (REV 4).** The maintainer: the guide should not
  be taught phrasings, "Haiku or Sonnet — let's use it while we try it out —
  they should understand on their own where to go". A question in any
  language goes to the model, which chooses the screen; the endpoint now uses
  claude-sonnet-5-5 (whytap-landing), with the same daily and monthly caps.
  The keyword guide stays the path while answers are off or offline. After a
  question this Mac did not understand, the line says whytap.ai understands
  any language and the button is **Turn on and ask**: that press turns answers
  on and sends that one question; earlier questions stay on this Mac.
- **Offered only when it helps (REV 5, REV 7).** The balloon opens with
  only the greeting and the reply field; the one-line disclosure shows by
  itself only after a question this Mac could not answer. There it is the
  whole reply: no "I only know Settings by name", no suggested questions
  (REV 7, the maintainer on 1769: "why isn't this fixed yet?"). It shows also
  after answers were turned on and off, since otherwise such a question would
  get no reply at all; the REV 5 marker `lilBro.answersEverOn` is gone.
  ⋯ → Turn on answers still shows it any time.
  With answers on, ⋯ sits next to the greeting, so they can be turned off
  before a question is sent (builder ticket 616). A question too short for
  whytap.ai gets the plain Turn on answers, never Turn on and ask. ⋯ → Turn off answers from
  whytap.ai stops it. The choice is `lilBro.answersFromWhytap`.
- **What is sent:** the question normalised as the server's
  `clean_question` does — split by Unicode scalar on Python's whitespace set
  (including U+001C–U+001F; a combining mark after a space is kept), joined
  with single spaces, cut at a character boundary to 300 scalars and trimmed
  again before the 3-scalar minimum (shorter stays local), the screen as raw ids (`features/drop`), and up to three
  earlier exchanges that whytap.ai itself answered, each cut to 300/600
  scalars (the question prepared the same way). A question asked while
  answers were off is never sent, also not
  later as history; with answers off the local guide gets no screen or
  history. No keys, dictated text, notes, settings, cookies or an identifier
  of this Mac (ephemeral URLSession). Redirects are refused, so the request
  never leaves the endpoint; a 3xx reads as unavailable.
- **What comes back** is checked twice: the server sends only ids from the
  app's catalog, and the app drops any it does not know. He opens the place
  through the same Settings calls as step 1.
- **Failures are said plainly and change nothing:** no internet or a timeout
  is offline ("I can't reach whytap.ai"), 429 or a spent budget is the daily
  limit, any other error is unavailable. Each offers the closest pages the
  local guide finds; offline and unavailable also offer Try again, which
  replaces the failed turn.
- Documents changed with it: `docs/architecture.md` invariant 1 and the Lil
  Bro paragraph, `docs/privacy.md` routes table, the repository security
  policy, and the
  agent guidance summary.

## Why

- The tester's problem is understanding Settings; a guide that only matches
  names cannot explain. Answers need a model, and the maintainer's key on the
  maintainer's server is the only way to give them to people who have not set
  up a key yet — the very people who need help.
- An explicit switch keeps the old promise true for everyone who does not
  press it, and makes the new route visible where it happens.
- The site's Ask already has budgets, per-address limits with keyed hashes,
  a 90-day question log without addresses, and the guide; reusing it keeps one
  privacy story.
- Closest pages on failure keep Settings usable offline, which is how the
  approved mockup behaves.

## What was tested

- `LilBroRemoteBrainTests`: the request goes only to the endpoint, has only
  question/screen/history, no cookies or Authorization; long questions are
  cut, very short ones stay local; feature, tab and keys answers; unknown
  places dropped; off-topic opens nothing; 429, budget, busy, 400, 502, bad
  JSON, empty text, no internet and timeout each read as limit, unavailable
  or offline; only `LilBroRemoteBrain.swift` calls a whytap.ai API.
- `LilBroControllerTests`: nothing is asked before answers are turned on;
  once on, the question carries the screen and earlier answers and he opens
  the place named; turning off goes back to the Mac; offline is sad and
  changes nothing, Try again replaces the turn; when whytap.ai cannot answer
  he still opens the closest page.
- Offscreen renders of the offer and the offline balloon.
- After the builder's review of the step-2 PR (ticket 604): the menu only
  shows the disclosure and only its button turns answers on; local turns stay
  out of history on the first opt-in and after off/on; mixed emoji questions
  and long earlier turns are cut to the server's scalar limits; the redirect
  delegate refuses any redirect. After ticket 606: the disclosure names the
  earlier questions and answers that are sent again and kept; after an
  unknown reply the menu's disclosure also has Not now (one placement rule,
  `LilBroOffer.placement`, tested in every state); normalisation matches
  `clean_question` on U+001C–U+001F, combining marks after spaces and a
  dropped long cluster.
- Not tested: a real call to whytap.ai (the endpoint is not deployed yet).

## Rejected

- Turning answers on by default, or asking on first launch: the invariant
  would change for people who never open Lil Bro.
- The user's own provider key for his answers: most people asking for help
  have not set one up yet.
- Sending the person's settings or feature states for better answers: more
  data leaves the Mac than a question needs; the screen id is enough.
- Falling back to the local guide silently when whytap.ai fails: the person
  would not know why answers got worse.

2026-11-24 · step 2 PR: feature/lil-bro-answers
2026-11-26 · REV 4 (one-line disclosure, Sonnet): feature/lil-bro-smooth
2026-11-26 · REV 7 (only the card when not understood): feature/lil-bro-unknown
