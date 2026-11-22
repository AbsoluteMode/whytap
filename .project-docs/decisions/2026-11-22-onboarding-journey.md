---
id: onboarding-journey-2026-11-22
type: decision
title: The first-launch onboarding becomes a small window of single steps that move on by themselves
summary: The five-page onboarding is replaced by one small window with a progress bar and up to fourteen single-purpose steps (speech source, speech key, optional language model, optional search, language, one screen per permission, Try Drop, shortcuts, Toolbox, help, thanks); a step whose action succeeds moves on after a short beat, steps done before the window opened are left out, Back keeps everything, and speech and the language model are set through the shared Speech and LLM rows.
status: confirmed
tags: [onboarding, first-launch, permissions, models, routing]
canonical_for: [onboarding-journey]
verified_at: 2026-11-22
sources:
  - type: user-confirmed
    reference: On 2026-11-22, after seeing three onboarding concepts, the maintainer described the flow through the orchestrating session - the user chooses local or API speech; with API they enter keys and choose an LLM plus a transcription model, or only transcription; the screen moves on by itself after a successful action, without Continue, in a small window with Back and a progress bar; the steps are local/API cards, transcription key, LLM key, search key for the Agent, language, permissions one by one (keyboard, then the rest), Screen Recording, Try Drop, a short tour of shortcuts and the Toolbox, a pointer to the whytap.ai agent for questions, and a thank-you. It must look and feel premium, with no AI-like animations. He also confirmed ("yes, for all speech") that the local model goes on every speech feature.
    confirmed_at: 2026-11-22
  - type: repository
    reference: Sources/Sidekey/Onboarding/OnboardingJourney.swift
    confirmed_at: 2026-11-22
  - type: repository
    reference: Sources/Sidekey/Onboarding/OnboardingJourneyModel.swift
    confirmed_at: 2026-11-22
  - type: repository
    reference: Tests/SidekeyTests/OnboardingJourneyModelTests.swift
    confirmed_at: 2026-11-22
related: [2026-11-21-first-launch-onboarding.md]
---

# The first-launch onboarding becomes a small window of single steps that move on by themselves

## Context

The first-launch onboarding (2026-11-21) had five large pages, several
decisions on one page and a Continue button on each. On build 1701 the
maintainer could not tell where to go next on the speech page, and after
three concepts he described a different shape: one decision or action per
screen, the screen moving on by itself when the action succeeds, a small
window, Back and a progress bar.

## Decision

- **One small window** (560 × 460 pt) with a progress bar, the step's name
  and "N / M" on top, one step in the middle and a footer with Back on the
  left. The final visual design and motion come from a separate design pass;
  the model does not depend on them.
- **Steps, in their only order** (`OnboardingStep`):
  1. Source: On this Mac or Your key (two cards).
  2. Speech key: Soniox, Deepgram or ElevenLabs.
  3. Language model key (optional): Anthropic, OpenAI or OpenRouter, with a
     preselected model.
  4. Search for the Agent (optional; only when a language model is set).
  5. Language.
  6. Keyboard control (Accessibility).
  7. Microphone.
  8. Input Monitoring, only when the Drop shortcut reports it needs it.
  9. Screen Recording (optional).
  10. Try Drop (only when speech is on the way).
  11. Shortcuts. 12. Toolbox. 13. Help on whytap.ai. 14. Thank you.
- **Moving on by itself.** A step moves on after a 0.9 s beat that shows
  the success when its action succeeds while it is shown: a key accepted and
  applied, a permission turning granted, a dictation inserted, a language
  picked, a source chosen. Arriving at a step that is already done is not a
  success, so Back to a finished step stays there. Back during the beat
  cancels the move. Only the informational steps (11–14) have Next or Done.
  Required steps have a quiet "Set up later", optional ones "Skip".
