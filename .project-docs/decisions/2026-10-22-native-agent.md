---
id: native-agent-2026-10-22
type: decision
title: Native Whytap agent with Tavily search and a dedicated workspace
summary: Replace OpenCode dispatch with a bounded direct model/tool loop, preserve selected routes and memory, and configure Tavily independently.
status: confirmed
tags: [agent, native, tavily, search, workspace, context, actions, privacy]
canonical_for: [agent-runtime, agent-web-search, agent-workspace]
verified_at: 2026-10-26
sources:
  - type: user-confirmed
    reference: On 2026-10-26 the user approved removing the card-description language sentence from the native system prompt after replica runs showed Russian/German descriptions for English requests.
    confirmed_at: 2026-10-26
  - type: user-confirmed
    reference: On 2026-10-23 the user reported a system beep when releasing Agent in text and voice modes while submission still worked, and requested a fix.
    confirmed_at: 2026-10-23
  - type: repository
    reference: Sources/Sidekey/Agent/SelectionCopyAvailability.swift
    confirmed_at: 2026-10-23
  - type: repository
    reference: Sources/Sidekey/Agent/SelectionFallback.swift
    confirmed_at: 2026-10-23
  - type: user-confirmed
    reference: On 2026-10-22 the user requested the selected model author's logo instead of the generic star while speaking to Agent, with inexpensive OpenRouter artwork refresh. They explicitly chose the existing voice mark rather than model-list decoration.
    confirmed_at: 2026-10-22
  - type: repository
    reference: Sources/Sidekey/AgentDaemon/AgentModelBrand.swift
    confirmed_at: 2026-10-22
  - type: repository
    reference: Sources/Sidekey/AgentDaemon/AgentModelIconStore.swift
    confirmed_at: 2026-10-22
  - type: user-confirmed
    reference: On 2026-10-22 the user corrected the Tavily setup location; all API keys belong in API & Models rather than Agents. Keep the existing credential while moving the form.
    confirmed_at: 2026-10-22
  - type: user-confirmed
    reference: On 2026-10-22 the user authorized a lightweight custom agent instead of OpenCode, Tavily search, fast initialization and a dedicated workspace; approve and bypass modes are a later phase. They selected the Whytap data folder separately from source code.
    confirmed_at: 2026-10-22
  - type: repository
    reference: Sources/Sidekey/AgentDaemon/NativeAgentProvider.swift
    confirmed_at: 2026-10-22
  - type: repository
    reference: Sources/Sidekey/AgentDaemon/NativeAgentModel.swift
    confirmed_at: 2026-10-22
  - type: repository
    reference: Sources/Sidekey/AgentDaemon/NativeAgentTools.swift
    confirmed_at: 2026-10-22
  - type: repository
    reference: Sources/Sidekey/AgentDaemon/TavilySearch.swift
    confirmed_at: 2026-10-22
related: [../project.md, 2026-10-22-agent-answers-and-screen.md]
---

# Decision

## Quiet selection lookup

Both text and voice submission share the optional Cmd+C fallback for apps
whose Accessibility selection is empty. An empty selection alone no longer
justifies sending a keyboard shortcut: this can invoke an unavailable Copy
command and cause the system alert sound. First inspect the target's menu
without opening it, requiring an explicitly enabled bare Command-C item
(physical C is accepted for non-English layouts). A missing/disabled command,
unknown Accessibility state, changed frontmost app, or a Whytap-owned key window
skips the fallback and continues the request without selection. Existing AX
selection needs no fallback. No global sound setting is changed.

Menu lookup has a 120 ms work budget, a 10 ms timeout per AX message, a maximum
of 192 nodes and 64 children per node through the normal menu-item depth.
Unsupported menu layouts safely omit fallback context. The existing deferred
copy, clipboard preservation, change-count validation and watcher suppression
remain for an available Copy command. Automated fixtures verify skipped input,
focus drift, shortcut matching and preserved clipboard behavior; the user's
live text/voice sound acceptance remains separate.

## Card description language

