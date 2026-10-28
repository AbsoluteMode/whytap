---
id: native-agent-2026-10-22
type: decision
title: Native Whytap agent with Tavily search and a dedicated workspace
summary: Replace OpenCode dispatch with a bounded direct model/tool loop, preserve selected routes and memory, and configure Tavily independently.
status: confirmed
tags: [agent, native, tavily, search, workspace, context, actions, privacy]
canonical_for: [agent-runtime, agent-web-search, agent-workspace]
verified_at: 2026-10-28
sources:
  - type: user-confirmed
    reference: On 2026-10-28 the user approved structured Agent completion with a required answer, separate source cards, explicit uncertainty and application validation after a source-only response.
    confirmed_at: 2026-10-28
  - type: repository
    reference: Sources/Sidekey/AgentDaemon/NativeAgentFinalAnswer.swift
    confirmed_at: 2026-10-28
  - type: repository
    reference: Tests/SidekeyTests/AgentDaemon/NativeAgentFinalAnswerTests.swift
    confirmed_at: 2026-10-28
  - type: user-confirmed
    reference: On 2026-10-27 the user reported that greetings succeed but tool-using requests fail and explicitly requested diagnostic logs. The repeat was on installed 1601, before the canonical-continuation fix was promoted.
    confirmed_at: 2026-10-27
  - type: user-confirmed
    reference: On 2026-10-27 the user reported an Agent HTTP 400 after changing the model. Safe app-control metadata identified Qwen 3.8 27B pinned to Cerebras FP16; the original error body was not retained.
    confirmed_at: 2026-10-27
  - type: user-confirmed
    reference: On 2026-10-27 the user reported a currency-conversion follow-up that showed only a source card and requested a joint Claude Code investigation and a fix preserving useful recent context.
    confirmed_at: 2026-10-27
  - type: repository
    reference: Tests/SidekeyTests/Agent/AgentControllerHistoryTests.swift
    confirmed_at: 2026-10-27
  - type: repository
    reference: Tests/SidekeyTests/AgentDaemon/NativeAgentTests.swift
    confirmed_at: 2026-10-27
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

## Structured completion

From 2026-10-28, native Agent completes only through a sole `finish_answer`
function call. Its closed schema requires `status`, `answer`, `sources` and
`actions`. The status is answered, unverified or needs_clarification. Sources
carry title/HTTP(S) URL; actions carry an absolute path or copyable text and a
description. The renderer reuses the existing text and keyboard-action cards;
there is no new UI-block or persisted conversation schema.

Use strict schemas across the Agent tool catalog and require the terminal
completion in application code. Optional inputs remain nullable with their existing defaults; numeric
offset limits stay locally checked. Uniform strict mode avoids endpoints that
reject mixed strict/non-strict tools. OpenAI and non-Anthropic OpenRouter routes
request required tool choice. Direct Anthropic and Anthropic-authored OpenRouter
models use auto with strict tool schemas: current Claude Opus 5.5, Sonnet 5.5,
Fable 5.1 and Mythos 5.1 reject forced any/tool choice with HTTP 400, irrespective
of thinking settings. This compatibility policy applies to the whole Anthropic
route family rather than attempting a model downgrade or retry. Plain free-text
completion under auto is still rejected by Whytap without a paid repair.
OpenRouter retains the exact model and endpoint pin and requires parameter support. A terminal call mixed with any other call fails before that
batch executes. Completion does not require another model request or a terminal
tool-result round trip. The shared model's default remains automatic tool choice,
so Meeting Assistant retains its existing output contract.

Rationale: the selected Qwen/Cerebras endpoint's public OpenRouter parameter
list on 2026-10-28 advertises tools and tool_choice but not response_format.
Cerebras documents strict tool calling for Qwen 3.8 27B, without string patterns
or length constraints. A terminal function fits that route and the existing
agent loop without selecting another model/provider or relying on a provider's
free-text final after separate presentation calls. The schema uses required
closed objects and basic types; lengths and URLs are checked locally.

