---
id: smart-destination-line-2026-11-24
type: decision
title: Smart tells the model which app the text is for and lets it decide about Markdown
summary: The fixed list of apps with their own Markdown rules is replaced by one line naming the destination app; the model decides whether that app shows Markdown. Only Slack and Telegram stay named in code, for the rich paste.
status: confirmed
tags: [smart, markdown, formatting, prompt, dictation, slack, telegram]
canonical_for: [smart-destination-line]
verified_at: 2026-11-24
sources:
  - type: user-confirmed
    reference: On 2026-11-24 the maintainer asked that Smart tell the model which app the cursor is in, so that a model which knows the app prepares Markdown for it; said that the model would not guess; said that rules are not needed and one line is enough; and gave the line as "this message is meant for X, you can use the features of its Markdown to structure the answer".
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

# Smart: one line about the destination app

## Context

Since 2026-10-21 Smart chose one of seven formatting profiles (plain,
CommonMark, GitHub, GitLab, Discord, Slack, Telegram) from a fixed list of
bundle identifiers, browser hosts and paths, and appended that profile's rules
to the system prompt. Every app outside the list got plain text. The
maintainer does not want to maintain a list of apps and a rule set for each:
the app's name is already known (History shows it), and the model knows which
apps show Markdown.

## Decision

- For a Smart take the model is told the destination in one line, and decides
  itself whether that app shows Markdown and which. The line replaces the
  plain-text rule of the prompt's Structure section; nothing else in the
  prompt changes. The prompt is Russian; the exact text is
  `SmartFormattingProfile.instructions`. In English:

  > This message is meant for the app "X". If you know that this app shows
  > Markdown, use the features of its Markdown to structure the text: format
  > the names of files, parameters and commands as `code`, keeping the
  > characters inside exact, and apply other formatting for meaning, not for
  > decoration. If the app does not show Markdown or you do not know it, use
  > no markup except simple lists.

- X is the app's display name, the same one the request already carried as
  `Active app:`. No new data leaves the Mac. The name is reduced to one line
  of at most 60 characters without control characters or the angle quotes
  that delimit it.
- No list of apps decides who gets the line. Editors and browsers are named
  like any other app; the file type and the site no longer matter.
- Three local guards remain, none of them per app: a single-line field
  (`AXTextField`, `AXComboBox`, `AXSecureTextField`) gets no line and stays
  plain; so does a take without a process identity (one of Whytap's own
  editors) and an app without a name.
- Slack and Telegram stay named in code, because the paste mechanics need
  them: there Whytap converts Markdown to RTF + HTML on the clipboard
  (`SmartRichTextPaste`). They are recognized by bundle identifier and, in a
  browser, by the exact hosts `app.slack.com` and `web.telegram.org`. Their
  line describes Whytap's converter instead of the app: standard Markdown,
  which marks it understands, and that headings, tables and quotes would stay
  as characters. Without it the model could write Slack's own `*bold*`, which
  the converter reads as italic.
- The pass marker, the provenance rule (a passed or echoed transcript is
  delivered plain, with literal asterisks), the filler protection of code
  spans and URLs, Retry and the selected route are unchanged. The filler
  protection now applies whenever the line was sent.

## Why

The maintainer's decision: trust the model instead of a list. The line keeps
his meaning (who the text is for, permission to use that app's Markdown). It
is longer than his wording for two measured reasons below: appended after the
prompt it had no effect, and as a bare permission it was applied at random.

## What was tested

Live requests on 2026-11-24, the maintainer's route (Anthropic direct,
`claude-sonnet-5-5`), the request of build 1743 (no reasoning fields), the
production system prompt, synthetic dictations only: 107 requests, all HTTP
200. Dictations: a long technical one (a file, parameters, a command, three
steps), a casual one, a short one with fillers, and a clean phrase.

| Variant | Result on the technical dictation |
| --- | --- |
| The maintainer's line appended after the prompt | No markup in 16 of 16 apps: the plain-text rule above it won |
| Same, plus "this lifts the ban; plain if the app shows no Markdown" | Random: `code` in Slack, Discord, Notion, Linear, Chrome, VS Code and an invented app; none in Claude, Obsidian, Telegram |
| The line in place of the plain-text rule, as a permission | Still random: none in Claude, Obsidian, Notion; `code` in Mail, Terminal, Chrome |
| Final line (above) | `code` in 7 of 7 Markdown apps (Claude, Obsidian, Discord, Notion, Linear, GitHub, Codex) and 4 of 4 Slack/Telegram answers |

The risk the maintainer accepted, measured with the final line: markup in an
app that does not show Markdown. Of 13 technical answers for such apps, 7
contained backticks: Terminal 3 of 3, Google Chrome 1 of 1, Safari 1 of 1,
VS Code 1 of 1, Messages 1 of 3; Notes, Mail, TextEdit and an invented app
0 of 4. Example in Messages (translated): "Restart the worker with the
command `make restart-worker`." The only markup that ever appeared was inline code
around files, parameters and commands. No bold, heading, table, quote or code
block appeared in any of the 107 answers.

Other behavior held: the casual dictation got no markup in any app (15
answers, lists only), the short one stayed a plain sentence (7 of 7), and the
clean phrase returned `<WHYTAP_PASS>` (9 of 9).

Four requests used the least-reasoning request proposed in pull request 443
(effort low, thinking off): Claude got `code`, and so did Notes and Messages
(2 of 2). The sample is too small for a rate; it suggests that with less
reasoning the model separates apps worse.

Telling a browser apart ("a web page in Google Chrome, site unknown") was
tried on four requests and helped nothing (Chrome still got `code`, Notion
lost it), so it was not built.

Each cell is one to three samples at the provider's default temperature.
These are reused development examples, not an accuracy estimate. Paste
rendering in real apps was not checked: the feature session does not launch
an app.

## Rejected

- The maintainer's line verbatim, appended: measured, no effect.
- Keeping the per-app profiles and only adding the line: the maintainer does
  not want the list.
- A site name for browsers (the page's host in the request): new data leaving
  the Mac, which [2026-11-22-smart-no-window-context.md](2026-11-22-smart-no-window-context.md)
  rules out without the maintainer's decision.
- Removing the single-line guard: a search field or a title never shows
  Markdown, and the guard needs no list.
- Teaching the converter Slack's and Telegram's own dialects instead of the
  converter line: `*x*` and `__x__` mean different things in them and in
  standard Markdown.

## Consequences

- Recognized web composers lose their site-specific rules: GitHub, GitLab or
  Discord in a browser is now "Google Chrome" to the model.
- A code file in an IDE and a terminal are no longer forced to plain text.
- An app without a bundle identifier is plain even when it has a name.

## Supersedes / superseded by

Supersedes the profile table and the per-profile rules of
[2026-10-21-smart-destination-formatting.md](2026-10-21-smart-destination-formatting.md).
Its clipboard, literal-preservation and provenance parts stand.

2026-11-24 · branch `claude/smart-destination-line`
