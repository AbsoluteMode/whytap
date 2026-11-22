---
id: smart-destination-formatting-2026-10-21
type: decision
title: Format Smart dictation for its recognized destination
summary: Resolve a local destination profile, pass fixed formatting rules to the editor, and deliver source Markdown or rich clipboard text appropriate for the target.
status: confirmed
tags: [smart, markdown, context, formatting, github, gitlab, discord, slack, telegram]
canonical_for: [smart-destination-formatting]
verified_at: 2026-10-21
sources:
  - type: user-confirmed
    reference: On 2026-10-21 the user requested destination-aware Markdown for popular development applications, explicitly extending the earlier Telegram example.
    confirmed_at: 2026-10-21
  - type: repository
    reference: Sources/Sidekey/SmartFormattingProfile.swift
    confirmed_at: 2026-10-21
  - type: repository
    reference: Sources/Sidekey/SmartRichTextPaste.swift
    confirmed_at: 2026-10-21
  - type: url
    reference: https://docs.github.com/en/get-started/writing-on-github/getting-started-with-writing-and-formatting-on-github/basic-writing-and-formatting-syntax
    confirmed_at: 2026-10-21
  - type: url
    reference: https://docs.gitlab.com/user/markdown/
    confirmed_at: 2026-10-21
  - type: url
    reference: https://support.discord.com/hc/en-us/articles/210298617-Markdown-Text-101-Chat-Formatting-Bold-Italic-Underline
    confirmed_at: 2026-10-21
  - type: url
    reference: https://slack.com/intl/en-gb/help/articles/360039953113-Format-your-messages-in-Slack-with-markup
    confirmed_at: 2026-10-21
  - type: url
    reference: https://github.com/overtake/TelegramSwift/blob/master/Telegram-Mac/ChatInputView.swift
    confirmed_at: 2026-10-21
  - type: url
    reference: https://obsidian.md/help/syntax
    confirmed_at: 2026-10-21
  - type: url
    reference: https://code.visualstudio.com/docs/languages/markdown
    confirmed_at: 2026-10-21
related: [2026-10-21-smart-editor-prompt.md, 2026-10-21-smart-decisions.md, 2026-10-22-smart-editor-pass.md, 2026-11-22-smart-no-window-context.md]
---

# Destination formatting

## Context and alternatives

The editor previously forbade all Markdown except plain lists. One formatting
rule is unsuitable for Markdown source editors, chat syntax and rich-text
composers. An app's support for typing shortcuts or an API's parse mode does
not establish how a pasted string will be handled.

Do not let the model guess the application from screen prose, globally enable
Markdown, change the user's app settings, or switch models to obtain formatting.
Keep unknown destinations on the existing plain-text contract.

## Decision

Resolve a fixed profile from the remembered target process's bundle identity,
with an exact app-name fallback only when identity is unavailable. Existing
Accessibility permission provides focused role and containing document URL.
Collect this metadata and existing screen text within one 1.5-second deadline.
Do not infer a site from window titles, transcript text, links found in the
page body or arbitrary AX fragments.

| Destination | Contract |
| --- | --- |
| Obsidian, Typora, MarkText | Small CommonMark subset |
| Codex/ChatGPT and Claude composers | CommonMark source for the prompt; a known non-Markdown file remains plain |
| VS Code, Cursor, Windsurf, Zed, Xcode | CommonMark only for an AXTextArea with a file document ending in .md/.markdown/.mdown |
| github.com issue/PR/discussion/commit composers | GitHub Markdown subset |
| gitlab.com issue/MR/wiki/epic composers | GitLab Markdown subset; no invented quick actions |
| Discord native or discord.com/channels | Discord-compatible Markdown subset |
| Slack native or app.slack.com/client | Local conversion to rich clipboard text |
| Telegram native or web.telegram.org | Local conversion to rich clipboard text |
| Unknown application/site, single-line field, unavailable IDE/browser metadata | Existing plain text |

Browser profiles require an allowlisted browser, an HTTPS containing-document
URL with the exact host, and an AXTextArea. Self-hosted GitLab and unsupported
web hosts remain plain. Single-line fields, search fields and issue titles
remain plain. These are best-effort recognition rules; inaccessible metadata
does not stall delivery or request another permission.

Append only the selected profile's static rules to the existing system prompt.
They override its presentation restriction while retaining all meaning,
language, literal-content and instruction-boundary rules. Screen context is
still data. Format discussed identifiers/paths as inline code, use paragraphs
and lists, and avoid decorative or unsupported structures. A short plain
message remains short. This applies to the selected cleanup provider; it does
not select Sol or change any saved route.

Recognition alone does not force another editor call. A successful clean
Decision can return raw text, which also bypasses the rich Markdown parser:
literal asterisks and underscores must not acquire formatting. Translation and
Decision/editor failure behavior remain unchanged. Fast does not use the new
formatting or rich clipboard path.

## Clipboard and literal preservation

For Slack/Telegram, the editor uses a small internal Markdown subset. Convert
it locally to RTF plus escaped, semantic HTML and a readable plain-text
fallback. This avoids applying a bot API syntax to an ordinary client paste.
Telegram's native source explicitly consumes RTF in its paste handler. Slack
has a separate markup preference and documents plain-text paste behavior in
that mode; do not override the preference or promise identical styling in
every client configuration.

Never execute model-provided HTML or load embedded resources. Raw HTML/images
and unclosed fences remain literal. Code preserves indentation and symbols.
URLs retain their exact visible bytes; link fallbacks keep the destination.
The local filler pass masks code spans/fences and bare URLs for known Markdown
profiles, so it cannot remove a filler-shaped token or normalize spaces there.

All clipboard flavors use AutoPasteEngine's existing suppression and full
snapshot/restore path. A writer that mutates the clipboard before failing
restores the original bytes. Tests use unique named pasteboards and fake key
events, never the user's clipboard or a real send action. History retains the
editor's canonical text representation, not a new rich-content store.

## Evidence and limits

Synthetic checks cover profile/field resolution, lookalike hosts, prompt
boundaries, unchanged clean-Decision bypass, shared AX deadlines, code/URL
preservation, RTF style/text round-trips, semantic HTML and clipboard restoration
on success/failure. The initial and revised formatting prompts were each
manually evaluated on the same synthetic dictation across six profiles using
exact openai/gpt-6-sol pinned to openai/fast, reasoning off. The final outputs
retain the literal path/parameter/numbers, staging-only restriction, approval
conditions and distinction between assessment time and completion commitment.
Recognized formats add inline code; the unknown-app control remains plain.

Source/model checks are separate from real-client acceptance. Physical focus,
AX metadata exposure and paste rendering in each app/version remain acceptance
checks on the shared installed application. The feature worker does not launch
or install an app. No universal Markdown compatibility or semantic-loss
guarantee is claimed.

## Resolution and consequences

Use local capability profiles and the existing editor call. Clipboard
conversion adds no network request, service, key or preference. Document URLs
used for resolution are not separately attached to model requests or logged;
the existing bounded screen-context envelope is unchanged and can itself
contain visible URLs. Preserve the current model and provider choices.

## Supersedes / superseded by

Extends the Smart editor's presentation contract for recognized destinations.
The screen-context envelope mentioned above was removed on 2026-11-22: see
[2026-11-22-smart-no-window-context.md](2026-11-22-smart-no-window-context.md).
Its meaning preservation, strict failures, Retry and Decision contracts remain.
