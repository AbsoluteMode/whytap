---
id: onboarding-journey-2026-11-22
type: decision
title: The first-launch onboarding becomes a small window of single steps that move on by themselves
summary: The five-page onboarding is replaced by one small window with a progress bar and up to twelve single-purpose steps (speech source, speech key, optional language model, web search only after a self-hosted model, language, one screen per permission, Try Drop, Toolbox, and a closing step that points questions to whytap.ai); a step whose action succeeds moves on after a short beat, steps done before the window opened are left out, Back keeps everything, and speech and the language model are set through the shared Speech and LLM rows.
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
  - type: repository
    reference: Sources/Sidekey/Onboarding/OnboardingDwell.swift
    confirmed_at: 2026-11-22
  - type: repository
    reference: Sources/Sidekey/Onboarding/OnboardingJourneyComponents.swift
    confirmed_at: 2026-11-22
  - type: repository
    reference: Sources/OnboardingPreviewKit/OnboardingPreview.swift
    confirmed_at: 2026-11-22
  - type: repository
    reference: Sources/Sidekey/Onboarding/OnboardingWireframe.swift
    confirmed_at: 2026-11-22
  - type: repository
    reference: Sources/Sidekey/Onboarding/OnboardingServerForm.swift
    confirmed_at: 2026-11-22
  - type: user-confirmed
    reference: On 2026-11-22 the maintainer accepted the onboarding screens in the standalone preview at commit 6d9f196c and asked to go on.
    confirmed_at: 2026-11-22
  - type: user-confirmed
    reference: On 2026-11-22 the maintainer asked, through the orchestrating session, to run the onboarding on its own, outside Whytap, and see all of it after every change.
    confirmed_at: 2026-11-22
  - type: user-confirmed
    reference: On 2026-11-22 the orchestrating session passed on a visual and motion pass by a separate design agent (Gemini 4 Carbon) as the base for the frame, not yet approved by the maintainer, with the instruction to move its components into the onboarding code and to check every text against what is true for all providers.
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