The system prompt sets the reply language once, in its first line ("Reply in the
latest request's language"), and says nothing else about language. A second
sentence about the language of `show_actions` descriptions made the selected
model write those card titles in Russian or German for English requests.

Tested on 2026-10-26 with the motion kit's replica of this request on the
user's route (OpenRouter `anthropic/claude-sonnet-5.5`, pinned
`google-vertex/us`), query "Find the Q4 budget spreadsheet.", no Cyrillic
anywhere in the input:

- "Use descriptions in the user's language." (previous prompt): Russian; on
  2026-10-22, 8 of 9 runs Russian or German;
- "Write card descriptions in the latest request's language.": Russian in 3/3;
- "...in the same language as the text of the user request.": Russian in 2/2;
- the base prompt without Monitor/Notify sections: German;
- no sentence at all: English ("Older draft") in 2/2.

The model itself, asked why, found nothing in the conversation that justified
Russian. Rejected: rewording the rule (every wording tested failed), and
pinning descriptions to English (non-English requests should keep their own
language through the first line). The legacy CLI prompt in AgentController is
unchanged; it does not drive the native runtime.

## Voice model mark

The existing 16 pt voice ticker slot shows the selected model's author instead
of the generic native Agent sparkle. Direct OpenAI/Anthropic routes use their
own marks; OpenRouter routes use the author namespace, never the hosting provider
pin. Supported artwork covers OpenAI, Anthropic, Gemini, DeepSeek, Qwen, Mistral,
Cohere and Perplexity. Unknown authors and Auto retain the OpenRouter mark;
missing routes retain the native fallback. Google voice search and Drop marks
keep their own existing source semantics. No model, route or key changes.

PDF fallback artwork is bundled and prewarmed, so recording never waits for
network or cache reads. The optional icon task refreshes only the displayed
author's public OpenRouter image, without a key, cookies, audio or prompt.
Each mark revalidates at most weekly with ETag when available, deduplicates
concurrent requests, and persists a small disposable cache across launches.
Responses are bounded to 256 KiB and 4 seconds; failures keep usable artwork
and back off for six hours in the running process. Cache I/O runs off the main
actor, as does network byte collection; small NSImage decode/render work remains
on the main actor. Cancelled/obsolete view loads cannot replace a new model's mark.
There are no model calls or frontend-provider-registry requests for artwork.

Source snapshots in `Resources/UsefulLinkIcons/model-*` were fetched on
2026-10-22 from `https://openrouter.ai/images/icons/`: OpenAI.svg, Anthropic.svg,
GoogleGemini.svg, DeepSeek.png, Qwen.png, Mistral.png, Cohere.png and Perplexity.svg.
Their PDFs preserve the mark's aspect ratio; Anthropic's known rounded tile is
removed and its monogram cropped for the small slot (unknown replacement SVG
layouts keep the bundled fallback). Perplexity's contour uses a 3-unit stroke
for legibility at 15 pt, identically for bundled and refreshed artwork.
Island rendering uses a neutral
monochrome alpha mask. These are third-party brand identifiers, not Whytap-owned
marks. Static image paths are not a documented versioned logo API, so bundled
fallbacks remain authoritative when OpenRouter changes or refuses a path.

## Native runtime

Run Whytap Agent inside the app, reusing the controller, voice flow, island,
provider routing and Keychain. OpenCode is no longer started for built-in
requests. Keep its source and old local data for compatibility and recovery;
do not delete history or credentials. Migrate an explicitly connected OpenCode
agent to the native runtime while preserving the exact model/provider/endpoint
and action setting. A disconnected agent stays disconnected.
Keep the legacy opencode connection identifier on disk while resolving native
dispatch in memory, so restoring the retained app does not lose its connection.

Initialization reads bounded local AGENTS.md memory and recent text pairs, then
sends the selected provider one request with the entire small tool catalog.
No version probe, subprocess daemon, MCP discovery, login shell, model listing
or separate model handshake precedes it. This removes harness startup work;
it does not promise a fixed model/provider latency or eliminate model mistakes.
Connect verifies local prerequisites without a paid request; API-key acceptance
is established by the provider when a model request runs.

