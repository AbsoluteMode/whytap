---
id: input-language-suggestion-2026-11-20
type: decision
title: Offer the input language after three Auto dictations
summary: With the input language on Auto, three consecutive Drop takes in one language produce a single notification card offering to set that language; clicking it sets it, ignoring it keeps Auto and the language is not offered again.
status: confirmed
tags: [drop, language, notifications, elevenlabs, privacy]
canonical_for: [input-language-suggestion]
verified_at: 2026-11-20
sources:
  - type: user-confirmed
    reference: On 2026-11-20 the user reported a person who installed Whytap that day and got Russian fillers and false starts (drawn-out "a-a-a", "e-e-e", a cut-off first letter) in every ElevenLabs dictation; setting the input language to Russian fixed it. The user asked for the language to be set automatically once the user accepts it, and chose the offer after a few dictations over using the keyboard layout or the system language.
    confirmed_at: 2026-11-20
  - type: repository
    reference: Sources/Sidekey/Privacy/InputLanguageSuggestion.swift
    confirmed_at: 2026-11-20
  - type: repository
    reference: Tests/SidekeyTests/InputLanguageSuggestionTests.swift
    confirmed_at: 2026-11-20
related: [2026-10-20-meeting-ready-notifications.md, 2026-10-20-notification-cards-and-sounds.md]
---

## Context

A new install has the input language on Auto: no language is sent to the
speech provider, which guesses it for every take. On ElevenLabs that left
Russian fillers and false starts in the text although `no_verbatim` was sent;
with the language set to Russian the same key and model returned clean text.
New users do not know the setting matters.

## Decision

- `InputLanguageSuggestion` counts delivered Drop takes while the input
  language is Auto. The language of the provider's transcript is read on this
  Mac by `NLLanguageRecognizer`; a take with fewer than 20 letters or a
  confidence under 0.85 is ignored and does not break the count.
- Three consecutive takes in one language of the menu produce one notification
  card: "Dictating in Russian?" / "Click to set Russian as the input language.
  Auto stays if you don't." A different language restarts the count.
- Clicking the card sets the input language, only while it is still Auto, so
  a card clicked later from Notify history never replaces a choice. Ignoring
  it changes nothing, and that language is never offered again; another
  language can be offered once later.
- The card's action is an internal field of the app's own event
  (`inputLanguageCode`), like the meeting card's `meetingID`: script output
  and links cannot supply it.
- Stored: the current streak's language code and count, and the codes already
  offered. The dictated text is not kept by this feature and nothing is sent
  anywhere.

## Why

The setting changes what the provider returns, and only the user knows which
language they speak. An offer with one click fixes the new-user case without
the app choosing for anyone; a wrong guess costs one ignored card.

## What was checked

- 13 tests: the three-take rule, a chosen language is never counted or
  second-guessed, mixed languages never trigger, unclear takes are ignored,
  only the code and count are stored, the card's copy and action, scripts
  cannot supply the action, old history still decodes.
- The effect of a set language on ElevenLabs cleanup is the user's own
  observation on 2026-11-20, not measured here.
- Not checked in a running app: the card's appearance and the click.

## Rejected

- Send the keyboard layout's language in Auto: developers type on an English
  layout and speak another language; a wrong hint is worse than Auto.
- Preselect the system language on first launch: the same mismatch.
- Set the language without asking: a silent change of what is sent to the
  provider.
- A modal question after a take: it would take focus from the field the text
  was just pasted into.

2026-11-20.
