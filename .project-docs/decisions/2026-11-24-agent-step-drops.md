---
id: agent-step-drops-2026-11-24
type: decision
title: A turn that only changed Whytap ends with drops right of the island, not with text
summary: When the built-in Agent's whole result is the Whytap changes it made, it finishes with status done and no text, and the app shows one glass drop per confirmed change right of the island (in order, at most three at a time, leaving in reverse) instead of the answer panel. The app accepts done only when it confirmed a change and no write failed; otherwise the answer is text as before. History keeps the same lines.
status: confirmed
tags: [agent, native-agent, app-control, island, drops, history, design]
canonical_for: [agent-step-drops]
verified_at: 2026-11-24
sources:
  - type: user-confirmed
    reference: 'ORCH-TASK 96, forwarded by the orchestrator on 2026-11-24. The maintainer proposed making app changes through the Agent and showing the result through the drops, and said: when no text needs to be written, the Agent should just show step by step what it did, and that is all (translated). No confirmation before the action.'
    confirmed_at: 2026-11-24
  - type: user-confirmed
    reference: 'ORCH-TASK 72 feedback on the shelved suggestion drops, quoted in the ORCH-TASK 96 brief: the appearing and hiding animation was broken; the drop shape itself was liked (translated).'
    confirmed_at: 2026-11-24
  - type: user-confirmed
    reference: 'ORCH-TASK 96, REV 3, forwarded by the orchestrator on 2026-11-24. For a model change the Agent shows a short summary of which model it was and which it is now; for a reassigned hotkey, which hotkey is assigned; adding a feature to the hover or removing one is done by short commands too; Y/N is not needed at all, only icons and briefly what was done (translated).'
    confirmed_at: 2026-11-24
  - type: repository
    reference: Sources/Sidekey/AgentSteps/AgentStepDropsModel.swift
    confirmed_at: 2026-11-24
  - type: repository
    reference: Sources/Sidekey/AgentSteps/AgentStepDropsView.swift
    confirmed_at: 2026-11-24
  - type: repository
    reference: Sources/Sidekey/AgentDaemon/NativeAgentProvider.swift
    confirmed_at: 2026-11-24
  - type: repository
    reference: Tests/SidekeyTests/AgentSteps/AgentStepDropsTests.swift
    confirmed_at: 2026-11-24
  - type: repository
    reference: Tests/SidekeyTests/AgentDaemon/NativeAgentAppControlTests.swift
    confirmed_at: 2026-11-24
related: [2026-11-22-native-agent-app-control.md, 2026-11-23-agent-drop-lists.md, 2026-11-23-drop-learning-shelved.md, 2026-10-22-native-agent.md]
---

# Agent step drops

## Context

The built-in Agent changes Whytap with the `whytap` tool (settings, model
routes, island tools, hotkeys, Vocab, Filler, To-do). Every confirmed change
already had an app-owned line ("Vocab + whytap") above the model's answer.
For "add whytap to vocab" the answer under the island was that line plus a
sentence repeating it. The maintainer asked that, when nothing needs to be
written, the Agent just shows step by step what it did. The shape was to be
the drop right of the island from the shelved Drop learning suggestions
(branch `shelf/drop-learning`), whose guessing and animation he had rejected
while liking the drop itself.

## Decision

- **The sign comes from the Agent, checked by the app.** `finish_answer` has
  a fourth status, `done`, offered only when the turn has the `whytap` tool.
  It means: the confirmed changes are everything the user asked for and there
  is nothing to add; the answer is empty, with no sources, actions or
  insert_text. The provider accepts it only if the app confirmed at least one
  change in this turn, no Whytap write failed and the turn made no file edit
  and ran no command (those have no app-owned line, so their result is text).
  Nothing in the interface guesses from the answer's length or wording.
- **Refused `done`.** With no confirmed change (the word was already there, a
  plain question) or after a failed write (list full, conflict, invalid
  arguments) the model is told once, as the tool's result, to finish with
  status answered and say what was and was not changed. A second `done` ends
  the turn as an invalid answer with the existing "changes may have
  completed" warning. So a failed step is never shown as done: the turn has
  no drops and its answer is text.
- **`done` with text is an ordinary answer.** What the model wrote is never
  dropped; the turn then looks as before (lines above the text).
- **One event.** The provider sends `appSteps` (operation and line of each
  confirmed change, in order) and `done`, no `finalAnswer`. A hotkey joined
  to its "Toolbox + Shot" line is one step. The Agent's own conversation
  memory gets the lines as the assistant's turn.
- **No answer panel.** `AskResponseStore.appSteps` is not answer content, so
  the island's answer panel stays closed and the wing folds. On completion
  `AgentController.onAppSteps` hands the steps to the drops.
- **History.** The agent row is finalized with a text block holding the same
  lines (Markdown literals, one paragraph each), so History shows what was
  done although nothing was written on screen.
- **Drops.** `AgentStepDropsPanel`: a non-activating panel in the menu bar
  right of the island, one level below it, following the system appearance.
  It never takes the mouse; menu bar extras under it keep working. One glass
  capsule per step: the mark of the changed part (book for Vocab, scissors
  for Filler, sliders for a setting, grid for Toolbox, keyboard for a hotkey,
  checklist for To-do, chip for a model route), then the app's line with the
  saved value in bold.
