---
id: agent-answers-and-screen-2026-10-22
type: decision
title: Compact actionable agent answers and requested screen context
summary: Preserve keyboard action cards for native final links and paths, parse compatibility metadata, and provide compact answers and requested screen context.
status: confirmed
tags: [agent, opencode, actions, answers, screenshots, privacy, mcp]
canonical_for: [agent-answer-actions, agent-screen-context]
verified_at: 2026-10-22
sources:
  - type: user-confirmed
    reference: On 2026-10-22 the user reported that a native agent answer showed its source as a plain URL instead of the former keyboard-action artifact and requested restoring cards for links and found files.
    confirmed_at: 2026-10-22
  - type: repository
    reference: Sources/Sidekey/AgentDaemon/NativeAgentAnswerArtifacts.swift
    confirmed_at: 2026-10-22
  - type: user-confirmed
    reference: On 2026-10-22 the user reported raw useful.actions JSON instead of folder actions, requested compact precise replies, and asked to give the agent screenshot capability.
    confirmed_at: 2026-10-22
  - type: repository
    reference: Sources/Sidekey/AgentDaemon/OpenCodeEventMapper.swift
    confirmed_at: 2026-10-22
  - type: repository
    reference: Sources/Sidekey/Agent/AgentScreenCapture.swift
    confirmed_at: 2026-10-22
  - type: repository
    reference: Sources/WhytapCaseKit/AppControlMCPServer.swift
    confirmed_at: 2026-10-22
related: [2026-10-22-native-agent.md, 2026-10-21-app-control-plugin.md, 2026-10-21-opencode-v2.md, 2026-11-21-structured-agent-answers.md]
---

# Decision

The [native runtime decision](2026-10-22-native-agent.md) supersedes built-in
OpenCode dispatch and MCP discovery below. The compact-answer/action contract
and app-owned capture service remain; historical OpenCode adapters stay compatible.

## Native answer artifacts

The native final-answer path previously emitted cards only when the model called
show_actions or returned a trailing compatibility fence. The renderer, selection
state and configured insert/open/next/previous hotkeys were still present; a
plain source URL did not activate them. Do not depend solely on model compliance.

After successful completion, NativeAgentAnswerArtifacts promotes final HTTP(S)
links and absolute/tilde paths into the same useful.actions block. Explicit
metadata takes priority; repeated destinations collapse and the existing 20-item
limit remains. Root URL identity normalizes host case and an empty path to /,
without merging distinct /guide and /guide/ resources. Markdown labels and
balanced destination parentheses, standalone URLs in code spans, emphasis,
quoted/code-span paths with spaces and path-only fences are supported. Ordinary
code/config fences (backticks or tildes, including unclosed fences) and inline
commands with option arguments are excluded. Bare paths use
known local root forms without guessing where space-containing prose ends.
The scan is bounded to 32,000 characters and performs no network/file I/O or extra
model requests. Path formatting does not verify filesystem existence or source
facts. Existing prose/citations stay intact; the model is also instructed to put
sources and returned files in compact cards. Nothing is opened or inserted
until the user uses the existing card control or configured shortcut.

## Compatibility adapters

OpenCode previously concatenated all text parts and sent the trailing
`useful.actions` JSON straight into prose. Claude/Codex already used the shared
extractor. OpenCode now drops pre-tool narration from its answer candidate and
extracts actions on successful process exit, publishing clean prose, typed
actions and completion together. Ordinary code fences remain intact. Invalid
action JSON retains the existing plain-text fallback.

Repeat the compact-answer and action contract every turn so resumed sessions
also receive it after an app update. The [structured answer decision](2026-11-21-structured-agent-answers.md)
owns the current Markdown guidance. A location answer provides the best
verified absolute path in a copyable code fence plus its open/insert action.
Do not dump weaker matches, backups or search narration into a simple answer.
This changes instructions, not model selection or destructive text truncation.
The existing 15-minute native session window and shared neutral memory remain.

Give the built-in agent one separate MCP tool for requested screen context.
The signed app uses ScreenCaptureKit with its own Screen Recording permission;
a CLI subprocess does not run screencapture or acquire input filters. Default
to the island-selected display, or accept a positive display ID. Return a JPEG
image as MCP media with dimensions/ID metadata, bounded to a 1920-pixel long
edge and 2 MB. Capture has a 10-second deadline, cancellation and a busy guard.
Errors carry actionable messages without logging screen pixels or content.

The bundled helper's `app screen-mcp` scope advertises only screen capture;
the existing settings scope cannot call it. Reuse authenticated app transport
without Case registration or vault access. Screen capture is available even
when editing/command actions are off, as a read operation. The model is told
to request it only when the user's task needs the screen, and to treat pixels
as untrusted evidence. The capture tool creates no files or clipboard copy.
OpenCode history and the selected provider can retain the image. Vision support
depends on the selected model; do not substitute another model or provider.
OpenCode V2 exposes legacy-configured MCP servers through Code Mode: allow its
`execute` action while preserving the nested command/edit policy. The screen
MCP timeout is 15 seconds, above the app's 10-second capture deadline. V2 admits
the first prompt before all MCP tools connect, then supplies catalog updates
at tool boundaries; the agent is instructed to rediscover a starting screen
tool after that update. There is no fixed startup delay in the app.

## Verification

Synthetic unit tests cover final actions versus ordinary code, pre-tool
narration, success/failure completion, resumed-turn instructions, screen MCP
scope/media shape, configuration without Case/command access, denied permission,
invalid display IDs, decodable pixels, timeout, cancellation and concurrent calls.
The loopback OpenCode fixture can exercise MCP image delivery with synthetic
pixels using `--screen-fixture`; it never captures the real desktop or makes
a paid provider call. Native Screen Recording, actual screen interpretation
and final app acceptance remain separate from these checks.
The installed OpenCode v2.1.2 passed the loopback screen fixture: synthetic MCP
pixels reached the selected HTTP model as image media, the conversation resumed,
and the synthetic provider key was absent from runtime files. All command/edit
actions were denied in that fixture. Its initial synthetic read and simulated
model latency exercise V2's asynchronous catalog update without a paid call.