Whytap validates every field, including unknown keys, nonempty answer text,
status, URL credentials/scheme/host, absolute paths and the combined 20-card
limit. A bounded format check rejects URL-only lists and common English/Russian
source headings. Unverified and clarification statuses get visible app-owned
labels. Invalid output never becomes successful UI/history or conversation
memory; an explicit error replaces it. There are no automatic paid repairs or
repeated actions. If edits/commands were attempted before an invalid completion,
the error warns that those operations may have completed before manual retry,
including malformed argument JSON rejected by the model decoder before terminal
validation. Provider/transport failures after attempted actions retain the same
warning with static safe error text; cancellation remains silent.

This is a structural contract, not proof of factual correctness or a general
semantic grader. It cannot detect every evasive sentence or invented fact in a
valid answer. Endpoint enforcement can vary; local validation is unconditional.
Refusals, unsupported strict tool use and malformed responses stay failures.
No live paid provider request was used to establish end-to-end behavior.

The 2026-10-27 fallback from prose beside show_actions to an empty free-text
final is superseded. show_actions is no longer offered in native Agent; a stale
call only requests the new final shape and does not publish cards. Intermediate
prose remains hidden. The bounded text-artifact fallback still adds missing
cards after a validated completion, without network or file I/O. Recent answer,
card destination, copy-payload exclusion and History persistence rules remain.
Explicit requests for only links/cards still require a brief answer field.

