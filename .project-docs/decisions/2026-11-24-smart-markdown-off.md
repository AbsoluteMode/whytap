---
id: smart-markdown-off-2026-11-24
type: decision
title: Smart writes plain text in every app for now; Markdown is switched off
summary: After a one-line "this text is for app X" design was built and measured on the live model, the maintainer removed Markdown from Smart for now. One switch keeps every take plain; the measured design and the Slack/Telegram rich paste stay in the code behind it.
status: confirmed
tags: [smart, markdown, formatting, prompt, dictation, slack, telegram]
canonical_for: [smart-markdown-switch, smart-destination-line]
verified_at: 2026-11-24
sources:
  - type: user-confirmed
    reference: On 2026-11-24 the maintainer asked that Smart tell the model which app the cursor is in, so that a model which knows the app prepares Markdown for it; said that rules are not needed and one line is enough; and gave the line as "this message is meant for X, you can use the features of its Markdown to structure the answer".
    confirmed_at: 2026-11-24
  - type: user-confirmed
    reference: On 2026-11-24, after the measurement report (backticks in 7 of 13 technical answers for apps without Markdown, the risk in a terminal), the maintainer said - okay, let us remove Markdown altogether for now.
    confirmed_at: 2026-11-24
  - type: repository
    reference: Sources/Sidekey/SmartFormattingProfile.swift
    confirmed_at: 2026-11-24
  - type: repository
    reference: Sources/Sidekey/PostProcessor.swift
    confirmed_at: 2026-11-24
  - type: repository
    reference: Tests/SidekeyTests/SmartFormattingTests.swift
    confirmed_at: 2026-11-24
related: [2026-10-21-smart-destination-formatting.md, 2026-11-22-smart-no-window-context.md, 2026-11-20-smart-ready-text.md, 2026-10-22-smart-editor-pass.md]
---

# Smart: Markdown off for now

## Context

Since 2026-10-21 Smart chose one of seven formatting profiles (plain,
CommonMark, GitHub, GitLab, Discord, Slack, Telegram) from a fixed list of
bundle identifiers, browser hosts and paths, and appended that profile's rules
to the system prompt. The maintainer did not want to maintain a list of apps
with a rule set for each and proposed one line: tell the model which app the
text is for and let it use that app's Markdown. That design was built and
measured the same day. The measurement showed the model putting backticks
into apps that show no Markdown, a terminal among them, and the maintainer
decided to remove Markdown from Smart for now.

## Decision

- Smart writes plain text in every app: paragraphs and simple lists, as the
  base prompt's plain-text rule says. No destination line is sent, nothing is
  converted on paste, and Slack and Telegram get the same plain text as any
  other app.
- One switch does it: `SmartFormattingProfile.isMarkdownEnabled`, `false`.
  While it is off `resolve` returns `plain` for every target, the system
  prompt is the base prompt byte for byte, and Smart does not read the
  focused role or the document address through Accessibility at all (the take
  no longer waits up to 1.5 s for them).
- "For now": the code behind the switch stays, covered by tests that pass
  `markdownEnabled: true`. Turning the switch on restores the design
  described below; it does not restore the seven profiles.
- The pass marker, plain delivery of a passed transcript, Retry and the
  selected route are unchanged. The request still carries the app's name as
  `Active app:`.

## What changed for the user compared with build 1743

- Slack and Telegram (app and browser): build 1743 pasted formatted text
  (bold, italic, monospace for names and code) converted from the model's
  Markdown. Now the text arrives plain, without formatting and without
  markup characters.
- Obsidian, Typora, MarkText, the Codex, ChatGPT and Claude composers,
  Discord, GitHub and GitLab composers in a browser, and a Markdown file in
  an IDE: build 1743 could put names in backticks and use bold. Now plain.
- Every other app: no change, it was plain already.

## The design behind the switch

For a take the model is told the destination in one line that replaces the
plain-text rule of the prompt's Structure section
(`PostProcessor.systemPrompt(for:)`). The prompt is Russian; the exact text
is `SmartFormattingProfile.instructions`. In English:

> This message is meant for the app "X". If you know that this app shows
> Markdown, use the features of its Markdown to structure the text: format
> the names of files, parameters and commands as `code`, keeping the
> characters inside exact, and apply other formatting for meaning, not for
> decoration. If the app does not show Markdown or you do not know it, use
> no markup except simple lists.

