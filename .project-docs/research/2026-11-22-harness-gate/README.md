# Harness Gate research (archived, 2026-11-22)

Design-stage research for answering coding-harness permission prompts and
questions from the Whytap island. The idea: a background Claude Code or Codex
session needs approval or asks a question, a card appears at the island, and
the user answers with Y / N / A or by voice without switching windows.

**Status: paused by the maintainer on 2026-11-22.** Nothing here is
implemented or current behavior. No app code changed. This folder archives
the research, the renders and the mockup source for a later decision.

## Contents

- `0-overview.png`: the same request in the three layouts
- `1-variant-A-under-island.png`: recommended layout, six states
- `2-variant-B-left-like-notify.png`
- `3-variant-C-wing-drawer.png`
- `mockup/`: HTML mockup source. Run `python3 build.py`, then
  `python3 shoot.py` (needs Python Playwright with Chromium). Render captions
  are in Russian; card copy is in English like the app.

## Feasibility

### Claude Code (checked against v2.1.325): documented path exists

Source: https://code.claude.com/docs/en/hooks.md (raw Markdown read on
2026-11-22).

| Need | Mechanism | What can be returned |
|---|---|---|
| Permission prompt | `PermissionRequest` hook, runs when Claude Code is about to ask for permission | `hookSpecificOutput.decision.behavior` `allow` or `deny`. Deny only: `message` (note to the agent), `interrupt`. Allow only: `updatedPermissions`. This gives **Always**: `addRules` with `rules: [{toolName, ruleContent}]` and `destination` `session`, `localSettings`, `projectSettings` or `userSettings`. A hook may echo one of the `permission_suggestions` it received |
| Agent question (AskUserQuestion) | `PreToolUse` with matcher `AskUserQuestion` | `permissionDecision: "allow"` plus `updatedInput` holding the original `questions` and `answers: {"<question text>": "<option label>"}`. Documented as the way to collect the answer through your own UI |
| MCP server form | `Elicitation` hook | `action` accept, decline or cancel with content; no dialog appears |
| Idle / waiting | `Notification` (`idle_prompt`, `permission_prompt` after about 6 s, `agent_needs_input`) | Signal only, cannot answer |
| Free reply after the turn ended | `Stop` with `decision: "block"` and `reason`, or `asyncRewake` | Possible but a workaround; out of scope for a first version |

Hook input and output:
- Hook input carries `session_id`, `transcript_path`, `cwd`,
  `permission_mode`, `tool_name` and `tool_input`. Bash input has a
  human-readable `tool_input.description`, used as the card title.
- Command hooks time out after 600 s by default; each handler can set its own
  `timeout`.
- Exit 0 with no output leaves the flow unchanged, so the normal dialog
  appears.

Rules and installation:
- Deny rules beat a hook's allow, so Whytap can never approve what the user's
  rules refuse.
- Installation fits the Whytap plugin (`plugins/whytap/hooks/hooks.json`).
- Hooks from different settings files merge, and the handlers for one event
  run in parallel. Existing user hooks stay untouched.

Not documented. Run these experiments before writing code:
1. Is the terminal dialog visible while a `PermissionRequest` hook is still
   waiting? Probably not: the hook runs first and the terminal shows only its
   `statusMessage` spinner.
2. How are two `PermissionRequest` hooks combined when only one decides?
3. Do user hooks run the same way in the Claude desktop app as in the CLI?
4. Can `answers` carry free text (the Other row)?

### Codex CLI (checked against 0.171.0): partial

Sources: https://learn.chatgpt.com/docs/hooks,
https://learn.chatgpt.com/docs/app-server, and the local schema output of
`codex app-server generate-json-schema`.

- Hooks exist, including `PermissionRequest`.
  - It returns `decision.behavior` `allow` or `deny`, with `message` for a
    deny.
  - Deny wins. When no hook decides, the normal prompt appears.
  - **No Always or for-session answer through hooks:** `updatedPermissions`
    is reserved and fails closed. Codex cards therefore have no A button.
  - A user-defined hook must be trusted once in `/hooks`; trust is per hash.
  - Hooks cover Bash, unified exec, `apply_patch` and MCP tools, but not
    hosted tools such as WebSearch.
  - The docs list the CLI and the desktop app as hook surfaces.
- `notify` is informational and fires only on `agent-turn-complete`. It is a
  single slot that may already be used by another tool.
- The full native path is `codex app-server`.
  - It sends `item/commandExecution/requestApproval` with decisions up to
    `acceptForSession`, and `item/tool/requestUserInput` for questions.
  - Reaching a TUI that is already running is possible only through the
    shared daemon socket, which is undocumented (source-level only).
  - The Codex desktop app uses a private stdio server.
  - Not suitable for a first version.