- **One small window** (520 × 440 pt): a fixed 32 × 24 pt Back slot, the
  progress rail and "NN / 10" on top ("NN / 11" with the search step); the act, a serif title and one line
  under it; the step's stage; a footer with Skip or Set up later on the left
  and Next on the right only when nothing moves on by itself. Back also answers ← and ⌘[ outside text
  fields. The visual and motion come from the design pass (dark raised
  cards with a 1 pt top highlight, recessed key fields, near-critically
  damped springs, nothing moving at rest, opacity only under Reduce Motion).
- **Progress rail:** one equal micro-segment per step, a wider gap between
  the four acts (Engine, Access, Try Drop, Island). Done steps are green,
  the current one fills during the dwell and turns amber while held; a step
  skipped or made unnecessary is hollow, never a false "done". A passed
  step reached again by Back stays green and is only lit (a soft glow and a
  light rim), never reset to white "in progress"; the owner asked for that
  on 2026-11-22 (`OnboardingSegmentState.revisited`). The gaps between acts
  stay.
- **Steps, in their only order** (`OnboardingStep`):
  1. Source: On this Mac or Your key (two cards).
  2. Speech key: Soniox, Deepgram or ElevenLabs.
  3. Language model key (optional): Anthropic, OpenAI or OpenRouter, with a
     preselected model.
  4. Web search for the Agent (optional; only after a Self-hosted language
     model, see "Web search: a step only after Self-hosted").
  5. Language: the wireframe globe (see "The language step is a globe").
  6. Keyboard control (Accessibility).
  7. Microphone.
  8. Input Monitoring, only when the Drop shortcut reports it needs it.
  9. Screen Recording (optional).
  10. Try Drop (only when speech is on the way).
  11. Toolbox. 12. Enjoy Whytap: questions to whytap.ai, Finish (REV 61;
  it was two steps, Help and Thank you). Shortcuts was removed in REV 64.
- **Moving on by itself, with no chip.** When a shown step's action
  succeeds (a key accepted and applied, a permission turning granted, a
  dictation inserted, a language picked, a source chosen) its segment fills
  for the step's dwell (0.62 s for a choice, 0.78 s for a verified key or
  grant, 1.15 s on the speech key so the padlock opens and settles first,
  1.35 s after Try Drop; Reduce Motion adds 0.22 s), then the step moves on
  with its animation. The owner removed every footer chip on 2026-11-22
  ("Next: …", "Paused · Stay as long as you need", "Continue · …"): Return
  still goes on at once without one. With no visible hold, the pointer no
  longer holds the move (a pointer resting on the page would have stopped
  it silently). Back to a step that is done, or to a tour step, never moves
  by itself and offers the plain Next; Back during the dwell cancels it.
  The tour steps (Shortcuts, Toolbox, Help) and Finish have no timer since
  REV 60: they wait for Continue or Return. Required steps keep a quiet "Set up later",
  optional ones "Skip"; a step that is done without a pending move offers
  Next. Step 1 has neither: its two figures are the choice (the owner asked
  to remove its skip).
  Step 1 is the exception (the owner asked to remove the pill, 2026-11-22): a
  click on a figure, or Return on the figure in front, is its Continue, with
  no pill and no Next, also after Back. It is not an instant cut either (the
  owner's clarification the same day): the click's own motion plays for
  0.34 s (the key turns a quarter and dips), then the chosen key flies on to
  step 2 while the page dissolves under it (the old page leaves in about
  0.2 s, the new one settles 0.1 s later), and Back flies it home the same
  way. A second choice during that beat wins.
- **The page fills the whole window.** The window's content runs under its
  transparent title bar; inside the safe area the fixed 520×440 page was
  centred and its footer ran about 14 pt past the bottom edge on every step,
  so the page ignores the safe area and the header keeps its place with a
  24 pt top inset.
- **Done before means not shown.** Steps whose result already holds when the
  window opens (speech runs, an LLM is set, the
  language is chosen, a permission is granted) are left out; choices remove
  the steps they make unnecessary (On this Mac removes the speech key step). A Drop press that finds a permission
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
  `finish_answer.sources`. That is a separate Agent change (session 78).
  Superseded on 2026-11-22 (below, "Web search: a step only after
  Self-hosted").

- **Texts only say what holds for every provider** (corrections to the
  design pass): the API card does not promise free credit (Soniox has no
  free offer; Anthropic and OpenAI credits come with paid plans), so each
  provider tab shows its own offer from API hints or nothing; no latency
  claims for the local model, only "Free. Works offline." and its size; shortcuts, the Agent's state and the
  Toolbox tiles come from the person's own HotkeyConfiguration, Agent switch
  and saved layout; the help example is a real answer (Settings → Hotkeys →
  Tools); nothing simulates dictation with the mouse in the app, Try Drop
  uses the real field and shortcut.

- **OpenAI speech, once the app runs it.** The maintainer brought OpenAI
  back as a speech provider (task #73, `gpt-4o-transcribe` and
  `gpt-4o-mini-transcribe`). The speech key step offers OpenAI as a fourth
  tab as soon as the registry names an OpenAI Drop model
  (`OnboardingJourneyModel.offersOpenAISpeech`), with no separate switch.
  One OpenAI key serves both steps: a key saved on one of them opens the
  other on OpenAI with "Use saved", never asking for it again.
- **A standalone preview** (`scripts/onboarding-preview.sh`, executable
  target `OnboardingPreview`, never packaged) opens the whole onboarding from
  step 1 in the same window and model, outside Whytap: its own defaults
  suite emptied on start and quit, keys in memory, offline key checks,
  catalogs and server model checks (a key containing "bad" is refused), Allow that
  only pretends macOS granted it, a timer for the speech model download and,
  on Try Drop, a capsule held to stand in for the Drop key (a short tap
  brings nothing, a longer hold types a sample sentence). It starts no hotkeys, event taps, stores or island
  and never touches `com.rootwise.sidekey`, the Keychain or the network.
  It is not a Whytap instance (no bundle, shared stores, hotkeys or taps),
  so the one-running-copy rule does not cover it: the session that changed
  the onboarding opens it for the maintainer after each change.
- **Steps 1 and 2 in the wireframe language (draft, from the design pass):**
  a laptop and a key drawn as depth-sorted wire solids on a softly lit
  ground. Hover brings a figure forward; the other recedes, dimmer and
  without its caption. Step 2 is "Paste your speech key.": a dark pill
  field with the whole key masked, the speech providers only (with
  their logos from `UsefulLinkIcons`), the provider's real offer, and a
  "Self-hosted" mark for your own server (see below). Only a key's own format picks
  the provider (see "Only a key's own format names its provider"). A refusal names one of five causes
  without blame: the key's shape (checked before any request), a refused
  key, an empty balance, a key without speech access, or no answer (with
  Retry); the key check has no separate rate-limit answer. The wire key
  turns in its lock when accepted and catches on a pin when refused. The
  footer has no chip at all (see "Moving on by itself, with no chip").
- **The wire figures move per display frame, not by SwiftUI animation.**
  Values a `Canvas` captures are not interpolated by `.animation`, so the
  first draft jumped between poses, and it drew at 30 fps. The stages now
  step the prototype's own damped springs (pose 135/19.5, fade and light
  150/22, key turn 160/18 on step 1; slide 140/20, turn 175/19 on step 2)
  on `TimelineView(.animation)` at the display's rate, keeping velocity
  when the hover target changes, with its pointer spin, hover tilt, screen
  pulse and checking light. Hover only updates the motion object, so no
  SwiftUI state or layout changes on pointer moves; captions are drawn in
  the same canvas. Reduce Motion snaps to the target and draws at 30 fps.
- **One key across steps 1 and 2.** The figures of both steps are one scene
  (`OnboardingWireScene`) drawn by one canvas above the page, so the key
  chosen on step 1 turns and flies to its lock on step 2 (and back on Back)
  on the same springs; only the steps' text and controls take the ordinary
  step transition. Two drawings with a cross-fade made the key jump, vanish
  and reappear. The steps report only their bands' vertical place (the step
  slide is sideways), and step 1's captions fade in the first third of the
  flight.
- **The design pass's padlock and light (delivered 2026-11-22).** Step 2
  uses its meshes and springs one to one: a chamfered padlock body with the
  keyhole toward the key and a tubular shackle; the key slides along the
  keyway (insertion 150/19: resting outside, a little in when pasted, seated
  while checking, short of the hole for a malformed key) and turns 185/18.
  Accepted: a quarter turn, then the shackle lifts (230/14.5) and swings
  open (180/14) with a small kick of the body. Refused: the key tries to
  turn (0.36 rad, 0.46 for credit or access), the padlock shudders and the
  key eases back. No answer: the lock dims and three dots fade toward it.
  The light is on the wires, not behind them: facets catching a grazing
  light turn rose-pearl on hover (step 1), and on step 2 a light from the
  field below goes rose, green when accepted and amber on a problem; the
  only glow is a faint dithered blush under the field, so nothing bands.
  The key and padlock use that prototype's ink (line width from the
  figure's size, full-strength dots in the vertices) and breathe slowly in
  depth and yaw, like the key on step 1.
