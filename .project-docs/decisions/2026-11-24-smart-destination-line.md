---
id: smart-destination-line-2026-11-24
type: decision
title: Rejected - one line naming the destination app instead of Smart's formatting profiles
summary: A design that tells the Smart model which app the text is for and lets it decide about Markdown was built and measured on the live model, then rejected by the maintainer. Smart's behavior did not change; the measurements are kept so the idea is not restarted from zero.
status: confirmed
tags: [smart, markdown, formatting, prompt, dictation, rejected]
canonical_for: [smart-destination-line]
verified_at: 2026-11-24
sources:
  - type: user-confirmed
    reference: On 2026-11-24 the maintainer proposed that Smart tell the model which app the cursor is in so that a model which knows the app prepares Markdown for it, said that rules are not needed and one line is enough, and gave the line as "this message is meant for X, you can use the features of its Markdown to structure the answer".
    confirmed_at: 2026-11-24
  - type: user-confirmed
    reference: On 2026-11-24, after the measurement report, the maintainer first said to remove Markdown from Smart altogether for now, then that Slack and Telegram could probably stay as they were and that the main thing is that structure (line breaks and the like) is kept, and finally confirmed closing the task and leaving Smart as it is.
    confirmed_at: 2026-11-24
  - type: repository
    reference: Sources/Sidekey/SmartFormattingProfile.swift
    confirmed_at: 2026-11-24
  - type: repository
    reference: Sources/Sidekey/PostProcessor.swift
    confirmed_at: 2026-11-24
related: [2026-10-21-smart-destination-formatting.md]
---

# Rejected: one line about the destination app

**Status: rejected. No behavior changed.** Smart keeps the formatting
profiles of
[2026-10-21-smart-destination-formatting.md](2026-10-21-smart-destination-formatting.md).
This record keeps what was measured. The code is in the closed, unmerged
pull request 445 (branch `claude/smart-destination-line`).

## The idea

Smart chooses one of seven formatting profiles (plain, CommonMark, GitHub,
GitLab, Discord, Slack, Telegram) from a fixed list of bundle identifiers,
browser hosts and paths. The maintainer did not want to maintain that list
and proposed one line instead: tell the model which app the text is for and
let it use that app's Markdown. The model already receives the app's name
as `Active app:`.

## What was built

- One line in the system prompt naming the app, in place of the plain-text
  rule of the prompt's Structure section. No list of apps; single-line
  fields, Whytap's own editors and unnamed apps got no line.
- Slack and Telegram stayed named in code for the paste mechanics only
  (Markdown to RTF + HTML on the clipboard); their line described Whytap's
  converter, because the model could otherwise write Slack's own `*bold*`,
  which the converter reads as italic.
- A second variant after the first report: one switch that made every take
  plain, including Slack and Telegram.

## What was measured

Live requests on 2026-11-24, Anthropic direct, `claude-sonnet-5-5`, the
request of build 1743 (no reasoning fields), the production system prompt,
synthetic dictations only. All answers HTTP 200. The technical dictation
named a file, two parameters and a command and listed three steps.

| Variant of the line | Result on the technical dictation |
| --- | --- |
| The maintainer's wording, appended after the prompt | No markup in 16 of 16 apps |
| Same, plus "this lifts the ban; plain if the app shows no Markdown" | Random: `code` in Slack, Discord, Notion, Linear, Chrome, VS Code and an invented app; none in Claude, Obsidian, Telegram |
| The line in place of the plain-text rule, as a bare permission | Random: none in Claude, Obsidian, Notion; `code` in Mail, Terminal, Chrome |
| In place of the rule, with "if you know that this app shows Markdown ... format names of files, parameters and commands as `code` ... otherwise no markup except simple lists" | `code` in 7 of 7 Markdown apps (Claude, Obsidian, Discord, Notion, Linear, GitHub, Codex) and 4 of 4 Slack/Telegram answers |

Why the maintainer's wording alone did nothing: the base prompt forbids
headings, bold, backticks, tables and code blocks in its Structure section
and shows only plain examples. A permission added after it loses to that
rule. The line has to replace the rule, and a bare "you may" is applied at
random; it needed a condition and a concrete use.

Where the best variant put markup into apps that show no Markdown: 7 of 13
technical answers contained backticks. Terminal 3 of 3, Google Chrome 1 of
1, Safari 1 of 1, VS Code 1 of 1, Messages 1 of 3; Notes, Mail, TextEdit
and an invented app 0 of 4. Example in Messages (translated): "Restart the
worker with the command `make restart-worker`." In a shell, backticks are
command substitution: such prose dictated straight at a shell prompt would
run the quoted command on Enter.

Other observations:

- The only markup in all 107 answers was inline code around files,
  parameters and commands. No bold, heading, table, quote or code block.
- A casual dictation got no markup in any app (15 answers); a short one
  stayed a plain sentence (7 of 7); a clean phrase returned the pass marker
  (9 of 9).
- Telling a browser apart ("a web page in Google Chrome, site unknown") on
  four requests helped nothing.
- With the least-reasoning request of pull request 443 (effort low, thinking
  off), four requests: `code` in Claude, and also in Notes and Messages (2
  of 2). Too small for a rate; it suggests that with less reasoning the
  model separates apps worse.
- With no line at all (the base prompt, 12 requests for Slack, Telegram,
  Claude, Terminal, Obsidian, Notes, Chrome, VS Code and others): no markup
  in any answer, lists where the dictation listed things.

Each cell is one to three samples at the provider's default temperature:
development examples, not an accuracy estimate. Paste rendering in real
apps was not checked.

## Why it was rejected

The maintainer expected a simpler change. The model does not separate apps
reliably by name: about half of the technical answers for apps without
Markdown carried backticks, a terminal among them. Removing Markdown
altogether would have taken formatted text away from Slack and Telegram.
He chose to leave Smart as it is; what matters to him is that structure
(line breaks, paragraphs, lists) is kept.

## If the idea returns

- Start from the last variant above, not from the bare permission.
- Decide first what a terminal gets.
- Measure with the request that ships then; reasoning effort changes the
  result.
- A review of the built code also found that when the focused role cannot
  be read within the 1.5 s deadline, a single-line field would get the line.

2026-11-24 · closed pull request 445