- Deep link: `codex://threads/<thread-id>`. Whether a hook's `session_id`
  equals the thread ID is unverified.

### How Whytap would learn and answer

The hook is a new subcommand of the signed helper:
`Contents/Helpers/whytap gate claude|codex`.

1. It reads the hook JSON from stdin.
2. It sends a new `gate_request` operation over the existing authenticated
   broker socket: harness, `cwd` (giving repository and branch), session,
   tool, and the command or question.
3. It waits for an answer up to its own deadline (60 s).
4. It prints the decision JSON, or nothing. Nothing means the normal dialog
   appears.

If Whytap is not running, the helper exits at once with no output.

Who asks:
- The helper's parent is the hook's shell, not the harness. The
  direct-parent rule of `HarnessCallerResolver` does not fit. Use an ancestry
  walk like `CaseCallerResolver`, up to a signed Claude Code or Codex from
  `knownAIApps`.
- A forged request is harmless: the answer returns only to the process that
  asked, so it can only approve the forger's own action. The identity is
  needed for the logo and deep link, not as a security boundary.
- `HarnessAccessGate` (meeting access) is unrelated. The feature would get its
  own per-harness switch, "Answer from the island", in Settings ->
  Integrations -> Coding tools.

## Layouts

| | Placement | + | - |
|---|---|---|---|
| **A** | card under the island, Case family, island width | noticeable, everything at once, reuses the Case code and visual language | covers the top of the page until answered |
| **B** | left of the island, like Notify, stacked | whole queue visible, center stays free | reads as an ordinary notification, shares the Notify slot |
| **C** | counter in the island wing, queue in a drawer | no interruption, scales to many sessions | easy to miss, longer path to an answer |

Shared behavior (frames A1-A6):

- **Keyboard focus, the key difference from Case.**
  - Case prompts follow the user's own action. Gate requests arrive
    unsolicited while the user types elsewhere.
  - Case's tap swallows Y / N / A globally after 300 ms of keyboard quiet.
    Here that would let a typed word such as "and" press **Always**.
  - So answer keys are captured **only while the pointer is over the card**,
    or after an explicit chord (⌃⌥Space). The 300 ms arming rule then
    applies as in Case.
  - Clicking the buttons always works.
- **Card contents:**
  - harness logo, repository and branch, queue position;
  - title from `description`;
  - the command on one monospaced line, full text in the tooltip;
  - No N / Always A / Yes Y.
- **Risky commands** are matched locally: `rm -rf`, `push --force`,
  `reset --hard`, `sudo`, `curl | sh`, writes outside the repository.
  - They get a red risk line, no Always, and Yes as a 0.6 s hold of Y.
  - This is a heuristic, not a guarantee, and the card says so.
- **Always** in Claude Code defaults to `destination: "session"`, never a
  settings file. Persisting a rule would be a separate, explicit action.
- **Questions:** options on keys 1-4; a free answer by voice.
- **Voice:** holding Space over the card starts an ordinary Drop take.
  - For a permission, it becomes "No, with a note" in `message`.
  - For a question, it becomes a free answer, if experiment 4 confirms that
    `answers` accepts free text.
- **Unanswered:**
  - After 20 s the card collapses into the wing: harness logos and an amber
    counter (frame A6).
  - After 60 s the hook releases the request to the terminal.
  - Nothing is ever answered automatically.
- **Queue:** first in, first out, one visible card, shared with Case. A Case
  prompt goes first because the user caused it.

## Recommendations

Layout A, collapsing into the C wing counter (frame A6). Do not use B.

Size **M**:
- scope: Claude Code permissions and questions, Codex permissions without
  Always;
- reused: `CaseApprovalController` (queue, arming, timeout),
  `CaseApprovalView` and the helper socket;
- new: the `gate` subcommand, the socket operation, pointer-gated key
  capture, the risk classifier, the wing collapse, and the hook entries in the
  plugin and in the Codex hooks file.

Voice replies add **S**. Stop/idle replies and the Codex app-server path are a
later phase.

Risks:
1. **Approving a destructive command with one key.**
   - Mitigations: the pointer gate, hold instead of press for risky commands,
     no Always for risky commands, and Always limited to the session.
   - The classifier will miss exotic cases; Claude Code deny rules still win.
2. **A waiting hook may block the terminal dialog** (experiment 1). Mitigation:
   the 60 s deadline and an "Answer in terminal" action that releases the
   request at once and opens the session.
3. **Coexistence with other `PermissionRequest` hooks** (experiment 2).
4. **Codex needs a manual trust step** in `/hooks` and has no Always.
5. **Undocumented behavior:** the desktop app (experiment 3) and free-text
   answers (experiment 4).