- **The key field is a secure field.** Every input (Latin, Cyrillic,
  digits, symbols, the Russian layout's "№") is dots from its first
  character, with no visible start or end. A wrong format is named only by
  the error text on Return; the input never shows. The owner asked for the
  whole key closed, then saw a 17-character string and then a Russian
  layout's digits and symbols in clear, so no input is an exception. The
  mask keeps the length in the monospaced font (Cyrillic and "№" have the
  same advance as a dot), so the caret never moves. A native secure field
  was not used: it turns on Secure Event Input, which blocks Drop's own
  keyboard tap while focused.
- **Only a key's own format names its provider.** A real prefix, the
  longest that matches across every provider Whytap knows ("sk-ant-"
  Anthropic, "sk-or-" OpenRouter, "sk-proj-"/"sk-" OpenAI, "sk_"
  ElevenLabs), or Deepgram's 40 hexadecimal characters, and at least 20
  key characters. The owner saw a random string get the OpenAI mark, a
  green check and "check it with OpenAI": the step had fallen back to the
  last provider and kept an earlier acceptance while a new key was typed.
  Now nothing is guessed: an unrecognised key leaves the marks at rest, is
  not checked on paste, and Return calls it a format problem ("pick its
  provider below"). A mark the person clicks still names the provider
  (Soniox keys have no format of their own). A new key in the field is a
  new attempt: an earlier refusal clears, and an earlier acceptance no
  longer shows its check.
- **Step 2's layout follows the design pass.** One centred axis: title, the
  key over its lock, the field ("Paste your API key…"), one quiet line under
  it (empty at rest), four monochrome provider marks of one optical height
  with no preselected one (a mark shows its name on hover, when picked, or
  when the key is recognised: ElevenLabs and OpenAI by prefix, Deepgram by
  40 hexadecimal characters) and, last in the row, "Self-hosted". A
  picked mark offers "Need a … key? Get one" with the provider's real offer.
  "Set up later" stays in the footer like on every step, aligned with the
  field's edge. The standalone preview already shows OpenAI as the fourth
  provider; the app keeps it behind the registry until OpenAI speech lands.
- **The language model step is the same screen.** "Paste a language model
  key." uses the speech step's layout, key, padlock, mask, problems and
  dwell (1.15 s, so the lock opens before the move), with Anthropic, OpenAI
  and OpenRouter marks; a recognised key names the model it will set. The
  lock closes again when the step opens (the key withdraws), and the page
  flows under the key like step 1 into step 2. "Skip" stays in the footer.
- **The model is the person's choice, from the provider's current list.**
  The owner asked what the preset "gpt-5.6" was: a fixed name in the
  preview's fake catalog, while the app took OpenAI's newest catalog model
  and Anthropic's registry model. Now an accepted key starts on the
  provider's newest flagship from its own catalog: the newest generation
  (within 30 days of the newest text model) and in it the highest output
  price when OpenRouter's cached list prices are known (OpenAI
  `gpt-6.2-astra`, Anthropic `claude-fable-5-2` on 2026-11-22), otherwise the
  newest; small tiers, voice, search and dated snapshots are never the
  default. The registry is used only before the catalog exists. Under the
  accepted line a quiet "Choose model ⌄" (the owner: "after the key, Choose
  model, and there the Recommended tag"; no model name or price at rest)
  opens a small dark list of up to eight current models with prices
  (OpenRouter: each major author's flagship), the recommended one first and
  tagged (OpenRouter: `anthropic/claude-sonnet-5.5`). The owner read a cut
  "claude-son…" and asked how to read it, so each row shows a readable name
  that is never cut ("Claude Sonnet 5.5", "GPT-6.2 Sol",
  `OnboardingModelPick.readableName`), the ID small under it, a small
  "Recommended" tag beside the name, and the list is as wide as its longest
  row. The button says "Choose model ⌄" until the person picks a model (the
  recommended one included) and then names it, without a price; the owner
  asked why it still said "Choose model" after a pick. The list checks a
  model only after the person picks one (the owner asked why a checkmark
  was already there: "the checkmark after the choice"); before that the
  recommended model is only tagged, closing the list changes nothing, and
  Next keeps the recommended model. The recommended
  model is already set, and a step with a choice of models does not move on
  by itself: the owner was moved on before he could choose (2026-11-22). It
  waits, after the padlock opens, for a pick (through the shared row, then
  the move) or Next, which keeps the recommended model. Only the
  language model step offers a model (REV 54): the owner saw "Choose
  model" on the speech step with OpenAI and said there is only one model
  there; a speech key sets the one model Settings -> Speech uses for its
  provider (`ModelRegistry.recommended(for: .dropFast)`, OpenAI
  `gpt-live-transcribe`) and the step moves on by itself, with no list, no
  search and no wait; a pick never reaches the speech row. A native
  menu was not used: AppKit draws only one text of its label.
- **One model is recommended: the provider's current Sonnet or Sol.** The
  owner asked on 2026-11-22 for "Sonnet / Sol, the current one" as the
  onboarding's recommendation, replaceable by the person. The language model
  step therefore starts on the newest member of the provider's balanced
  family in its current catalog, chosen by name in one place
  (`OnboardingModelPick.recommended`): Anthropic `claude-sonnet-*`, OpenAI
  `gpt-*-sol`, OpenRouter `anthropic/claude-sonnet-*`. On 2026-11-22 that is
  `claude-sonnet-5-5` and `gpt-6.2-sol` (OpenAI's live /v1/models list, as
  cached by the app, lists `gpt-6.2-sol`, `gpt-6.1-sol` and `gpt-6-sol`). A
  family, not an ID, so a newer Sonnet or Sol takes over without a code
  change; a provider without that family falls back to the newest flagship.
  The list tags it "Recommended"; any other pick replaces it. The speech
  step recommends the registry's Drop model.
- **Web search: a step only after Self-hosted.** First (REV 32) the step
  was left out when the language model searched the web itself; then the
  owner dropped it for everyone (search is set in Settings -> API & Models,
  the Search row of session 78, and Tavily stays in API keys). Seeing that a
  Self-hosted language model led nowhere he brought it back for that case
  only ("I forgot about self-hosted"): a server has no web search of its
  own. So the Tavily step and its rail segment appear only when the
  language model runs on the person's own server (Self-hosted on step 3, or
  set so before the window opened) and no Tavily key is saved; Back and a
  provider's key take the step away again. The step is the key steps'
  screen: "Paste a Tavily key.", the wire key and padlock, dots from the
  first character, a monochrome Tavily mark, no chips, the same dwell and
  flow, "Optional · the Agent searches the web with it" and Skip. A key
  without Tavily's `tvly-` prefix is a format problem; Tavily's answers name
  the other four: 401 or 403 refused, 432 or 433 (plan and pay-as-you-go
  limits) no credit, 429 busy with Retry, no answer unreachable with Retry.
- **Your own server is a mark in the row and changes the step in place.**
  The owner asked on 2026-11-22 for the quiet "Use your own server →" link
  to become a card like the providers, captioned "Self-hosted": the row ends
  with a monochrome server mark of the marks' optical height, named on
  hover and while its fields are shown (on the speech step after Soniox,
  Deepgram, ElevenLabs and OpenAI; on the language model step after
  Anthropic, OpenAI and OpenRouter). The owner,
  2026-11-22: a separate screen (first a form over the window, in the app
  Settings) and a return to the key step before the move looked cobbled
  together. Now, in the app and the preview alike, the key field's capsule
  reshapes into the first of three fields of the same family (Base URL, an
  optional key, one model) and the other two unfold from it. The step says
  what the model is for, with no switch (the owner: self-hosted
  transcription on the speech step, an LLM on the language model step): a
  transcription model such as `whisper-large-v3-turbo` on speech, an LLM such
  as `qwen3:8b` on the language model step. A server added on one of them
  comes back filled in (address and key) on the other and is added once,
  with both models; the title reads "Your own server.", the wire key and
  padlock stay, the row stays under the fields with Self-hosted selected.
  A provider mark (or Escape, or Back) folds them into the key field again. Return on the model adds the server the way Settings
  does (`addServer`: the address answers, the key if any is accepted), runs
  the model's small check (`runServerModelCheck`), adds it and sets the
  shared Speech or LLM row; the padlock answers like for a key and success
  moves straight on to the next step, the fields still in place. A second
  try with the same address and key reuses the server. The name comes from
  the address (Ollama and LM Studio by their default ports, otherwise the
  host). The Settings path of the first version
  (`SettingsWindowSelection.requestNewServer`) was removed with it, so this
  branch no longer touches the Custom server tile of PR 408.
- **The preview's fakes are outside the app.** The owner asked that the
  real catalog fill "Choose model" when the app is built. In the app the
  list always comes from the provider's catalog through the same
  `APIAndModelsViewModel` as Settings -> Models (prices from the same
  catalogs); the preview's fake providers, catalogs, key checks, permissions
  and URL protocol moved out of the app's module into `OnboardingPreviewKit`
  (Sources/OnboardingPreviewKit), which only the OnboardingPreview
  executable and the tests link, so a Whytap build cannot contain them.
- **The access steps follow the design pass's screen 04.** The owner,
  REV 57: "the access steps are fine, put them to work". Keyboard control,
  Microphone, Input Monitoring and Screen Recording share one template, each
  with its own wire figure in the key, padlock and globe family: a Command
  keycap on its switch stem (its glyph drawn as continuous strokes whose
  loops meet the square's sides, sharper than the prototype's), a
  microphone capsule, an aperture, a display with viewfinder corners. Rest:
  the title, one purpose line and Allow. Waiting: where to turn Whytap on
  and the pane's path, a quiet Open System Settings, no spinner. Allowed:
  the figure plays (the cap presses and a caret rises, the capsule stands
  up, the aperture opens, the corners close on the window) and the step
  flows on after 1.05 s, the prototype's beat, with no chip. Not on yet: a
  return to the app with the switch still off shows one calm amber line and
  Allow again, with no shake and no red; it is not shown while macOS's own
  microphone dialog is open, and a step reached again starts at Allow. Only
  the system's check grants a step, as before. The progress rail and the
  step count stay the app's. Screen Recording, the one optional step, has
  Skip for now under Allow, so the footer shows no second Skip there.
- **The last five steps follow the design pass's screens 05 to 09.** The
  owner, REV 58: "great", after asking to remove the island and turn the
  dividing line into waves while speaking, and to remove the summary table
  and keep only a line that we hope they will like Whytap. Try Drop: the
  title and lede, a thin line, a wire key with the legend of the person's
  own Drop key, the real text field with the shortcut as keys, one line and
  a capsule. No island or Listening chip: while Drop records, the line
  turns into soft coloured waves that follow the voice level
  (AppState.audioLevels) and straightens when the take ends. The capsule
  is a status in the app (the take starts with the key itself, never with
  the mouse) and Continue once the text arrived. A take that ends with
  nothing in the field says so in one calm line after a short quiet: "No
  speech heard - try again." when it never reached the insert, a line that
  the text went to another field when it did, and one for Drop's own
  delivery failure; a new take clears it (OnboardingVoiceSignal follows
  AppState.phase). Shortcuts: three wire keys over the person's shortcuts
  in two columns (Drop, the Agent marked Off while it is off, then the tools
  that have a shortcut, six at most); a row's modifier keys go down while
  the pointer is on it. Toolbox (REV 60) and the last step (REV 61): see
  below; the receipt table is gone. Each of these steps has
  its own capsule, so the footer adds no Next or Skip there.
- **Steps without an action wait for Continue; Toolbox is a ring.** The
  owner, REV 60, after testing the preview: remove the timers, the screens
  without an action (Shortcuts, Toolbox, whytap.ai) must not move on by
  themselves, only by Continue or Return, and their progress segment must
  not fill over time; the short pause after a success on a step with an
  action stays, so the padlock or key finishes its animation. A tour step
  that leaves while the person is still reading loses what it was showing.
  For Toolbox he asked to drop the display frame and put every Toolbox tool
  (the app's whole catalog, not six) on a circle with a card in the middle:
  "Toolbox", the tool under the pointer and its short description, or a
  general line when nothing is hovered; hovering a tile lights it and
  changes the card. The ring holds the catalog Settings → Toolbox lists
  (every tool but Settings, which is always on the island; a tool not out
  yet is dimmed and its card says so), not the person's own layout, which
  that subtitle sends them to choose. Nineteen tiles do not fit a true
  circle in the 520 by 440 window without touching, so the circle is drawn
  tilted toward the person: about twice as wide as tall, the near tiles a
  little larger, tiles at equal steps along the ring (equal angles crowd
  its narrow ends). A thin rose spoke joins the card to the lit tile; the
  keyboard focus lights a tile like the pointer.
- **whytap.ai and Finish are one last step.** The owner, REV 61, about the
  last screen: remove it as a full page or merge it with the whytap.ai
  step, something like "enjoy, and if you have questions write on the
  landing"; the orchestrating session chose the merge. The last step is
  "Enjoy Whytap." with "We hope you'll love having it on your Mac.", the
  constellation of the earlier figures (key, open padlock, globe, Command
  key), one Ask capsule "Questions? Ask on whytap.ai" that opens the site
  (OnboardingAskLine), and Finish. The Help step, its four solids and its
  sample question are gone, so the rail has one segment fewer ("NN / 11",
  "NN / 12" with the search step). A page that only points elsewhere was a
  stop with nothing to do; one line on the last screen says the same.
- **Each thing is said once.** The owner, REV 62, on a preview screenshot
  of Try Drop: "we write hold Space four times, do we think the user is
  dumb?" (the field's header, the placeholder, the line under the field and
  the capsule). Try Drop now says which key to hold once, in the field's
  header ("Hold Space and speak"). The placeholder says where the words go
  ("Your words land here"); the line under the field is empty at rest and
  only reports a take (let go to drop it, "No speech heard - try again.",
  "That's Drop - the same shortcut works in any app."); the header's right
  label no longer says "real text field" (the lede does) or "try again".
  REV 63, the owner's exact choices: remove the line under the field
  entirely ("No speech heard - try again." shows inside the empty field, in
  amber); the field says only "Your text will appear here"; the button
  under it is Continue, there from the start and active once a take
  arrived, with Skip beside it. The preview's "Preview take" capsule of REV
  62 is gone. It also had a bug the owner hit: the take started on the
  capsule's drag gesture, the capsule was swapped for another view as the
  take began, the gesture was torn down and its end never came, so the step
  stayed recording; and Space did nothing in the preview, which starts no
  hotkeys. Now the preview listens for the person's own Drop shortcut in
  its window with a local event monitor (OnboardingPreviewDrop in
  OnboardingPreviewKit, behind the app's OnboardingDropStandIn protocol, so
  nothing of it is in the app), whatever has the focus. The owner then saw
  spaces still typed while holding ("with us they are not typed"): a held
  Space or hold combo now runs through Drop's own SpaceHoldDetector with
  SpaceHoldMonitor.mapEvent and tapDecision, so the preview behaves as Drop
  does in the app: a short tap types a space, a hold past the 300 ms
  threshold erases the spaces it printed (Drop's Backspace), records, and
  swallows its auto-repeats and release; a tap shortcut toggles; and a take
  always ends: on release, on
  the window or the app losing focus, after 30 s, and when the step goes
  away. Skip and Back work during a take. The other steps were
  checked the same way: an access step's waiting copy no longer names
  System Settings three times ("Turn on Whytap, then come back here.", the
  pane's path, a "Waiting..." capsule, Open System Settings); its allowed
  line says what now works instead of repeating "allowed" next to the
  Allowed capsule; its not-on-yet line states the fact and leaves the action
  to Allow again; and Shortcuts and Toolbox lost their footer "Open
  Hotkeys" and "Open Toolbox" buttons, since each lede already names its
  Settings tab.
- **No Shortcuts step; Toolbox turns; the last step shows questions.** The
  owner, REV 64, on the Shortcuts screen: "we'll remove this screen"; Try
  Drop now leads straight to Toolbox and the rail has one segment fewer
  ("NN / 10", "NN / 11" with the search step). REV 65, on the Toolbox ring:
  "make the centre smaller, the icon frames bigger, and a carousel that
  turns". The card is 176 by 76 pt with compact text, the tiles 38 pt
  (were 30), the ring as wide as the window allows, and it turns one round
  in 70 s, stepped per display frame (OnboardingCarousel); pointing at or
  focusing a tile stops it, lights the tile and names it on the card, and
  leaving lets it turn on; Reduce Motion and offscreen renders stand still.
  Tests turn the ring through a full tile step at two area heights: tiles
  never touch, never cover the card and never leave the area. REV 66, on
  the last screen: use the middle for a carousel of questions worth asking
  on the landing, a stack that shows example requests on hover. The
  constellation is gone; the list (OnboardingQuestionList) holds eight real questions
  from the Ask agent's eval pool (models to start with, tap instead of
  hold, Russian dictation into English, custom words, Case with Claude
  Code, fully local with Ollama, meeting speakers, the microphone), one
  line each (at most 52 characters). REV 68 replaced the stack: "leave the
  last one just like this and let them change slowly" (the opened list on
  the owner's screenshot, whose fourth row was cut). Four rows are always
  shown (icon, question, arrow) in a fixed 138 pt block above the Ask
  capsule and Finish, so no row is cut or covers them; every 3.2 s one row,
  the rows in turn, fades to a question not on the list, and the pointer
  or focus on the list holds it. A click opens whytap.ai/?q=<question>: the landing's Ask page reads `q`
  and asks it once its scripts are in (site/ask/ask.js in the landing
  repository; /ask/ keeps `?q=` too, and Ask caps a question at 300
  characters). The Ask capsule and Finish stay.
- **"Choose model" searches a large catalog.** The owner, REV 52: "maybe
  just give a search above 10 models". When the accepted provider's catalog
  has more than ten usable models (`OnboardingModelSearch.threshold`), the
  list opens with a search field: an empty field with the glass and the
  caret on the left, as wide as the list, no prompt text (the owner, REV
  56: a narrow field sat centred with its caret mid-row and "Search 18
  models" in it). Without text the list
  is the selection as before (Recommended and the picks; OpenRouter one
  flagship per author); with text it shows matches from the whole catalog
  (`modelCatalog`, OpenRouter's every model) by readable name and ID, words
  in any order, case and dashes ignored, names that start with the text
  first and newest first, scrolling past about eight rows; Return takes the
  first. The panel keeps one form while typing (the owner, REV 68: with
  "sol" on OpenRouter the field narrowed and moved, the results sat with a
  wide left indent and the panel changed size): its width is set once from
  the widest row among the selection and the whole catalog, 280 to 480 pt
  (`OnboardingModelList.panelWidth`), because a width that followed the
  shown rows jumped with each letter and centred narrow results in a wide
  scroll view; results use the rows' grid (checkmark slot, name, ID, price
  at the right); the height follows the rows with a short ease; no match is
  one quiet "No models found" row. Ten or fewer: no field. A model found by search is set like any
  pick; the checkmark, Recommended tag and uncut names stay as before.
- **"Accepted" belongs to the provider or server that answered.** The owner
  saw "Anthropic · dsfadfdas · dafdasfdasf · key saved in your Keychain"
  after adding a server and clicking Anthropic, and asked what happens when
  a person enters one key and then switches. A key step kept one state, so a
  click on another mark only renamed it: the field claimed "OpenAI key
  saved" with no OpenAI key, Self-hosted opened greyed out under
  "<model> · added", and the line glued one provider's name to another's
  model. Now the step remembers the route that holds (`accepted`: a
  provider, the server or Tavily) and whose key or server the latest try
  checked; each mark shows only its own state: its check or refusal,
  "accepted" when it is the route that holds, otherwise "Saved X key ·
  press Return to use it" when its key is in the Keychain or the empty
  field. The Self-hosted fields are always open (they come back as they
  were accepted; an edit is a new try). The route, the model, the
  Self-hosted mark and the Tavily step change only after a new key or
  server passes its check; a refused try leaves the accepted route
  accepted, and coming back to its mark shows it again. "Choose model"
  picks only on the accepted provider, so a pick never reaches a provider
  whose key was not checked here (the old path also kept the pick as the
  next Anthropic check's model). Another mark during the automatic move
  stops it; Next keeps the accepted route. Keys stay in the Keychain:
  switching saves and deletes nothing.
- **The language step is a globe.** The owner asked for the language
  choice in the key steps' visual language, then for a globe where a person
  finds their country and, or by typing, sees it lit; he approved the
  design pass's prototype (screen 03). The step replaces the old list (same
  step, same place in the way): a wireframe globe of country outlines on a
  unit sphere, drawn like the key and the padlock (depth-shaded edges,
  vertex dots, light glancing off the coasts, a slow turn and a breath),
  turned by dragging; a click on a country turns it to the middle and lights
  it; the one field ("Language or country, or click the globe...") turns the
  globe as the text matches a country (English, its own or the Mac's
  language, a few aliases such as UK) or a language (its home country, with
  that language, and the other countries of that language lit softly).
  Under the field: the country's language in its own script and in English, or its
  languages side by side (German, French and Italian for Switzerland, each named in its own language with its code), each a
  choice; "Auto-detect any language" when nothing is lit. Only languages the
  speech route can take are offered: a Deepgram model's own list
  (`DeepgramLanguagePolicy`), otherwise Whytap's dictation menu
  (`AppLanguage.all`, the Soniox realtime set); a language outside it says
  so in one line ("isn't in Whytap's dictation languages yet", or "isn't
  available with Soniox" / "with Deepgram <model>" where that list is the
  route's own), and Auto-detect is offered only where the route has it. No
  checkmark until a language is chosen; then the outline turns green, the
  field's arrow becomes a check and the step moves on by itself. The
  outlines come from `scripts/onboarding_globe_data.py` into
  `OnboardingGlobeCountries.swift`, built from Natural Earth's 1:110m
  admin-0 countries (world-atlas 2.0.2 TopoJSON, public domain, ISC for the
  conversion; `Resources/OnboardingGlobe/`, not shipped, with its license
  note), downloaded with the owner's go-ahead after he found the
  prototype's 79 joined regions too rough: 171 countries, simplified to
  0.8 degree (finer detail is under a pixel at this size), corner dots about
  every 7 degrees (4 on the lit country), no border drawn along the 180th
  meridian where Natural Earth cuts Russia and Fiji, names from the Mac's
  English region names. Language variants
  (English US/UK/AU, Portuguese BR/PT, Spanish ES/MX) show under the
  language with every speech route, as in the prototype (the owner, REV 51:
  "show the variants, it looks good"): the lit country's own variant is
  underlined and taken by Return, a variant under the pointer turns the
  globe to its country, and a click chooses it. The variant is stored beside
  the language (`sidekey.preferences.selectedLanguageVariant`, BCP 47, valid
  only while its language is the selected one, backed up with it); every
  provider still gets the language's ISO 639-1 code. Sending the variant to
  Deepgram is left out of this change.

## Rejected

- Keeping Continue on every step: the maintainer asked for screens that move
  on by themselves.
- Moving on whenever a step is already done, including after Back: Back
  would bounce forward and could not be used to look at or change a choice.
- A separate per-feature speech or LLM choice in the onboarding: the shared
  rows already do one pick for all, and Advanced in Settings keeps custom
  models.
- A permanent Continue next to the automatic move, or any chip that names
  the next step: the owner removed them; Return goes on, Back stops.
- Holding the move while the pointer rests on the page: with no visible
  hold it silently stopped the move; the dwells are long enough to read the
  result instead.
- A Post Event screen: no separate System Settings pane on current macOS.
- Asking for System Audio Recording and Automation in the onboarding: they
  are only needed by Meetings and Now Playing and are asked at first use.

## What was tested

- REV 68: the preview's Space follows Drop's detector (a quick tap types a
  space and records nothing; a hold erases the printed spaces, records,
  swallows repeats and the release, then drops the text; outside a text
  field a hold does nothing), end to end in a real window and in the whole
  onboarding window reached by walking the steps; the last step's list
  changes one row at a time, never shows a question twice and brings every
  question round; offscreen render of the last step with all four rows in
  full above the Ask capsule and Finish.
- REV 64 to 66: the flow goes Try Drop, Toolbox, Enjoy Whytap with ten
  segments by default; Try Drop's key keeps the Drop key's legend; the
  Toolbox ring keeps every tile clear of the others, the card and the area
  edges over a full tile step of its turn, and the carousel turns, holds
  while pointed at, goes on, wraps and stands still under Reduce Motion;
  the question stack has eight distinct one-line questions and each opens
  whytap.ai with it as `q`; end to end, a real window with Try Drop on
  screen gets Space through NSApp.sendEvent while the field holds the
  keyboard, records instead of typing, and drops the text into the field
  on release, and stops listening once the step is gone; offscreen renders
  of Toolbox idle and lit, and of the last step closed and open.

- REV 62 and 63: Try Drop's field says "Your text will appear here" and a
  failed take's line inside the field; the preview's Drop holds Space in
  its window (swallowed, other keys pass, repeats ignored), letting go
  drops the text, a quick tap brings nothing, a tap combo toggles and needs
  its modifiers, losing the window or app focus and the 30 s limit end a
  take, leaving the step ends it with nothing arriving later; Skip and Back
  leave Try Drop while recording; the app's sources name no preview Drop;
  offscreen renders of Try Drop waiting, recording, done and failed, and of
  every access step in each state.

- REV 61: the flow ends Shortcuts, Toolbox, Enjoy Whytap with no Help
  step (eleven segments by default), the last step has no timer and
  finishes, Back from it reaches Toolbox in the preview; offscreen renders
  of the last step alone and in the window ("11 / 11").

- REV 60: Shortcuts, Toolbox and whytap.ai keep the dwell idle and their
  segment empty and wait for Continue however long the person reads, and
  Back to one offers Continue again; the Toolbox ring holds every catalog
  tool but Settings, with a tool not out yet, and nineteen 30-point tiles
  never touch at their tilted sizes in the window; its card names the tool and its
  description or says what Toolbox is; offscreen renders of Toolbox with no
  tool and with Case lit.

- REV 58: on Try Drop a take with nothing in the field says "No speech
  heard", the next take clears it, a take that reached the insert elsewhere
  and Drop's delivery failure each have their own line, and a take that
  arrived records its time; Shortcuts lists Drop and the Agent first, the
  Agent Off while off, only tools with a shortcut, six at most; the island
  showed the person's tools without Settings or tools not out yet (replaced
  in REV 60);
  offscreen renders of Try Drop in four states, Shortcuts, Toolbox idle and
  open, whytap.ai and Finish, and the whole window on each step.

- REV 57: each access step goes Allow, waiting, back with the switch off
  (Not on yet), Allow again, allowed, in the preview with its pretend
  system; a return before any ask changes nothing; a step left and reached
  again starts at Allow; Open System Settings opens the step's pane and its
  grant moves the step on; a later return never undoes a grant; macOS's
  microphone dialog still open is no refusal, a Don't Allow is; the Command
  glyph's loops start and end on the square's sides; offscreen renders of
  the four steps in their four states.

- REV 56: no file of the app's module names a preview fake (the fake
  catalogs, key checks, permissions and URL protocol moved to
  `OnboardingPreviewKit`, linked only by the preview and the tests), the
  app's onboarding is built on the default `APIAndModelsViewModel` (the
  catalog and prices Settings -> Models shows), and the app target links
  Sidekey only.

- REV 54: an accepted OpenAI speech key sets `gpt-live-transcribe` with no
  model list, no search, no pick reaching the speech row, and the step
  moves on; Soniox, Deepgram and ElevenLabs offer no list either.

- REV 52: the model search finds by readable name and ID, words in any
  order, nothing for blank or unknown text, a field only above ten models;
  OpenRouter's search covers its whole catalog beyond the listed selection
  and a model found by it is set and checked like any pick; offscreen
  renders of the list with the field and with "gemini".

- `OnboardingGlobeTests` (REV 50): the typed text finds the country ("Rus",
  "Jap", "Port" before Portuguese, "uk") and a language's home country with
  that language (Russian in Cyrillic, "English", "Catalan"), nothing for "Xyzzy"; a
  click finds the country under it (Russia, Brazil, the US, Japan, none in
  the open Pacific, and apart: Switzerland, Lithuania, Latvia, Estonia, the
  Netherlands); each country offers its own variant (Ireland UK, New
  Zealand AU, Argentina MX, Angola PT) and the variant is stored beside the
  language, gone when the language changes elsewhere, absent for Auto; a
  point of the view maps back to the sphere at any
  turn; the spring lands with the country facing the viewer; a Deepgram
  model offers only its languages and Auto-detect only where it has it.
  Offscreen renders of the step at rest, typing, picked, a country of three
  languages, a language outside the menu and no match.

- `OnboardingPreviewTests` switching marks (REV 46), both key steps: a key,
  another provider, back (no borrowed "accepted", no pick or route without
  its key, a refusal stays that provider's, accepted again on return, a new
  checked key moves the route and the old key stays saved); a server, then a
  provider (no glued line, the server keeps the route and the Tavily step
  until a provider's key passes, the fields come back as accepted); a
  provider, then the server (the fields open, a failed server keeps the
  provider, a passed one takes the route). With the pick guard removed the
  two "then back" tests fail.

- `OnboardingJourneyTests`: which steps a clean Mac, a local choice, a key
  choice, a Mac without local speech, an LLM, a missing permission and a Mac
  where everything is done see; Next and Back walk the same list; a step a
  choice removed continues from its place; the bar runs from empty to full;
  a success moves once, Back cancels it, another step's success does not.
- `OnboardingJourneyModelTests` with temporary stores, in-memory keys and
  offline key/model checks: a speech key sets all five speech features
  (Meetings on the recorded model) and moves on after the beat; a refused key
  stays with the reason and sets nothing; a saved key is reused; an LLM key
  sets all four text features and goes on to the language; skipping the LLM
  goes on to the language; OpenAI preselects its newest usable catalog model; On this
  Mac with and without the model here; permissions granted while shown move
  on, granted elsewhere do not; Input Monitoring only when the shortcut needs
  it; informational steps end with Done; an earlier speech key whose check
  finishes last does not replace the later choice.
- `OnboardingJourneyTests` also covers the dwell controller: counting,
  latch and resume, commit now, review never firing, cancel, and the
  per-step dwell times.
- `OnboardingPreviewTests` also names each of the five key problems
  (and saves no refused key), names a provider only from a real format
  (random strings, short and Cyrillic input name nobody; Anthropic and
  OpenRouter keys only on the language model step), masks every input from
  its first character (Russian layout and symbols included, with the dots'
  width equal to the typed text's), calls an unnamed key a format problem until it
  is edited, turns the key field into the server fields and back on the
  same step (the name from the address; a saved server keeps its fields
  until the move), starts the language model step on the recommended model
  of a realistic catalog listed first, lists only current text models with
  prices, waits for a pick or Next (OpenRouter on its current Sonnet too)
  and applies a pick, offers OpenAI's speech models with
  per-minute prices, and checks the flagship rule on its own; the
  recommendation is the newest Sonnet or Sol. `OnboardingJourneyModelTests`
  add a server model with its check (a refused model keeps the fields, the
  retry reuses the server, the shared row takes it, the move goes straight
  to the Tavily step), bring the Tavily step only after a Self-hosted
  language model and take it away after a provider's key, and name
  Tavily's refused, no credit, busy and unreachable answers and a foreign
  key's format.
- `OnboardingPreviewTests`: the preview session walks every step with its
  fakes (refused and accepted keys, server model checks, pretend
  permissions, Simulate Drop, Back, finish) and writes routes only to its
  own suite; On this Mac finishes its timed download.
- OpenAI is not a speech tab until the registry has its speech model; an
  OpenAI key saved on the LLM step opens the speech step on it, and one
  saved for speech opens the LLM step on it.
- Offscreen renders (520 × 440) of every step, including a refused key, an
  accepted key while counting, a held step, Back to a reviewed step, the
  server fields on the speech and language model steps and an added server.

Not verified: the real window with real permissions, real provider key
checks, the motion itself (offscreen renders are still frames) and the
maintainer's approval of the visual.

2026-11-22 · branch `feature/onboarding-v2`
