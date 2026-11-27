# Whytap Assistant: plan

Date: 2026-11-26. Status: design draft, no product code. Includes the owner's
spec REV 1 (actions with confirmation) and REV 2 (one mechanism around three
problems). Waits for the decisions in
[Open questions](#12-open-questions-for-the-owner).

Checked against `origin/main` at `d8b47d3a`. External facts (MCP
specification, OpenCode, Slack, GitHub, Atlassian, Google, Telegram servers,
other apps' MCP config files) were read on 2026-11-26 and are marked
*(checked)*. Prices, latencies and rates are **targets and assumptions**, not
measurements, unless a source is named.

## 0. Three facts that change the brief

1. **The Agent is no longer OpenCode.** Since 2026-10-22 Right Command runs
   Whytap's own runtime (`NativeAgentProvider`: direct HTTP to OpenRouter,
   OpenAI or Anthropic, its own tool loop). OpenCode does support MCP
   *(checked)*, but that does not help: **Whytap needs its own MCP client in
   the native runtime.**
2. **`ProjectKnowledgeStore` and `LLMIsolationLevel` no longer exist.**
   Routing of models is `AIRouting/AIFeature`. There is no local index.
3. **Meetings have no live transcript.** Notes are transcribed after Stop.
   The live stream was deleted with the Meeting Assistant on 2026-11-05.

## 1. The mechanism (REV 2)

One loop and one local memory. Every input goes through the same loop;
every reaction of the user writes to the same memory.

```
 event ──► SKIP ──► VERDICT ──► ROUTE ──► RETRIEVE ──► COMPOSE ──► CARD
 (message,  rules +   1 cheap    memory,    1–2 scoped   1 strong    Open / Act /
  mail,     learned   call, no   no model   searches     call, only  Dismiss
  utterance, attention tools                             if needed       │
  or the user's                                                          │
  own question)                                                          ▼
      ▲                                                            FEEDBACK
      └──────────────── MEMORY (on this Mac) ◄──────────────────────────┘
          Sources: what is connected and what each tool is for
          Map:     who and what lives where
          Profile: what I answer, ignore, turn into tasks, and how I write
```

- **A question from the user** (Right Command) is the same loop with SKIP
  bypassed and the user as the event.
- **An action** (REV 1) is a CARD whose button opens a preview; execution is
  app code after Confirm (section 5).
- The three problems below are the three parts of the memory.

### 1.1 Problem 1: adding a source takes a minute

**What "a source" is for the user:** a name and a logo. They never see MCP,
tools or schemas. Under it is a connection (section 4) plus a
**source adapter** that says what each tool is for:

```
SourceAdapter {
  sourceID, name, logo
  roles: {
    search:      { tool, args: { query: "$query", from: "$person?", in: "$place?", after: "$after?" } }
    listRecent:  { tool, args: { since: "$since", mine: true } }      // for Watch and for learning
    listPlaces:  { tool, args: {} }                                    // channels, projects, repos
    getItem:     { tool, args: { id: "$id" } }
    send:        { tool, class: outward, args: { to: "$place", thread: "$thread?", text: "$text" } }
    createTask:  { tool, class: outward, args: { … } }
  }
  itemShape:  { id, link, title, text, author, place, time }   // JSON paths into a tool result
  toolHashes: { tool → hash }                                   // pinning, section 4
}
```

**Who writes the adapter**

- A **preset** ships it, reviewed (GitHub, Jira, Slack).
- For any other server Whytap writes it **once at connect**: one call of the
  Assistant model over the server's tool list (names, descriptions, schemas;
  no user data) returns the roles; Whytap then runs one harmless `search` or
  `listRecent` and shows "Found 12 items from the last week" as the proof.
  The user sees a tick, or "Couldn't work out how to search this. Fix" which
  opens the mapping for advanced users.
- Cost: one model call per connection, repeated only when the server's tools
  change.

**Approaches compared**