- **Done before means not shown.** Steps whose result already holds when the
  window opens (speech runs, an LLM is set, a Tavily key is saved, the
  language is chosen, a permission is granted) are left out; choices remove
  the steps they make unnecessary (On this Mac removes the speech key step;
  no language model removes search). A Drop press that finds a permission
  missing brings the permission steps back.
- **Speech and the LLM go through the shared rows.** A speech key, or On this
  Mac, is applied with `APIAndModelsViewModel.selectShared(kind: .speech)`;
  a language model key with `selectShared(kind: .llm)`, so one pick covers
  every feature of its kind it can serve (Meetings gets the recorded
  counterpart) and a feature it cannot serve keeps its route and is named in
  one line. Existing custom per-feature choices are kept. Local speech goes
  on every speech feature, as the maintainer confirmed.
- **The latest choice wins.** As on the 2026-11-21 speech page, every speech
  or language model action takes a new number; a key check, model check or
  download that answers after a newer action of its kind changes no route and
  moves nothing, and a late key save keeps only the key.
- **LLM preselection:** the Agent's registry model when there is one
  (Anthropic `claude-sonnet-5-5`, OpenRouter `anthropic/claude-sonnet-5.5`);
  OpenAI has none, so the newest model in its live catalog that the Agent
  can use (the catalog loads when the key is saved).
- **Permissions, one per screen**, from what the code actually needs:
  Accessibility gates the Space-hold event tap, the Right Command gesture,
  the focused-field check and Escape; the microphone gates Drop, Agent voice
  and meetings; Input Monitoring is only the tap's fallback; Post Event has
  no separate pane on current macOS and the paste engine no longer gates on
  it; System Audio Recording and Automation stay asked at first use.
- **Search, step 4.** Anthropic (Messages `web_search` server tool), OpenAI
  (Responses `web_search`) and OpenRouter (`openrouter:web_search`) each have
  built-in search at about $10 per 1,000 searches plus result tokens, so a
  user with one of those keys could search without a Tavily key. The native
  Agent cannot use it yet: it would have to round-trip server-tool blocks,
  handle `pause_turn` and mixed search/tool turns, and carry citations into
  `finish_answer.sources`. Until a separate Agent change does that, step 4
  offers a Tavily key; afterwards it offers "your model's built-in search"
  first.

## Rejected

- Keeping Continue on every step: the maintainer asked for screens that move
  on by themselves.
- Moving on whenever a step is already done, including after Back: Back
  would bounce forward and could not be used to look at or change a choice.
- A separate per-feature speech or LLM choice in the onboarding: the shared
  rows already do one pick for all, and Advanced in Settings keeps custom
  models.
- A Post Event screen: no separate System Settings pane on current macOS.
- Asking for System Audio Recording and Automation in the onboarding: they
  are only needed by Meetings and Now Playing and are asked at first use.

## What was tested

- `OnboardingJourneyTests`: which steps a clean Mac, a local choice, a key
  choice, a Mac without local speech, an LLM, a missing permission and a Mac
  where everything is done see; Next and Back walk the same list; a step a
  choice removed continues from its place; the bar runs from empty to full;
  a success moves once, Back cancels it, another step's success does not.
- `OnboardingJourneyModelTests` with temporary stores, in-memory keys and
  offline key/model checks: a speech key sets all five speech features
  (Meetings on the recorded model) and moves on after the beat; a refused key
  stays with the reason and sets nothing; a saved key is reused; an LLM key
  sets all four text features and brings the search step; skipping the LLM
  skips search; OpenAI preselects its newest usable catalog model; On this
  Mac with and without the model here; permissions granted while shown move
  on, granted elsewhere do not; Input Monitoring only when the shortcut needs
  it; informational steps end with Done; an earlier speech key whose check
  finishes last does not replace the later choice.
- Offscreen renders of every step of the frame.

Not verified: the real window with real permissions, real provider key
checks and the final visual design.

2026-11-22 · branch `feature/onboarding-v2`