- X is the app's display name, already in the request; for Slack or Telegram
  in a browser it is "Slack" or "Telegram". The name is reduced to one line
  of at most 60 characters without control characters or the angle quotes
  that delimit it.
- No list of apps decides who gets the line. A single-line field
  (`AXTextField`, `AXComboBox`, `AXSecureTextField`), a take without a
  process identity (one of Whytap's own editors) and an app without a name
  get no line. The single-line guard works only when the role was read.
- Slack and Telegram are named in code for the paste mechanics only: Whytap
  converts Markdown to RTF + HTML (`SmartRichTextPaste`), and their line
  describes that converter instead of the app.

## What was tested

Live requests on 2026-11-24, the maintainer's route (Anthropic direct,
`claude-sonnet-5-5`), the request of build 1743 (no reasoning fields), the
production system prompt, synthetic dictations only. All answers HTTP 200.

With the switch off (what ships), 12 requests: a technical dictation (a
file, parameters, a command, three steps) for Slack, Telegram, Claude,
Terminal, Obsidian, Notes, Google Chrome and VS Code, a casual one, a short
one, a search-like one and a clean phrase. No backtick, bold, heading or
other markup in any answer; lists where the dictation listed things; the
clean phrase returned the pass marker.

The destination line, 107 requests:

| Variant | Result on the technical dictation |
| --- | --- |
| The maintainer's line appended after the prompt | No markup in 16 of 16 apps: the plain-text rule above it won |
| Same, plus "this lifts the ban; plain if the app shows no Markdown" | Random: `code` in Slack, Discord, Notion, Linear, Chrome, VS Code and an invented app; none in Claude, Obsidian, Telegram |
| The line in place of the plain-text rule, as a permission | Still random: none in Claude, Obsidian, Notion; `code` in Mail, Terminal, Chrome |
| The line above | `code` in 7 of 7 Markdown apps (Claude, Obsidian, Discord, Notion, Linear, GitHub, Codex) and 4 of 4 Slack/Telegram answers |

With the line above, of 13 technical answers for apps that show no
Markdown, 7 contained backticks: Terminal 3 of 3, Google Chrome 1 of 1,
Safari 1 of 1, VS Code 1 of 1, Messages 1 of 3; Notes, Mail, TextEdit and an
invented app 0 of 4. Example in Messages (translated): "Restart the worker
with the command `make restart-worker`." In a shell, backticks are command
substitution: such prose dictated straight at a shell prompt would run the
quoted command on Enter. The only markup that ever appeared was inline code
around files, parameters and commands; no bold, heading, table, quote or
code block in any of the 107 answers. The casual dictation got no markup in
any app (15 answers), the short one stayed a plain sentence (7 of 7), the
clean phrase returned the pass marker (9 of 9).

Four requests used the least-reasoning request proposed in pull request 443
(effort low, thinking off): Claude got `code`, and so did Notes and Messages
(2 of 2). The sample is too small for a rate; it suggests that with less
reasoning the model separates apps worse.

Each cell is one to three samples at the provider's default temperature.
These are reused development examples, not an accuracy estimate. Paste
rendering in real apps was not checked: the feature session does not launch
an app.

## Rejected

- Shipping the destination line as measured: the maintainer chose to remove
  Markdown instead.
- An exception for terminals only (the recommendation given to the
  maintainer): he chose the simpler removal.
- Keeping the rich paste for Slack and Telegram: "altogether" was taken
  literally; the loss is listed above for the maintainer to confirm.
- Deleting the profile, the line and the converter: "for now" means it may
  come back, and one switch is cheaper than a rewrite.
- Restoring the seven per-app profiles behind the switch: the maintainer did
  not want the list.

## Before turning the switch back on

- Decide what a terminal gets; backticks there are not harmless.
- Re-measure with the request that then ships (reasoning effort changes the
  leak rate).
- When the focused role cannot be read, a single-line field gets the line
  too.

## Supersedes / superseded by

Supersedes the profile table and the per-profile rules of
[2026-10-21-smart-destination-formatting.md](2026-10-21-smart-destination-formatting.md),
and switches off its rich paste for Slack and Telegram. The clipboard code
and its literal-preservation rules stay in the repository.

2026-11-24 · branch `claude/smart-destination-line`