| Approach | User effort | Works without Whytap servers | Limits |
| --- | --- | --- | --- |
| **Import from this Mac**: read MCP servers already set up in Claude Code (`.claude.json` in the home folder, project `.mcp.json`), Claude Desktop (`claude_desktop_config.json`), Cursor (`.cursor/mcp.json` in the home folder), Codex (`.codex/config.toml` in the home folder), VS Code (`mcp.json`) *(checked: formats and locations on a real Mac)* | One click per server | Yes | Only for people who already use such tools. Local servers with a token in `env` work at once; remote servers signed in through OAuth need a new sign-in, because each app keeps its own tokens. **claude.ai cloud connectors cannot be imported**: their tokens live at Anthropic |
| **Sign in in the browser** (official remote MCP server + OAuth) | Two clicks | Only where the service accepts an unregistered or self-described client (dynamic registration or a client metadata document), or the owner registered a shared app | The service decides. Slack and Google do not accept unregistered clients *(checked)* |
| **Paste a token** | About a minute: a button opens the service's token page with scopes prefilled, paste, done | Yes | The user must be allowed to create tokens; read-only scopes are the user's care |
| **Existing sign-in on this Mac** (`gh` CLI, the Mac's calendars) | One click | Yes | Few services have one |
| **Local files** (a folder) | Drag a folder | Yes, built in, no MCP | Text files only; bounded scan like the old project index (hidden files, symlinks, credential names excluded) |
| **Custom server** | Minutes, for people who know MCP | Yes | Advanced; never the default path |

**Default flow.** "Add source" opens one sheet in this order:

1. **Found on this Mac**: importable servers, a signed-in `gh`, with one
   Import button each. Import copies secret values from the other app's
   config into Keychain; Whytap's own manifest keeps only names.
2. **Services**: tiles. Each tile takes the easiest route that exists for it:
   Sign in, else Paste a token with a deep link.
3. **Folder**, then **Custom server** at the bottom.

After any route: adapter mapping, the proof search, then two switches
("Search it when I ask", "Watch it"), the second off.

**Honest table: what "easy" can be without Whytap servers**

| Service | Easiest route today | Time | What would make it easier |
| --- | --- | --- | --- |
| Whytap meetings, To-do, Calendar | Built in | 0 | — |
| A folder | Drag it | 10 s | — |
| GitHub | Use the `gh` sign-in if present; else paste a fine-grained token (deep link) | 1 click / 1 min | A GitHub OAuth app registered by the owner gives a device-code sign-in with no secret and no server |
| Jira, Confluence Cloud | Browser sign-in to Atlassian's remote server if it accepts our client (to verify); else site, e-mail and API token | 2 clicks / 1 min | — |
| Linear, Notion, Sentry and similar | Browser sign-in (they accept self-registering clients; verify each) | 2 clicks | — |
| Slack | **Not easy.** Import if the user already has a Slack server in a coding tool. Otherwise create an internal Slack app (often needs an admin) and paste its client ID and secret | 1 click / 10+ min | A Slack Marketplace app registered by the owner: then 2 clicks plus the workspace's approval |
| Mail | **Not easy.** Gmail: Google's remote server needs the user's own Google Cloud client. Any IMAP mailbox: a third-party server plus an app password. Apple Mail on this Mac: needs a spike (Automation or Full Disk Access) | 5–15 min | A Google-verified shared client (restricted scopes, yearly assessment), or the Apple Mail spike succeeding |
| Telegram | **Not easy and most sensitive.** A community server that signs in as the user (app ID from my.telegram.org, a session with full account rights) | 10+ min | A first-party reader with a QR sign-in (bundled Telegram library and the owner's app ID): large, and it is a per-service client |

So the one-minute promise holds today for local sources, GitHub, Atlassian,
OAuth-friendly services and anything importable. Slack, mail and Telegram
need an owner decision (question 2) or stay "advanced".

**How we measure it**

- *Setup time:* stopwatch from "Add source" to the proof search, on a clean
  macOS user, per route. Target: median ≤ 60 s and ≤ 3 inputs for Import,
  Sign in and Paste a token.
- *Adapter mapping:* a fixture set of tool lists from 10 popular servers.
  Target: `search` mapped correctly with no manual fix on ≥ 8 of 10; a wrong
  mapping must fail the proof search rather than pass silently.
- *Import:* fixtures of each app's config format; every importable entry
  either connects or shows a named reason.
- No telemetry: these are acceptance checks, plus a local setup log the user
  can read.

### 1.2 Problem 2: knowing where to look

**The Map** is a small local database built from metadata and from what the
user does. It answers: "for this person and these words, which one or two
places?"

```
place   { id, sourceID, kind: channel|chat|project|repo|label|folder,
          externalID, name, keywords[≤12], lastActivityAt, myItems }
person  { id, displayName, handles[]: (sourceID, externalID | email) }
edge    { fromKind: person|term, fromID, placeID,
          seen, sent, opened, used, dismissed, lastAt }   // counters
pattern { regex, placeID | sourceID }                     // PROJ-123 → Jira PROJ; owner/repo#12; URL host
```

Stored in `Application Support/whytap/assistant/memory.sqlite`. It holds
names, IDs, counters and keywords. It does **not** hold message texts.

**How it is built, cheaply**

| Step | When | Calls | Model |
| --- | --- | --- | --- |
| **Census**: `listPlaces` per source (my channels, projects, repos, labels) | At connect, then daily | 1–3 list calls per source | none |
| **My trail**: `listRecent(mine)` or `search(from: me)`, the last ~200 items I wrote, paced under rate limits | At connect, in the background | a few paged calls per source | none: only author, place, time and distinctive words (local term weighting) are kept |
| **Keywords**: up to 12 single words per active place, in the user's languages, so "счёт" finds the place where people write "invoice" | Once per active place, refreshed when its words drift | 1 small call per ~20 places | Watcher model; the output is a validated word list, never free text |
| **Passing traffic**: every item seen by Watch or returned to Ask bumps `seen` | Continuously | 0 | none |
| **Feedback**: opened or used a result: strong plus; dismissed or Not useful: minus; "Look elsewhere…" on a card and picking a place: strongest plus | On each reaction | 0 | none |

- People are joined across sources by exact e-mail or handle, then by an
  exact normalized name; anything ambiguous stays two people.
- Counters decay (half-life about 30 days; feedback decays slower), so a
  project that ended fades by itself.

**How it is used: `route(query, people, context) → [place]`**

```
score(place) = 3.0 · personEdge + 2.0 · termMatch + 1.0 · recency
             + 4.0 · feedback  + context (same source as the event,
                                          people in the current calendar event)
pattern match → that place directly, no scoring
```

- Top place clearly ahead → search **1 place**; close second → **2 places**,
  in parallel, with a scoped query (`in:` place, `from:` person).
- Nothing confident, or the scoped search returned nothing → **widen once**
  to each enabled source's global search. Where the hit was found is written
  back as an edge. Fan-out is how the Map learns; the Map is how fan-out
  stops being needed.
- Routing is arithmetic over a few hundred rows: under 5 ms, no model. What
  to look *for* (query, person, time) comes from the VERDICT call that
  already ran, or from the user's question.

**Comparison** (5 connected sources; assumptions marked ≈)

| | Fan-out to all | The model picks tools | **Map routing (chosen)** |
| --- | --- | --- | --- |
| Searches per query | 5 | 1–3 | 1–2, then 5 only on a miss |
| Extra model calls | 1 (rerank noisy results) | 1–2 round trips to choose, with every source's tool schemas in the prompt (≈ 1–3k tokens each time) | 0 |
| Added latency | the slowest source (≈ 1–3 s) | ≈ 0.6–1.5 s per round trip | < 5 ms, then the one search |
| Rate limits | hits every source on every event; Slack search has special limits *(checked)* | moderate | low |
| Accuracy | best recall, most noise | does not know the user's channels unless we give it the Map anyway | best precision for known people and topics; needs the fallback for new ones |
| Cold start | works at once | works at once | needs census and trail (minutes), widens until it has learned |

**How we measure it**

- *Holdout from the user's own history, no hand labels.* Take the items the
  user wrote (the true place is known), build the Map on the first 80 % of
  the timeline, ask the router for the last 20 % with only the person and
  the words. Targets: the true place is in the top 2 in ≥ 85 % of cases for
  known people; average searches per query ≤ 1.6; widen rate ≤ 20 %.
- *Against the baseline:* recall of routed search ≥ 90 % of fan-out recall on
  the same cases, at ≤ 40 % of its calls.
- *Live, local only:* counters in Settings → Assistant → Memory: routed,
  widened, opened from the first place.

### 1.3 Problem 3: cheap, fast, accurate, and it knows how I reply

**Calls per incoming event**

| Tier | What it does | Model calls | Target time | Target cost | Share of events (assumed) |
| --- | --- | --- | --- | --- | --- |
| **T0 Skip** | Rules: muted places, bots, mailing lists, my own messages (they feed the Profile instead), duplicates and edits, one-word acknowledgements. Channels: only direct messages, mentions and threads I am in, unless the channel is switched to "everything". Learned: Profile attention below the floor and no mention | 0 | < 5 ms | $0 | 75–90 % |
| **T1 Verdict** | Watcher model, no tools. Input: the event (≤ 1,500 characters), 2–3 lines of thread context, the sender's card from the Map, attention hints. Output: `none`, `lookup`, `reply`, `task`, `handoff` with fields | 1 small | p50 ≤ 700 ms | ≈ $0.0001–0.0005 | 10–25 % |
| **T2 Retrieve** | Route, then 1–2 scoped searches. Exact identifier → the item directly | 0 | 0.3–1.5 s | $0 | part of T1 passes |
| **T3 Compose** | Assistant model: choose among several hits, or write the draft or proposal with the style card | 1 strong | 1–2 s | ≈ $0.002–0.01 | ≤ 3–5 % |

- **Per event on average:** about 0.2 model calls and ≈ $0.0002 (assumed
  small-model prices; the Costs journal will give the real figure).
- **Per day at 500 incoming events:** about 400 skipped, 100 verdicts, 15
  composed: ≈ $0.10, about $3 a month. Per shown card: ≤ $0.01.
- **Time to a card:** lookup p50 ≤ 2.5 s after the event is seen; a draft
  p50 ≤ 4 s. On demand ("find X"): the small model extracts the query
  (≈ 0.5 s), the router and one search return raw hits as cards (first card
  ≤ 2 s after speech ends); the strong model refines only if asked.
- **Live meeting** uses the same tiers on utterances; its numbers and the
  speech stream are in section 6.

**Models: tiers the user chooses**

| Role | Route | Tier | Default |
| --- | --- | --- | --- |
| Watcher (T1, keywords) | new `assistantWatcher` | small and fast | Not set. Turning Watch on offers "Use recommended": the small model of a provider whose key exists, from a list measured on the replay set (kept in `ModelRegistry`, like the old detector's allowed models) |
| Assistant (T3, adapter mapping, style cards, Ask) | existing `agent` | strong | The user's current choice |
| Live speech | new `assistantAudio` | realtime | Not set |

Nothing is chosen silently and no route is copied from another feature
(invariant 3). An unset optional row is not shown as "needs setup".

**Caching and skipping the model**

- *Prompt prefix:* system text, schema and profile hints are byte-stable, so
  providers' prompt caches apply; only the event is new input.
- *Coalescing:* events of one thread within 20 s become one verdict; a poll
  that brings a batch sends up to 10 events in one T1 call.
- *Verdict cache:* a normalized text hash, for repeated notifications.
- *Retrieval cache:* (place, query) → hits for 3 min, in memory.
- *Draft cache:* kept until the thread changes.
- *No model at all:* T0, exact identifiers, a single confident hit.

**The Profile: what I do with messages, and how I write**

```
attention { scope: global|person|place|kind, key,
            incoming, replied, tasked, ignored,      // counters, smoothed
            medianLatencyS }
style     { scope: global|person|place, key,
            language: { ru: 0.8, en: 0.2 }, medianChars, formality,
            emojiRate, greeting?, signoff?,           // counted locally
            card (≤ 600 chars), examples[≤3]: my own short replies,
            builtAt, fromItems }
outcome   { suggestionID, kind, action: accepted|edited|dismissed|notUseful|expired,
            editDistance, target, at }
editPair  { draft, final, at }                        // last 50
```

Same file as the Map (`memory.sqlite`).

- **Counters cost nothing.** They come from the same "my trail" pass as the
  Map: an incoming message followed by my reply within 24 h counts as
  replied; an item I turned into a task counts as tasked; nothing counts as
  ignored.
- **Style cards cost one strong call per scope**, from 20–40 of my own sent
  messages: one global card, then the 20 people and places I write to most.
  Rebuilt after 30 new sent items or weekly. Whole build: ≈ $0.01–0.05.
- **It learns from reactions.** Accept, edit, dismiss and Not useful update
  `attention`; an edited draft is stored as an `editPair`, and the next
  rebuild of that card sees the last pairs ("the user shortens, drops the
  greeting").
- **Use.** T0 skips what I reliably ignore. T1 gets the attention hints as
  a prior. T3 gets the card and examples for that person or place, the
  thread's language and my usual length. Card priority follows attention.
- **Poisoning.** Style cards are built only from messages **I sent**, never
  from incoming text. Map edges come from structured metadata and my
  actions. Place keywords are a validated word list. So an incoming message
  cannot write instructions into the memory.

**Privacy of the memory**

- Everything is in one local file with file protection; never in `os_log`,
  never sent to Whytap. It is part of the encrypted backup only.
- What reaches a model: the sender's card and attention hints (T1, Watcher
  provider); one style card with up to three of my own snippets (T3,
  Assistant provider); a sample of my sent messages when a card is built
  (Assistant provider). Each is listed in `docs/privacy.md`.
- **Settings → Assistant → Memory** shows it in plain words: Places, People,
  "What I usually answer", "How I write" (the cards are editable text).
  Delete one row, reset a section, reset everything, export as JSON.
  "Don't learn from" excludes sources or chats.

**How we measure it**

- *Triage, from history, no hand labels.* For past incoming messages the
  truth is known (I replied, made a task, or did nothing). Train the Profile
  on the first 80 %, predict the rest. Targets: of what would be shown,
  ≥ 70 % was acted on; of what was acted on, ≥ 80 % would be shown; T0 skips
  ≤ 5 % of messages I acted on.
- *Drafts.* For held-out real replies, generate a draft from the incoming
  message and compare: language matches in ≥ 98 %, length within ±50 % in
  ≥ 70 %, and a blind "which one is mine?" test by the owner on 30 pairs
  (target: the draft passes as his in ≥ 60 %). Live: sent without edits
  ≥ 40 % and the median edit distance falling over weeks.
- *Cost and speed.* From the Costs journal and local timings: $ per event,
  $ per card, p50 and p90 per tier, skip rate. Settings → Assistant →
  Activity shows the day: "412 events · 371 skipped · 38 checked · 6 cards ·
  $0.07".

## 2. What failed last time, and the rule each failure gives us

Sources: commits `54873daa`, `5becd90a`, `9b608ffa`, `93185955`, `c73f5e0a`,
closed PR #254, the decision records deleted in `c73f5e0a`, and
`docs/decisions/2026-11-05-retire-live-assistant.md` (which gives no reason
beyond the owner's request; the causes are read from the history).

| What happened | Evidence | Rule |
| --- | --- | --- |
| The strong model saw the whole transcript every 4 s | 558 Claude Sonnet 5.5 requests, $4.45, one 70-minute meeting (PR #254) | Tiers: most events cost nothing, the strong model runs last. Hard caps |
| The agreed cheap detector never shipped | PR #254 came after the bill | T0 and T1 are in the first proactive slice |
| Listening surprised the owner | Auto-listen and its reversal on the same day, 2026-10-26 | Listening is an explicit mode with an indicator; default is Ask |
| Scope: Spaces, a manifest script, a screenshot tray, a separate panel | 4,551 lines removed | One loop, one surface (island cards), presets as data |
| Thresholds from one in-sample meeting; never run live | Detector decision record | Holdout measurements and one real session are ship gates |
| A 20-character minimum lost short questions | Builder review of PR #254 | Utterances flush on a pause, never on length |

## 3. Scope and rename

**v1** = rename, sources (problem 1), Ask with the Map (problem 2), Act on
demand (REV 1). **Then** Watch with the Profile (problem 3), then live
meetings, then the hard sources.

Never in scope: a Whytap backend or relay, an account, telemetry, an
on-device LLM, an outward action without a confirmation.

**Rename.** User-facing "Agent" becomes "Assistant" (about 38 source files
*(counted)*).

- **Change:** the Features → Agent screen and checklist, the Agent card and
  Search row in Keys & models, hotkey names and Help window rows, island
  hints, permission and error copy, Costs labels, API hints, the system
  prompt's self-name, Lil Bro's answers, descriptions in the Whytap MCP
  server and Case, `README.md`, `docs/agent.md` (to `docs/assistant.md` with
  a pointer), SPEC, hotkey, privacy, architecture and customization docs,
  the landing page and videos (outside this repository).
- **Keep:** UserDefaults keys `agent.*` (including
  `agent.opencode.allowActions`), `AIFeature` raw values `agent` and
  `agentVoice`, `SettingsWindowTab.agentMode` and its `whytap://` links,
  app-control keys `agent` and `agentWorkspace`, the workspace path, Keychain
  services, Swift type names, the `native-agent` log category.
- **Also:** "agent" stays a search alias; coding tools stay "coding tools";
  a test fails on a user-facing "Agent" string outside an allowlist.

## 4. Connections (under every source)

New module `Sources/Sidekey/Assistant/Connections/`.

- **Transports** *(checked against MCP specification 2026-07-28)*: stdio and
  Streamable HTTP.
- **Subset:** `initialize`, `tools/list`, `tools/call`, `ping`,
  `tools/list_changed`, cancellation. No sampling or elicitation: a server
  cannot ask our model anything.
- **Implementation:** hand-written, a few hundred lines (the repository
  already hand-writes the server side). The official Swift SDK *(checked)*
  would add swift-nio, swift-system, swift-log and eventsource to an app with
  two dependencies; revisit if the specification outruns us.
- **stdio hosting:** as `NotifyScriptSupervisor` does: absolute path, own
  process group, parent-death guard, bounded stderr and restarts, lazy start,
  idle stop, stop on sleep and quit.
- **Bounds:** each result is clipped before a model sees it; reads have a
  10 s deadline.

| Secret | Where it lives | How it reaches the server |
| --- | --- | --- |
| stdio token | Keychain, `integration.<id>.<ENV_NAME>` | Only in that child's environment. The manifest holds names, not values. Model keys are never added |
| Remote static token | Keychain | `Authorization` header, only to that origin |
| OAuth | Keychain refresh token, rotation as in `CalendarOAuth` | Browser S256 PKCE, loopback redirect, access token in memory |

- **Imported servers** keep the command the other app used. A secret that
  the other config passed as a command-line argument is moved to Keychain and
  rebuilt into the arguments at start; the row says it is visible to local
  process listings, as it already was.
- **OAuth client identity** *(checked)*: a client ID the user supplied, else
  a client metadata document (a static JSON at an HTTPS address; the
  authorization server fetches it, the app never does), else dynamic
  registration where still offered.
- **Tool classes**, enforced in app code:

| Class | Who can call it |
| --- | --- |
| **Read** | Ask; Watch retrieval, for sources switched to Watch |
| **Local write** (Whytap To-do) | One click on the card, Undo 10 s |
| **Outward write** (send, create, hand off) | Only the executor after preview and Confirm |
| **Destructive** | Hidden in v1 |

- A server's own hints only prefill the class; presets ship a reviewed one;
  unknown tools are Outward.
- **Pinning:** a hash of each approved tool's name, description and schema; a
  changed tool asks again and the adapter is remapped.

## 5. Ask and Act

**Ask.** Right Command → the existing runtime, plus one built-in tool
`find(query, people?, after?, before?)`, which is ROUTE and RETRIEVE from
section 1. The model says what to look for; the Map decides where. Results
are the existing link cards.

**Taint rule (changes today's behavior).** Today `run_command` and
`write_file` run without asking. Once a turn has read content from a source,
that content may try to steer the model, so for the rest of the turn
`run_command`, `write_file`, `fetch_url` and web search ask for a
confirmation. App-enforced. (Question 4.)

**Act (REV 1).** A proposal is data; no model ever calls a write tool.

```
ActionProposal { kind: handoff | createTask | reply | custom,
                 title, target: ActionTarget id, arguments,
                 evidence: [SourceItemRef], reason }
ActionTarget   { name: "Whycode · sferyx", kind, sourceID, role or tool,
                 fixed: { project: "sferyx" }, slots: ["prompt"],
                 undo: { tool, from: result.id }? }
```

1. A proposal appears as a card (Watch) or as the answer (Ask: "hand this to
   sferyx", "make a task from this").
2. Click → **preview**: the exact payload, editable; the resolved target
   with its name and ID; the evidence with a link. Nothing is cut short.
3. **Confirm** (Return in the Whytap panel). Escape cancels.
4. **Send delay** 5 s with Undo (0–30 s in Settings): the one undo that works
   everywhere, including mail.
5. The executor calls the tool with the **frozen arguments the user saw**.
6. Result card with a link, and **Undo** when the target declares a
   compensating tool; otherwise "Open in …" and no promise.
7. Failure keeps the draft; no automatic retry (it could send twice).

- **Targets** come from adapters (`send`, `createTask`) and from tools the
  user marks as an action. The preview form is generated from the tool's
  JSON Schema. **Whycode is one such target through its own MCP server, with
  no Whycode code in Whytap**; its server was not inspected for this plan.
  Whytap To-do is built in.
- **Choosing the target** is the Map again: `edge(person | term → target)`
  from earlier confirmed actions preselects it; the preview always shows a
  picker. A first time is a pick, not a guess.
- **Reply recipients** come from the source item's structured fields
  (channel, thread, message ID), never from message text. A recipient
  outside the source thread is highlighted.
- **Drafts** use the Profile's style card (1.3).
- **Always confirm.** Every outward action, from Watch or Ask. No "always
  allow" in v1. One click only for a Whytap To-do.
- **Audit log:** `assistant/actions.sqlite`, local: time, trigger, proposal,
  evidence references, target, tool, final arguments, result or error class,
  undo state. Settings → Assistant → Activity, with Clear. 1,000 rows or 90
  days. `os_log` gets IDs, counts and timings only.

## 6. Watch

Watch is the loop of section 1 running on its own.

- **Inbox events:** per-source poll through `listRecent`, every 2 min by
  default, backoff on errors and limits, paused on sleep, lock, Low Power
  Mode and (by default) battery. Only items newer than the moment Watch was
  switched on.
- **Live meeting:** a realtime speech stream over system audio, only while
  listening is on. Modes: Never / **Ask each meeting** (default) / Always
  for recognised meetings; maximum 90 min, then ask again. Utterances are
  grouped by pause. Same tiers; the previous utterances are the thread.
  Targets: card p50 ≤ 3 s after the utterance; ≤ 20 strong calls per hour;
  ≤ $0.30 per hour excluding speech (the 2026-10-19 replay measured about
  $0.02 per hour for a decision model; the pilot's $3.9 per hour is the
  anti-target).
- **Caps:** hourly calls per tier and a daily spend cap. Reaching one pauses
  Watch **visibly**; no silent degradation, no model switch. Costs gets
  `assistantWatcher` and `assistantAudio`; the retired IDs stay retired.

## 7. Island surface

Reuse the notification cards (`IslandNotificationPill`) with an internal
source "Assistant".

- **Card:** logo, title, one line, primary button (Open, or the action). On
  hover: Dismiss, Snooze (15 min, this meeting, today), Not useful, and
  "Look elsewhere…" (teaches the Map).
- **Limits:** one card per 20 s, six per hour by default; an item already
  opened or dismissed is not shown again.
- **Intrusiveness:** Quiet (a dot and a list, no popups), Cards (default),
  Cards with sound.
- **Screen sharing:** a card can show a private message. Default: Quiet
  while the screen is captured. Capture exclusion of the card window on
  current macOS must be verified before relying on it.
- **Listening indicator** in the pill with time and spend; one click stops.
- **Keyboard:** an optional tool shortcut "Assistant suggestions" (unset by
  default, per `docs/hotkey.md`), one Help row.

## 8. Settings and states

- **Features → Assistant:** on/off (off by default), the checklist, "Allow
  file edits and commands" (existing key), **Sources** (add, per-source
  "Search it when I ask" and "Watch it"), **Watch** (off; sensitivity,
  intrusiveness, pause on battery, daily cap $1), **Meetings** (listen mode),
  **Actions** (targets, send delay), **Memory** (1.3), **Activity**.
- **Keys & models → Advanced → Assistant card:** Speech, Text, Watcher, Live
  speech.

| State | What the user sees |
| --- | --- |
| No sources | "Add a source to search it. Meeting notes and To-do already work." |
| Adapter not mapped | "Couldn't work out how to search this. Fix", source stays off |
| Watch on, Watcher unset | "Choose a Watcher model" with "Use recommended"; nothing is sent |
| Memory still learning | "Learning where things are: 3 of 5 sources"; searches widen meanwhile |
| Sign-in expired | Row and one card: "Slack needs sign-in again"; Watch skips it |
| Server not starting | Named cause (not found, exited, timed out) |
| Rate limited | Source paused until the time the server gave |
| Cap reached | Pill: Watch paused, Resume (one hour), Open settings |
| Tools changed | "3 tools changed. Review"; those tools ask again |
| Action failed | Draft kept, error class, Retry, Copy text |

## 9. Risks

| Risk | Mitigation |
| --- | --- |
| False positives | Decline by default, T0 and attention, limits, Not useful, holdout precision as a gate |
| Latency | No model in routing, 1–2 scoped searches, exact-ID fast path, coalescing, warm servers in a meeting |
| Cost | Tiers, caches, caps, a visible daily figure |
| The Map or Profile is wrong or stale | Widen-once fallback, decay, "Look elsewhere…", editable and resettable memory |
| Auto-mapped adapter is wrong | The proof search must pass; presets for the common services; roles shown to advanced users |
| Privacy | Per-source opt-in for Ask and for Watch; memory holds metadata and my own snippets, not archives; Quiet on screen sharing; plain text in `docs/privacy.md` that other people's messages reach the user's model provider |
| Importing other apps' servers | Only on the user's click, the exact command shown, secrets copied into Keychain, nothing written back to the other app |
| Third-party servers | Secrets scoped per server, pinning, a plain warning for account-level servers (Telegram) |
| Battery | Event-driven, pauses on battery and Low Power Mode, idle servers stop |
| Other participants' consent | Listening is deliberate and visible; the legal side is the user's, stated in the docs |
| Scope creep | One loop; each iteration has a number to hit before the next starts |

**Prompt injection: what a fooled model can and cannot do**

Assume the model will sometimes be fooled. Structure limits the damage:

- The Watcher has **no tools**; its output is a typed verdict.
- Watch retrieval has **read tools of opted-in sources only**: no web search,
  `fetch_url`, `run_command`, `write_file` or screen capture, so "read a
  secret, then send it out" has no exit.
- **No model can call a write tool.** Only the executor does, after a real
  click or Return in a Whytap-owned panel; `whytap://` links cannot confirm
  (invariant 7).
- Arguments are **frozen at preview**; recipients and targets come from
  structured metadata or configured targets.
- On demand, the **taint rule** covers tools that run without asking today.
- The **memory cannot be written by incoming text** (1.3).
- Labelling content as untrusted in prompts is the weakest layer; nothing
  relies on it alone.

What remains is a misleading card or a draft shaped by an attacker, so the
preview must show everything. **A handoff to a coding orchestrator turns a
message into an agent's prompt:** the draft quotes it with its origin
("Sveta, Slack #sferyx, 14:02") under the user's own instruction line, and
the docs say what the orchestrator's agents do with it is outside Whytap's
control.

New invariant to add with the first source: *no model output executes an
outward action; only a confirmation in a Whytap-owned surface does.* Also
update invariant 1's traffic list and the `docs/privacy.md` table.

## 10. Iterations

Effort is in focused working days for one feature session, without queue
time and acceptance. **Each iteration ends with a number**; the next one
starts only when it is met or the owner decides otherwise. Real model calls
for holdout runs need the owner's go-ahead for the spend (a few dollars).

| # | Builds | Validates | Check | Effort |
| --- | --- | --- | --- | --- |
| **0. Rename** | Strings, docs, guard test | — | Saved settings and routes unchanged | 1 day |
| **1. Sources** | MCP client, Keychain secrets, classes and pinning, adapter auto-mapping with proof search, Add source sheet: Import from this Mac, `gh`, paste a token (GitHub, Atlassian), folder, built-in sources | **Problem 1** | Median ≤ 60 s and ≤ 3 inputs from "Add source" to the proof search; `search` mapped without a fix on ≥ 8 of 10 fixture servers. Owner: import what Claude Code already has, add GitHub and a folder | 6–8 days |
| **2. Map + Ask** | Census, my trail, keywords, router, `find`, feedback, Memory screen (Places, People), taint rule | **Problem 2** | Holdout on the owner's history: true place in top 2 ≥ 85 %, ≤ 1.6 searches per query, recall ≥ 90 % of fan-out. Owner: hold Right Command, "what did Sveta send about the invoice", first card ≤ 2 s | 6–8 days |
| **3. Profile, offline** | Attention counters and style cards from my trail, the tier pipeline run as a **replay** over history (no cards shown), Memory screen ("What I answer", "How I write") | **Problem 3**, before anything pops up | Holdout: shown-and-acted ≥ 70 %, acted-and-shown ≥ 80 %, T0 false skips ≤ 5 %, ≈ $0.0002 per event, drafts match language ≥ 98 % and pass the blind test ≥ 60 %. Owner: read "How I write" and correct it | 5–7 days |
| **4. Act on demand** (REV 1) | Proposals, preview, confirm, send delay, executor, targets from adapters, Whycode as a target, audit log, drafts with the style card | Actions and safety | Injection fixtures: 0 outward calls without Confirm in the test set. Owner: select a correction, "hand this to sferyx", Confirm; a reply drafted in his style | 5–7 days |
| **5. Watch: inboxes** | Poller, live tiers, cards, limits, caps, Quiet on sharing, learning from accept, edit, dismiss | The loop, live | One week on the owner's Mac: ≥ 60 % of cards opened or acted on, ≤ 6 cards per hour, ≤ $0.15 per day, sent-without-edit ≥ 40 % | 6–8 days |
| **6. Browser sign-in** | OAuth with PKCE, client identity per question 2, Slack and other presets | Problem 1 for the hard services | Slack connected in ≤ 2 min with a shared app, or documented honestly as advanced | 4–6 days |
| **7. Watch: live meetings** | `assistantAudio` stream, listen modes, indicator, replay on ≥ 3 recorded meetings not used for tuning | The headline scenario | Card p50 ≤ 3 s, ≤ $0.30 per hour without speech, one real meeting accepted | 7–10 days |
| **8. Later** | Mail and Telegram per question 3, Apple Mail spike, Case-brokered secrets, narrower confirmations | | | open |

### The smallest slice worth shipping

**Iterations 1 and 2 together** (after the rename): add a source in a
minute, then ask and get the right item from the right place fast. It has no
background cost and no false positives, it proves problems 1 and 2 with
numbers, and iteration 3 can then measure problem 3 on real history before a
single card is shown. If only one iteration can ship first, it is iteration
1 with GitHub, a folder and Import: Ask already works over it by widening.

## 11. Rejected

- **Bringing OpenCode back for its MCP support:** a second runtime and its
  own credential files.
- **A client per service written by us:** five APIs to maintain. (A
  first-party Telegram or mail reader would be this; question 3.)
- **Fan-out to every source as the normal path:** cost, rate limits, noise
  (1.2). Kept as the fallback.
- **Letting the model choose among all tools:** extra round trips and it
  does not know the user's places (1.2).
- **A local index of messages and mail, or embeddings:** private data at
  rest, sync and deletions; there is no on-device model and a remote
  embedding route would send every message out. The Map stores metadata
  only.
- **Reusing claude.ai connectors:** their tokens are at Anthropic.
- **The official Swift MCP SDK now:** dependency weight.
- **"Always allow" for outward actions:** one injected message from sending
  as the user.
- **A Whytap relay for OAuth:** breaks invariant 1.

## 12. Open questions for the owner

1. **Is offline-first acceptable?** Iteration 3 measures triage and drafts
   on your history before any card appears, which delays the first proactive
   card by about a week. Recommended: yes; it is the check the pilot never
   had.
2. **Shared app registrations.** May Whytap register a GitHub OAuth app
   (device sign-in), a Slack Marketplace app and host one static client
   metadata file (whytap.ai or GitHub Pages; the app never contacts it)?
   Without them Slack stays a ten-minute setup. Recommended: yes for the
   file and GitHub now; Slack after iteration 2.
3. **Telegram and mail.** (a) advanced only, with a warning (recommended
   for now), (b) endorse community servers in presets, (c) first-party
   readers (a Telegram QR sign-in, IMAP), which breaks "no client per
   service" but is the only way to "a minute".
4. **Learning from your sent messages.** Building the Map and Profile reads
   your last ~200 sent items per source, and style cards send a sample of
   them to your Assistant provider. On by default when a source is added
   (recommended, with a visible line and a switch), or ask first?
5. **Taint rule.** After the Assistant reads source content in a turn,
   commands, file writes and web requests in that turn ask first.
   Recommended: yes.
6. **Confirmation strictness.** One click only for Whytap To-do; preview and
   Confirm for everything outward; no "always allow" in v1. Or should a
   Whycode handoff be one click?
7. **Listening default.** Ask each meeting (recommended) or Always.
