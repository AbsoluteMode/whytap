# Whytap agent plugin

The local `plugins/whytap` plugin runs one stdio MCP server, `whytap mcp`. It
serves live application state, models, allowlisted settings, To-do and (after
the user's Yes) meetings, plus authorized Case project and key names. Case
never returns secret values over MCP. The server does not need Accessibility,
mouse/keyboard automation, a source checkout at runtime, or provider keys in
the agent's configuration. The plugin requires a Whytap build that includes
`whytap mcp`; with an older helper use the two older commands below. Source tests do not establish
that the installed application or a host's plugin connection has been updated.

## Which client can use what

| Client | Settings, models, languages | To-do | Meetings, Vocab and Filler words | Case key names and `whytap case run` |
| --- | --- | --- | --- | --- |
| Claude Code | yes | yes | after a one-time Yes in Whytap | after **Case → Connect → Claude Code** |
| Codex | yes | yes | after a one-time Yes in Whytap | no: Case → Connect does not offer Codex, so Case refuses it (access denied) |
| Cursor | yes | yes | no (`unsupported_client`): only Claude Code and Codex are recognized | after **Case → Connect → Cursor** |
| Whytap Agent (built in) | through its own `whytap` tool (next version after 2.2.26) | same | same, without the question (you are at the Mac) | after **Case → Connect → Whytap Agent** |
| Whycode (Developer ID build) | yes | yes | no (`unsupported_client`); after a one-time Yes only the live Drop take, see [Live dictation](#live-dictation-in-an-apps-own-field) | no |
| A script, terminal or other program | yes, through the CLI or MCP | yes | no (`unsupported_client`) | no |

- Settings and model tools need Whytap running; To-do works while Whytap is
  closed. Island tools and their hotkeys (`whytap_toolbox_*`,
  `whytap_hotkey_set`) come with the next version after 2.2.26, and so do
  `whytap_vocab_add` and `whytap_filler_add`; they need Whytap running.
  `whytap_vocab_add` and `whytap_filler_add` also need, from a coding tool,
  the same one-time Yes as meetings; island tools and hotkeys
  (`whytap_hotkeys_get` came later) do not, like settings and models.
- Meetings are recognized only when Claude Code or Codex started the server
  itself (the helper's direct parent, checked by Apple-vouched signature). A
  new Codex user can use meetings after the Yes but not Case.
- The onboarding's **Coding agents** page (next version) and `claude mcp add`
  / `codex mcp add` only add the MCP server; they do not register the client
  in Case.
- With Whytap 2.2.26 or older, use `whytap app mcp` (settings, To-do,
  meetings) and `whytap case mcp` (Case) as two servers; `whytap mcp` arrives
  with the next version.

The built-in Whytap Agent is a different mechanism with its own tools,
including file edits and commands: see [Whytap Agent](../agent.md).

## Commands

The installed helper is `/Applications/Whytap.app/Contents/Helpers/whytap`.
Use `whytap mcp` for stdio MCP. The older `whytap app mcp` (application tools
only) and `whytap case mcp` (Case tools only) keep working for hosts already
set up with them. Other clients can invoke the CLI directly:

```sh
/Applications/Whytap.app/Contents/Helpers/whytap app status
/Applications/Whytap.app/Contents/Helpers/whytap app settings
/Applications/Whytap.app/Contents/Helpers/whytap app models '{"feature":"dropSmartCleanup","query":"gpt 6 sol"}'
```

| MCP tool | CLI subcommand | Behavior |
| --- | --- | --- |
| `whytap_get_state` | `status` | Live build/source, activity flags, every feature's route, the shared Speech and LLM rows (`shared`: label, Mixed, the model most features follow, custom and unset features), the Agent workspace folder (`agentWorkspace`) |
| `whytap_get_settings` | `settings` | Current supported settings and accepted values |
| `whytap_list_models` | `models` | Search the app's cached compatible models; optional account and limit (1–100) |
| `whytap_set_model` | `set-model` | Validate and select one account/model for one feature through Settings; preserve other routes. There is no shared write: set each feature of `shared.<kind>.features` the same way |
| `whytap_list_providers` | `providers` | OpenRouter endpoints for the current model; free metadata request |
| `whytap_set_provider` | `set-provider` | Validate and pin an endpoint or choose Auto (`null`) |
| `whytap_set_setting` | `set-setting` | Change one supported setting through its existing store |
| `whytap_toolbox_get` | — | The island's tools in order and every tool with its hotkey |
| `whytap_vocab_add` | — | Add words to Vocab for dictation; existing words are reported, not duplicated (needs the Yes) |
| `whytap_filler_add` | — | Add words Drop removes from dictation (Filler; needs the Yes) |
| `whytap_vocab_remove` | — | Coding tools only (not the built-in Agent): remove named Vocab entries (needs the Yes) |
| `whytap_filler_remove` | — | Coding tools only (not the built-in Agent): remove named Filler entries so Drop keeps them (needs the Yes) |
| `whytap_toolbox_set` | — | Show a tool in the island (optionally at a place) or remove it, as Settings → Toolbox |
| `whytap_hotkeys_get` | — | Every hotkey: Drop (dictation), Agent, Google search, meeting recording, link keys, Agent close, each tool, fixed keys; keys, mode, allowed modes, default |
| `whytap_hotkey_set` | — | Change one hotkey's keys and/or Hold or Toggle mode, or reset it; assign or clear a tool's hotkey; as Settings → Hotkeys |
| `whytap_todo_add` | `whytap todo add` | Add a batch or a tree of To-do tasks (statuses, parentID); confirms what was saved, retry-safe |
| `whytap_todo_update` | `whytap todo set/done/reopen` | Edit title, status, parent or completion of one task (closing cascades to subtasks) |
| `whytap_todo_list` | `whytap todo list` | List To-do tasks (active unless `includeCompleted`) |

| `whytap_meetings_search` | — | Find meetings by words and dates; note snippet and best replies with speaker and time |
| `whytap_meeting_get` | — | One meeting's note as Markdown |
| `whytap_meeting_transcript` | — | Replies by index or around a moment, paged |
| `whytap_meeting_open` | — | Show the note in Whytap |

Supported settings are `dropMode` (`fast`/`smart`), `inputLanguage` (language
code/`null` for Auto), `outputLanguage` (code/`null` for off; enabling requires
Smart) and `autoHideIsland` (boolean). `get_settings` enumerates accepted codes.
Unknown fields, settings, feature IDs and wrong types are rejected. There is
no arbitrary UserDefaults operation.

## Vocab and Filler

These are Drop's hand-filled lists, the ones the island's Vocab and Filler
editors fill. Each operation adds through that list's own store and checks,
so an open editor shows the entry and the next dictation reads it. Nothing
reads a list back. An
entry already there is reported and left as it is, so a retry is safe. One
invalid entry (empty, too long, a line break or control character) adds
nothing (`invalid_term`); joiners such as the Persian zero-width non-joiner
stay part of a word. A full list answers `list_full`. A coding tool needs
the user's one-time Yes for these, as for meetings (they change the user's
speech profile); the built-in Agent adds what your request names.

`whytap_vocab_add` takes `terms`: 1–20 words or short phrases, at most 50
characters each; Vocab holds 1,000. A term already there in any letter case
is `existing` with its saved spelling. Each speech route sends the part of
Vocab its model supports, so a saved term is not a promise that a given
model uses it (On this Mac dictation uses no Vocab). The built-in Agent
shows `Vocab + whytap` above its answer, with the spelling exactly as saved.

`whytap_filler_add` takes `terms` (1–20, at most 50 characters; the list
holds 100): words Drop removes from dictation, Fast and Smart (`um`, `ну`).
When removing them would leave a Fast take empty, Drop pastes the take
unfiltered. The Agent shows `Filler + ну`.

`whytap_vocab_remove` and `whytap_filler_remove` take `terms` (1–20) and
remove exactly those entries, matched in any letter case and without
surrounding spaces on either side (a restored backup can hold `"  Word  "`).
A removed entry comes back as `removed` with its saved spelling, trimmed; a
term that is not in the list is `missing`, which changes nothing and is not
an error. One invalid entry (empty, more than one line or longer than 50
characters) removes nothing, and there is no way to clear a whole list.
Only Claude Code, Codex and other connected coding tools get them; the
built-in Agent can add entries but not remove them. `whytap_filler_remove` makes Drop keep a word
again; to cut a word from dictation use `whytap_filler_add`. Coding tools
need the same one-time Yes.

There is no Replace list: it came with Drop learning, which was shelved on
2026-11-23.

## Island tools and their hotkeys

`whytap_toolbox_get` returns `pinned` (tool ids shown in the island, in order;
Settings always stays last and is not listed) and `tools`: every tool with
`tool`, `title`, `description`, `pinned`, `position`, `comingSoon`, `hotkey`
(`{keys, display}`, e.g. `option+s` / `⌥S`, or `null`) and
`hotkeyAssignable`. `whytap_toolbox_set` takes `tool`, `pinned`, an optional
`position` (1 is the first tool) and `expected`, the exact `pinned` list; it
uses the same layout store as Settings → Toolbox, so the island and Settings
show the change at once. Removing a tool keeps its hotkey. Settings cannot be
moved or removed (`not_movable`).

`whytap_hotkey_set` takes `tool`, `keys` (or `null` to clear) and `expected`,
the tool's current `keys` (any modifier order) or `null`. Keys follow the
`whytap://hotkey` link rule: Control or Option plus A–Z, 0–9, F1–F20 or US
punctuation, so ⌘ and ⇧ shortcuts of macOS and other apps stay free; Quit and
coming-soon tools are refused (`hotkey_not_allowed`), other keys
`invalid_hotkey`. The change goes through the Hotkeys Save path
(`HotkeyPreferences.assignToolShortcut`): keys another action uses are refused
as `hotkey_conflict` naming that action, never taken over, and refusals name
the nearest free keys (the same key with ⌥, ⌥⇧, ⌃⌥, ⌃⇧ or ⌃). An Option combo
that types a character in text fields (⌥F is ƒ on US) is assigned and the
reply's `typesInTextFields` names that character; the Hotkeys pane,
Help and the registered shortcut update at once. A repeated identical request
answers `changed: false`. Unknown tool ids answer `unknown_tool`. Provider keys, permissions, security controls,
Case contents, history, clipboard, recording, shell execution,
installation and quit are outside the application-control server.

## Every hotkey

`whytap_hotkeys_get` returns `hotkeys`: every Settings → Hotkeys row, every
tool and the fixed global keys. Each has `id`, `title`, `does`, `keys`,
`display`, `mode`, `modes`, `changeable`, `clearable`, `default`
(`{keys, display, mode}`) and sometimes `note`.

| id | Settings row | Default |
| --- | --- | --- |
| `dropVoice` | Drop voice (dictation) | `space`, hold |
| `agentText` / `agentVoice` | Agent text / voice | `right_command`, tap / hold |
| `googleText` / `googleVoice` | Google text / voice | `right_option`, tap / hold |
| `meetingRecord` | Meeting record | `option+m` |
| `linkInsert`, `linkOpen`, `linkNext`, `linkPrevious` | Links insert / open / next / previous | ← → ↓ ↑ |
| `agentClose` | Agent close | `option+q` |
| `tool.<tool id>` | Tools | none |
| `help`, `answerEscape` | — (fixed: ⌥H, Esc) | not changeable |

`mode` is `hold` or `toggle` for the voice rows (Drop, Agent voice, Google
voice; Settings shows Hold / Toggle) and `tap` for the rest. `modes` is what
the row accepts now: on Space only `hold`. Keys a Whytap window takes only
while it is open (screenshot editor, Case prompt, History) are not listed.

`whytap_hotkey_set` with `hotkey` takes `keys` (optional), `mode` (optional),
or `reset: true` (default keys and mode), and `expected`, the row's current
`keys`. "Put dictation back on hold Space" is
`{"hotkey":"dropVoice","keys":"space","mode":"hold","expected":"`"}`.
It makes the change Settings → Features makes for that row
(`FeatureHotkey.assign` / `setGesture`) and saves it through
`HotkeyPreferences.apply`, the Hotkeys Save path: the monitors re-register at
once and Settings, Help and the island hints follow. Rules:

- Keys are written, not pressed: a combo with Control or Option
  (`option+m`, `control+command+d`), a bare `f1`–`f20`, `right_command` or
  `right_option` alone, or `space` (Drop only). Other keys answer
  `invalid_hotkey`; Command- or Shift-only combos and bare typing keys
  (`` ` ``, letters) can be recorded only in Settings, so a misread request
  cannot take ⌘C or a letter from every app.
- Space is Drop's alone (`hotkey_not_allowed` elsewhere) and hold-only:
  `space` sets Hold, and Toggle on Space is `invalid_mode`. Other keys keep the
  current mode unless `mode` is given. One-shot rows accept only `tap`.
- One physical key = one action: keys or a mode another action uses (⌥M is
  Meeting record; Toggle on Right ⌘ is Agent text's tap) answer
  `hotkey_conflict`, naming that action and the nearest free keys. Nothing is
  taken over.
- Only tool hotkeys clear (`keys: null`); other rows answer `not_clearable`.
  `help` and `answerEscape` answer `hotkey_not_allowed`; unknown ids answer
  `unknown_hotkey`; stale `expected` answers `conflict`. A repeated request
  answers `changed: false`.
- The reply has `hotkey` (the row as `whytap_hotkeys_get` lists it), `keys`
  (`{keys, display}`), `mode`, `previous` (`{keys, mode}`) and `changed`; the
  built-in Agent shows `Hotkey: Drop voice — Space · Hold`.

`hotkey: "tool.<id>"` is the same as `tool` with the island-tool rules above;
`reset: true` clears it.

## Meetings and access

The meeting tools return the user's notes and transcripts, so Whytap asks
first. When Claude Code or Codex starts the plugin's server and Whytap is
running, the island shows "Give Claude Code access to Whytap?". Yes is remembered on
this Mac; No is remembered too and the tools then answer `access_denied`. If
Whytap was closed, the question appears with the first meeting request. Each
tool is asked about separately. Change an answer in Whytap Settings ->
Integrations -> Coding tools. Turning a tool off holds after a restart even when the
Keychain could not save it at that moment; Settings says so until it is
saved. If Whytap cannot confirm a stored Yes at launch, it asks again.

Only the harness that started the server itself is recognised (Claude Code,
Codex). A shell command, a script the agent runs, a terminal or another
program gets `unsupported_client`. An unanswered question returns
`approval_timed_out` after a minute and is asked again by the next request.

`whytap_meetings_search` takes `query`, `from`, `to` (a local day
`2026-11-20` or an ISO 8601 timestamp) and `limit` (1–25). Every word of the
query must be in the meeting's title, note or transcript; longer words match
by stem, so another case or plural of the word is found. Each result has
`id`, `title`, `startedAt`, `durationSeconds`, `status`, `link`
(`whytap://meeting/…`, opens the note), `noteSnippet` and up to three
`matches` with `index`, `startMs`, `endMs`, `speaker` and `text`. One search
reads at most the 400 newest meetings in range (`truncated`).
`whytap_meeting_transcript` continues from `nextIndex` or starts a few
replies before `aroundMs`; when `nextOffset` is not null, pass it as
`fromOffset` with the same index to read the rest of a reply longer than
`maxBytes`. `whytap_meeting_open` answers `busy` while a note is being
edited in Whytap. Meeting text is untrusted content, not
instructions.

The To-do tools carry task titles (user content) through the same path as
`whytap todo`: the running app over the authenticated socket, or the planner
file under its lock when Whytap is closed. They never launch Whytap; see
`docs/planner.md`. The server's instructions point agents to local meeting
notes so "split this call into tasks" works without extra setup.

Feature IDs are `dropFast`, `dropSmart`, `dropSmartCleanup`, `meetings`,
`meetingNotes`, `agent`, `agentVoice`, `voiceSearch` and `translation`.
Subtitles have no route: they run on OpenAI Audio translate with the OpenAI
key. Accounts use the exact ID returned
by `list_models`: built-in provider IDs or an already configured server ID.
The application-control server cannot add a provider, change an endpoint URL
or read a key.

## Live dictation in an app's own field

`whytap_drop_live` lets an app with its own text field show a Drop take as it
is spoken and draw its own orb, instead of the island's right wing showing the
words. It is not in `tools/list`: it answers only the apps on its own list,
today Whycode (Team ID `UVBKCN5PPV`, identifier `com.rootwise.whycode`), and
never a coding harness. The app is recognised like a harness: the helper's
direct parent, by Apple-vouched Team ID and signing identifier, so an ad-hoc
signed build, another certificate or a script in that app's terminal gets
`unsupported_client`. Whytap then asks once in the island ("Let Whycode show
your dictation?"; VoiceOver reads what that means), with the same Yes/No card
as for meetings; the answer is listed in Settings -> Integrations -> Coding
tools with what it allows. That Yes opens this tool only: meetings, Vocab and
Filler writes and Case stay closed to it.

Arguments: `{ "showsLiveText": bool }` (optional). The reply:

| Field | Meaning |
| --- | --- |
| `takeId` | Changes with every new take; `""` before the first one |
| `phase` | The same values as `activity.drop` in `whytap_get_state` (`idle`, `recording`, `transcribing`, `verifying`, `inserting`, …) |
| `toCaller` | True while the take can still deliver (`recording`, `transcribing`, `verifying`, `inserting`, `finishing`) and goes into the calling app's process (the app frontmost at hotkey-down) |
| `text` | The words so far while `toCaller`, otherwise `""`; a take into any other app never sends words, and a take that ended, failed (`deliveryFailed`) or was cancelled sends none |
| `level` | Newest raw microphone sample, 0…1 |
| `energy` | 0…1 while `recording`: the island orb's noise-floor gate and scaling, before its smoothing; 0 otherwise |

`text` is the whole take so far. Cloud speech providers send that directly.
On-device transcription re-decodes only the last ~14 s; once a take is longer
than that, Whytap keeps the words already sent and joins each new window onto
them where they overlap (by words, or by characters in languages written
without spaces; a re-decoded boundary word may change). Shorter takes are
passed through as decoded. It is a preview; the
pasted final text is what counts.

A call with `showsLiveText: true` keeps an opt-in for 1.5 s; `false` ends it.
While the opt-in holds and the take goes into that app, Whytap writes no
partials into the island's wing (the orb and phase stay). When the app stops
asking, quits or loses the take, the next partial reaches the wing as before.
The final text is still pasted by Drop (in Smart it can differ from the
partials); the app replaces its preview with it. Poll it about 10 times a
second during a take. Builds without this tool answer with `Unknown tool`
(MCP error -32602): treat that, `unsupported_client`,
`access_denied` and `approval_timed_out` as "no live text" and keep the
earlier behaviour. Nothing from this tool is logged.

## Case projects and keys

The same `whytap mcp` server serves the names-only Case tools of `whytap case mcp`:

| MCP tool | Behavior |
| --- | --- |
| `case_list_projects` | Authorized project names, descriptions and key counts |
| `case_list_keys` | Find authorized keys by name, description or project name using `query`; optionally restrict `project` |

Search directly with `case_list_keys(query: "name or description")`; listing
projects first is optional. To use a key, run the existing CLI in the agent's
own terminal, with single quotes so the outer shell cannot expand its value:

```sh
/Applications/Whytap.app/Contents/Helpers/whytap case ls
/Applications/Whytap.app/Contents/Helpers/whytap case run --only KEY_NAME '<command using $KEY_NAME>'
```

These are command templates: replace the key and command with the intended
operation. Add `-p <project>` when the same key name exists in several projects.
Case injects values into the child environment and masks recognized values in
output on a best-effort basis. MCP has no command-execution or value-read tool.
Both Case tools are marked read-only in their MCP annotations, so a host may
run them without asking; the broker still decides what each client may list.
Case keys are for the agent's own commands and are separate from the provider
keys Whytap itself uses for dictation, models and meetings (Settings -> API &
Models).

Installing the plugin or adding the server does not register the agent or
broaden its Case rights. Each Case tool call is the same broker request
`whytap case mcp` sends, so the existing client registration, project scope,
Accept/Bypass policy and approval flow still apply. An unregistered client
gets "Access denied" from the Case tools and must first be connected in
Whytap -> Case -> Connect; the application tools of the same server work as
before. Connect is offered for Claude Code and Cursor and adds this same
`whytap` server there; Disconnect removes only the older `case` entry it wrote
and leaves `whytap`. Whytap changes an entry only when it is exactly what
Whytap writes (`<helper> mcp`, or the older `<helper> case mcp`, with nothing
else). Any other `whytap` entry (your env, a disabled flag, a timeout, a tool
filter, `app mcp`, another path, another server) stays as it is: Connect shows
"Configured manually — Whytap left it as is" and changes nothing, the older
`case` entry included. To let Connect manage it, remove that `whytap` entry
and connect again. An older `case` entry left in a host still works,
but shows the Case tools twice next to `whytap`; remove it once `whytap` is
connected (`claude mcp remove -s user case`, `codex mcp remove case`).

Codex is not in the Connect list (see the 2026-10-21 Case Connect decision).
Add the server with the `codex mcp add whytap -- … mcp` line above. Its
application tools work as for any harness; its Case tools answer only if
Codex already has a registration from an earlier Whytap build (kept and
editable in Case), and otherwise return "Access denied".

## Read, change, verify

Read state/settings before writing. Every mutation requires `expected`, equal
to the complete current route or setting value. An unset route is `null`;
a configured route always has `account`, `model` and `provider` (`null` for Auto).
For example, **only if state just returned this exact route**:

```json
{
  "feature": "dropSmartCleanup",
  "account": "openRouter",
  "model": "openai/gpt-6-sol",
  "expected": {
    "account": "openRouter",
    "model": "deepseek/deepseek-v4.1-flash",
    "provider": "baseten"
  }
}
```

Pass that object to `whytap_set_model` or as the single JSON argument to
`app set-model`. Never copy the example's `expected` without reading state.
A different model starts on Auto; reselecting the same model preserves its
pin, as in Settings. Use `set_provider` to change the pin explicitly.

The response is `{ "ok": true, "data": ... }` or `{ "ok": false, "data":
{ "code": ..., "message": ... } }`. MCP also returns structured content and
an error flag. Model selection may send the same tiny synthetic paid probe
as Settings; no dictated text is used. Failed checks preserve the route.
Unknown models are not silently replaced. A manual route change during a
probe wins; a disconnected/cancelled probe cannot assign a model afterward.
The stdio reader keeps processing MCP cancellation notifications while a tool
waits; cancellation and EOF shut down the corresponding app socket. Requests
are bounded and at most 16 tool calls can be pending per MCP process.
Concurrent plugin writes return `busy`; a stale expected value returns
`conflict`. Neither is a reason to retry blindly.

Success reads back the app's store in the same process. If the connection is
lost around a synchronous commit, its outcome is unknown: read state before
retrying. A selected model applies to subsequent operations; selection alone
does not prove a real dictation or provider request succeeded.

## Install in an agent host

The repository marketplace is `.agents/plugins/marketplace.json`, pointing
to `plugins/whytap`. It follows the [official plugin packaging format](https://developers.openai.com/plugins/build/plugins)
with a [local stdio MCP server](https://developers.openai.com/plugins/deploy/desktop-only).
Use a local marketplace to install it in Codex. The package is not publicly
published and does not require a hosted Whytap service. Other MCP hosts can
configure the helper command with the single argument `mcp`.

Claude Code needs no checkout; on each Mac run once:

```sh
claude mcp add --scope user whytap -- /Applications/Whytap.app/Contents/Helpers/whytap mcp
```

Codex also needs no checkout:

```sh
codex mcp add whytap -- /Applications/Whytap.app/Contents/Helpers/whytap mcp
```

A host that already has `whytap` pointing at `app mcp` keeps working; to move
it to the one server, remove it and add it again with the line above.

To install the whole plugin with the current Codex CLI, run from this checkout:

```sh
codex plugin marketplace add .
codex plugin add whytap@whytap-local
codex plugin list --marketplace whytap-local --json
```

Start a new local chat or restart the host if its existing plugin connection
does not refresh. Installation into the plugin cache does not prove that tools
have connected to the updated Whytap app.

A connected `whytap mcp` (also `app mcp` and `case mcp`) keeps working when
Whytap is updated: on its first call after the update the helper replaces
itself with the new build's helper, in the same process, and answers that call.
No `/mcp` reconnect is needed. It runs only a helper file that fully validates
and is signed by the same signer as itself (ad-hoc source builds therefore
never switch), and gives up after three switches within two minutes. If the
update is a rollback to a build without this ability, waiting calls get an
explicit "retry" error and the following calls work. Helpers started from a
build without this change need one last reconnect.

The plugin's only runtime dependency is the installed Whytap helper. It uses
the existing private Unix socket, with bounded requests and audit-token/code
validation against the helper in the same app. Settings and To-do controls are available to
local processes running that helper as this user; they are not guarded by
Case registrations or Touch ID. Meeting tools additionally need the user's
answer for the calling harness (above). This is the local settings-access boundary,
not a sandbox for an already authorized agent. A website's `whytap://` link
cannot invoke or receive these commands. Case requests keep their existing
authorization and the app-control namespace never returns secret values.

## The built-in Whytap Agent

The Agent in the island (Right Command) has the same `whytap_*` operations:
the same names, descriptions and argument schemas, taken from the plugin's own
catalog and run inside the app by the same controller, without the helper or
an MCP server. The model sees them as one `whytap` tool (operation plus a JSON
arguments string), which keeps every provider's strict tool limits. Ask it, for example, "switch Drop Smart cleanup to
anthropic/claude-sonnet-5.5", "add a task: send the report" or "where did we
discuss the budget?". Every change still needs the exact current value, and
each confirmed change appears as one line above the answer, such as
`Drop Smart cleanup → anthropic/claude-sonnet-5.5`, `Toolbox + Shot` or
`Hotkey: Shot — ⌥S`. "Add Shot to my quick actions (hover) and give it option
f" pins the tool and assigns the keys in one line,
`Toolbox + Shot · ⌥F (no longer types “ƒ” in text fields)`; a hotkey the rules
refuse or another action uses is reported with the nearest free keys, not
moved. For a task a Whytap tool does ("take a screenshot") the Agent reads the
tools and suggests one with its hotkey, "Press ⌥S — that's Shot", instead of
macOS shortcuts; without a hotkey it points to the hover or its search and
offers to set one. It only suggests: no operation opens or starts a tool. Meetings need no harness
prompt there: the request comes from you at this Mac. The Agent still cannot
read key values, the clipboard or run commands through these tools.