Use OpenRouter Chat Completions, OpenAI Responses (store:false, replay encrypted
reasoning), and Anthropic Messages. Retain native assistant/tool/reasoning items
inside each loop so call IDs, encrypted reasoning and thinking signatures remain
valid. Never switch providers/models automatically. Report provider errors
without echoing response bodies. Existing cost recording receives reported
OpenRouter charges; unreported costs remain unavailable, not zero.

The dedicated workspace is `Application Support/whytap/agent`, outside source.
AGENTS.md remains durable memory. The new native-conversation.json retains only
completed user/assistant text pairs, at most six pairs and 12,000 characters.
Reuse requires the same route/endpoint and session ID within 15 minutes. Expired
context is ignored; the file is replaced on a later successful turn, not deleted
by a timer. Tool results, reasoning and screenshot pixels remain in flight and
are excluded from this new file. Old OpenCode data remains unused on disk.
One app-owned system prompt directs compact answer-first replies, requested
screenshots and typed show_actions buttons; the legacy JSON extractor is a
compatibility fallback. A bounded final-text fallback also supplies the same
keyboard-action cards for ordinary links and returned paths when the model omits
metadata; it performs no extra provider requests or file/network I/O. It is a
bounded conversation, not an empty context for
every question. Memory, file/selection/web/tool content and pixels are evidence,
not authorization or higher-priority instructions.

Tavily has a separate Settings → API & Models → API keys key in Keychain. Save uses
GET /usage rather than a search. A failed replacement preserves the old key.
Use the same provider tile and minimal Save/Remove form as other API keys,
with the shared short accepted/rejected notice and accessibility announcement.
Clear the replacement draft when leaving the form or closing its Settings window.
The user corrected the earlier Agents location: all keys share one setup surface,
while Tavily remains separate from model routing. No Keychain migration is needed.
POST /search uses basic search, five results, no generated answer/raw pages or
images, and sends the tool query only. Cap two searches per turn and bound all
returned excerpts. Missing configuration produces a setup error; no alternative
search service is chosen. The key joins the existing encrypted credential backup
allowlist. Tavily credit cost is not added to model inference totals.

The local tool catalog covers list/read/search, HTTPS fetch, requested screenshot,
Case key names, answer actions, write and shell. Capture calls the app-owned
ScreenCaptureKit service directly; the existing MCP scopes remain compatible.
Case uses the signed helper and existing broker approvals. Register only the
native shell child PID, released at exit; never register the app PID or read
vault files directly. A gated shell startup makes that identity available before
a Case request can be sent. Commands have an isolated process group, 30-second
deadline and bounded output. Cancellation signals the group, then bounds the
output drain even if a child detached into another session. An inherited open
pipe produces an incomplete/stopped warning, never a clean Exit 0. Detached
processes may survive; persistent background jobs require a separate facility.
Do not pass model keys or unrelated app descriptors to child processes.

Preserve agent.opencode.allowActions: on permits file writes/commands under the
Mac user's permissions; off omits and rejects them. The UI names that concrete
behavior. Approval prompts and bypass modes are explicitly a later phase.
The overall loop has a three-minute deadline, 12 model steps, 48 tool calls,
context limits, cancellation and no automatic retries of paid calls or side
effects. This is not a filesystem sandbox.

# Validation

Use synthetic provider responses, temporary files/preferences and in-memory
keys. Verify first-request tools/exact route, each provider's tool round trip,
image format and reasoning retention, action metadata, disabled writes/commands,
Tavily auth/query/result bounds and failed replacement, HTTP body redaction,
conversation expiry/scope and shell timeout/cancellation.
Include a detached-child/open-pipe regression, signal exit status, descriptor
inheritance and rollback-compatible connection settings. Render native Settings
offscreen in both appearances without launching another app or reading keys.
Live Tavily credentials, real provider/model behavior and Screen Recording remain
separate acceptance checks in the one installed app.