Contracts: [Cerebras strict tool calling](https://inference-docs.cerebras.ai/capabilities/tool-use),
[OpenRouter parameter requirements](https://openrouter.ai/docs/guides/routing/provider-selection),
[OpenAI structured function calling](https://developers.openai.com/api/docs/guides/function-calling),
[Anthropic strict tool use](https://platform.claude.com/docs/en/agents-and-tools/tool-use/implement-tool-use),
[Anthropic tool-choice restrictions](https://platform.claude.com/docs/en/agents-and-tools/tool-use/define-tools#forcing-tool-use).

Synthetic fixtures verify terminal completion in all three wire formats,
required/auto tool-choice policy and strict flags, preserved
endpoint/credentials/reasoning, Claude auto request bodies and rejected free-text
finals without retries, missing fields,
source-only finals, invalid cards, mixed final/write batches, malformed final
JSON after a successful write, no automatic retry,
visible uncertainty, retained follow-up values and copy-payload exclusion.
Actual chosen-model behavior remains ordinary acceptance in the shared app.

## Provider continuations

OpenRouter tool continuations replay a canonical assistant message. Tool IDs
and already-valid JSON argument string values are preserved exactly; tolerated
object arguments are encoded as JSON strings before replay. Response-only
extensions such as tool-call indexes are omitted. Ordered `reasoning_details`
are retained without alteration; plaintext reasoning (including its legacy
alias) is used only when those details are absent, avoiding duplicate forms.
OpenAI Responses and direct Anthropic native items remain unchanged. The common
NativeAgentModel also serves Meeting Assistant, so these OpenRouter changes
apply to its route as well; its tool access and capture policy do not change.

OpenRouter error responses are read only into bounded transient memory
(at most 16 KiB for a non-success HTTP response). Fixed, allowlisted error
categories produce static messages; unknown metadata, upstream messages,
raw payloads and arbitrary provider codes are never echoed, persisted or
logged. Existing authentication/credit/rate-limit status handling stays
immediate. Unknown errors retain the generic status message.

A non-streaming response can contain an error despite HTTP 200, either at
the root or on a completion choice. The model layer records any reported
usage before rejecting that response, so it cannot become a completed answer
or silently lose a reported charge. No retry or provider/model substitution
is added. The selected provider pin and tool-result IDs remain unchanged.

The reported Qwen/Cerebras failure followed a web-search tool call. The
original provider error body and intermediate response were not retained;
the exact rejected field is unknown. Canonical replay addresses a demonstrated
serialization defect, while avoiding duplicate reasoning is a compatibility
measure. Synthetic request-shape/error/privacy fixtures do not establish that
this particular live HTTP 400 is resolved. Pin-specific context limits are a
separate concern and are not changed here.

Contracts: [OpenRouter tool calling](https://openrouter.ai/docs/guides/features/tool-calling),
[reasoning preservation](https://openrouter.ai/docs/guides/best-practices/reasoning-tokens),
[typed errors](https://openrouter.ai/docs/api_reference/errors-and-debugging),
[Cerebras tool use](https://inference-docs.cerebras.ai/capabilities/tool-use).

## Local diagnostics

The common native model loop writes a request event and an accepted/failed
event to macOS unified logging (`com.rootwise.sidekey`, category `native-agent`).
Default/error levels support retrospective inspection without a live log
stream. The operating system owns retention; there is no new file, network
destination or provider request. Tavily HTTP calls are not model events.

Events contain only a locally generated turn UUID, request ordinal, closed
provider/feature enums, pin presence, timings, byte/count metrics, tool names
from a fixed enum, tool-call/result matching counts, argument/reasoning shape,
finish/status enums and allowlisted error categories. Direct OpenAI/Anthropic
tool pairing and Meeting Assistant feature scope are represented separately.
The route strings, external IDs, paths, prompts, arguments/results, reasoning,
images, keys and raw error text never enter events. Unknown external values
become a fixed unknown enum. The HTTP layer returns typed error metadata but
does not log shared search traffic or change user-visible error wording.

Fixed error-field keyword-presence hints may be derived from the bounded
transient provider error. They indicate mentions only, since an error can
quote input; they do not prove the rejected field or root cause. Malformed or
truncated bodies retain an explicit unparsed/truncated flag and generic status.
HTTP-200 error envelopes distinguish root and choice errors, with usage still
recorded before failure. Fixture tests place private sentinels in requests,
tool data, route IDs, reasoning and errors and verify none reach event JSON.

After an ordinary user reproduction, inspect locally:

```sh
log show --last 1h --style compact --predicate 'subsystem == "com.rootwise.sidekey" AND category == "native-agent"'
```

Compare request ordinals within one local turn UUID. A successful fixture or
an installed logging build does not establish that the live provider failure
is resolved; that remains ordinary user acceptance after promotion.

## Follow-up context

Completed conversation pairs include the answer and returned card descriptions
and destinations that are absent from its prose. This preserves references to
earlier values, pages or files. Copy cards contribute only their description
(or a generic label), never their payload, to supplementary memory. The same
route, session ID, six-pair / 12,000
character limit and 15-minute expiry still apply. Raw tool output, reasoning
and screenshot pixels remain excluded. The prompt directs follow-ups to use
recent answers and treats cards as supplements to requested explanations.
Structured completion now supplies the requested text and cards together.

A latest exchange larger than half the context budget is shortened with an
explicit marker, retaining the beginning and end of each side. This leaves
room for subsequent follow-ups; older pairs are evicted only after shortening.
Long selected evidence can no longer evict the current question and
answer entirely; the user request at the end of that evidence is retained.
Selected evidence remains untrusted context and can be retained in shortened
form as part of the submitted prompt.

History persistence stores the visible final text as a textAnswer block when
the provider supplied it separately from card blocks. Both the structured
history and its Markdown representation retain text and cards, without
duplicating an existing textAnswer block.

Synthetic provider fixtures verify structured completion and a currency-conversion
follow-up receiving earlier values and card targets. Oversized turns and SQLite
history retain their separate regression checks. Original intermediate provider
messages from earlier reports were not retained.

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
completed user/assistant answers including returned card descriptions and
destinations, at most six pairs and 12,000 characters.
Reuse requires the same route/endpoint and session ID within 15 minutes. Expired
context is ignored; the file is replaced on a later successful turn, not deleted
by a timer. Tool results, reasoning and screenshot pixels remain in flight and
are excluded from this new file. Old OpenCode data remains unused on disk.
One app-owned system prompt directs compact answer-first replies, requested
screenshots and structured finish_answer completion. Legacy CLI extractors remain
for compatibility; they do not replace the native completion contract. A bounded final-text fallback also supplies the same
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