- **What a drop says.** The app's line for the change: "Vocab + whytap",
  "Hotkey: Shot — ⌥S" (the hotkey now assigned), "Toolbox + Shot",
  "Toolbox − Monitor", "Drop mode → Smart". A model change is a summary of
  what it was and what it is, "Agent: claude-sonnet-5-5 → claude-opus-5-5"
  (`NativeAgentAppControl.stepLine`): the old model is the `expected` route
  of the request, which the controller matched against the saved route
  before writing. The line above a text answer and the wing's label are
  unchanged. A drop is at most 340 pt wide; longer text is cut in the middle.
- **How many and how long.** At most three at once. Drops bud 0.22 s apart
  in the order the changes were made. With more than three, every 1.1 s the
  first goes back into the island and the next buds at the far end, so every
  step is seen in order. The full row stays 3.2 s plus 0.8 s per further
  drop (4.8 s for three), then the drops leave last first, 0.12 s apart.
- **Motion.** A drop exists in the view only while it is on screen. The
  panel is ordered in 0.3 s before the first drop (the island's wing has
  folded by then) and out 0.5 s after the last one left. macOS 26: each drop
  is a `glassEffect` with a `glassEffectID` in one `GlassEffectContainer`,
  so the system morphs it out of and back into its neighbour. Without native
  glass (macOS 14/15, Reduce Transparency) a drop grows from its leading side
  out from behind the one before it, the first from under the island. Reduce
  Motion: fades only (0.16 s).
- **Busy island.** Drops show only while Drop and the Agent are idle and no
  answer is open. A new take, an Agent turn, sleep or quit fades them at
  once. Steps that arrive during a dictation wait up to 20 s for it to end;
  older ones are not shown late (they are in History).
- **No keys, no clicks, no undo.** The user asked for the change, so there is
  nothing to confirm and Control-Y / Control-N are not registered. Undo is a
  new request to the Agent; Vocab and Filler removal is not an operation yet.
- **VoiceOver.** The panel never has focus; the shown lines are posted as
  one announcement.
- **Unchanged:** answers with text, cards, sources or an error; the step
  label in the wing during the turn; learning from edits (still only on the
  shelf branch, with its settings, calibration and Replace list).

## Why

- Only the model knows whether it has something to say; only the app knows
  whether a change was really saved. Requiring both keeps a quiet turn from
  hiding a failure or a question.
- A refused `done` costs one more model request in a rare case, instead of a
  wrong silent success.
- The shelved drops kept all four drops in the hierarchy and hid them with
  opacity, scale and offset; the panel was ordered in at the same moment the
  first drop was set out and ordered out on a fixed timer. Glass does not
  follow opacity, and a state set before the window is on screen is not
  animated, which matches what the maintainer saw. Insertion and removal with
  a panel that is up before and after avoids both.
- A panel that ignores the mouse cannot repeat the shelved first-click
  problem or block menu bar extras.

## What was tested

`NativeAgentAppControlTests`, the real native loop with a stubbed model and
the real controller on temporary stores: one action with `done` (one step, no
answer text, two requests, the conversation file has the line, the status
enum and prompt rule are sent); three actions (three steps in order); a tool
added with its hotkey (one step); a model change (was and now), a reassigned
hotkey (the assigned keys), a hover tool added and one removed; a failed action with `done` (refused, text
answer, no drops, the failed list unchanged); a model insisting on `done`
(error with the warning); an existing word and a plain question with `done`
(refused, text); a turn that also wrote a file (refused, text); an action
with needed text and `done` with text (text, as before); an ordinary question; no `done` without the whytap tool; the
`done` format. `AgentControllerHistoryTests`: a steps-only turn opens no
answer panel, hands the steps over once, saves the lines in History and the
next ordinary turn hands over nothing; an error after steps shows the error.
`AgentStepDropsTests`, model on a hand-moved clock: one, three and five
steps, order, never more than three, reverse exit, the panel up before the
first drop and until the last left, a busy island, a replaced row, Reduce
Motion, waiting for a dictation, the 20 s limit, sleep, the panel frame; the
real row rendered off screen in light and dark with its text read back.
Live, 2026-11-24, direct Anthropic `claude-sonnet-5-5` (the maintainer's
Agent route), temporary stores, about ten requests in Russian: "add whytap
to vocab" ended with one step and no text; vocab + filler + Smart with three steps and
no text; an existing word and a question with text and no steps. Storyboard
frames and videos of the path without native glass were made from the real
drop view and the model's timeline. Not tested: the installed app; native
macOS 26 glass does not render off screen, so its morph was not seen.

## Rejected

- Guessing from the answer (short, or equal to the lines): the interface
  would decide what the Agent meant.
- A boolean field next to the answer: one more required parameter in every
  strict request; a status says the same with no schema growth.
- Drops for every turn with changes, beside a text answer: the lines are
  already above the text, and an answer panel under a row of drops is two
  places to read.
- A red drop for a failed step in a silent turn: a failure needs its reason,
  which is text; the app forces text instead.
- All steps at once, or a "+2" drop: unreadable beyond three, or hides steps.
- Keeping the drops' Y/N, clicks or hover pause: nothing to answer (the
  maintainer confirmed no Y/N at all); a click-through panel is what keeps
  the menu bar usable.
- An undo button in the drop: not asked for; it would need a mouse-taking
  panel again.
- Changing the shared change line to "old → new" everywhere: text answers
  were to stay as they are.
- Budding each drop live during the turn: the island's wing is open then and
  covers that place.
- `whytap_replace_add`: Replace left the app with Drop learning; a request
  for a replacement rule is answered in text.

2026-11-24 · ORCH-TASK 96 · branch `claude/agent-step-drops`
