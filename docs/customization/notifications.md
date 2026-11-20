# Custom notifications

Notify restores the compact dark notification pill to the **left of the island**,
with its logo, title, body, animated color wash and countdown. Hover pauses the
countdown; clicking opens the supplied link, or dismisses an event without a link.
Notify has persistent history and source controls. It is available from hover
search and Settings → Toolbox; saved tool layouts are preserved.

All notifications use a **text card** to the left of the island, with an
8-second default lifetime. Hover pauses dismissal, brightens the card and
enlarges it by 3% without clipping its rounded edges. Its right/top anchor
and gap from the island stay fixed; Reduce Motion disables enlargement.
Cards keep arrival order; at most 33 are presented or
queued, while every accepted event is saved to history. Small icon notifications
and the notification type selector have been removed. Legacy `presentation`
fields are ignored; sources that omit a title use their source name on the card.

Notify keeps the **500 newest notifications**. New, unseen history shows a red
dot on the Notify tool in the island's hover drawer and search; Monitor receives
no attention indicator. The dot survives temporary card expiry and app restarts,
and clears when Notify history is opened. **Clear All** clears history and current
notifications immediately, without confirmation or disconnecting sources.

**Settings → Notifications** lists every connected source, its logo and current
status and an on/off switch. Turning it off stops its script
and notifications immediately, while keeping its configuration and event history;
the switch remains off after restarting Whytap. Agent-added sources appear
automatically without reopening Settings.

Each source also has a notification sound: the speaker icon beside its switch,
crossed out while Off (the default). Click it to choose Glass, Ping or Pop. Selecting a sound plays a preview and saves that choice for
the source, including Meeting notes. Audibility follows macOS output and volume.
Only new accepted arrivals within the presentation limit sound; duplicates,
restored history and suspended delivery stay silent. Bursts play at most one
sound every 0.75 seconds. Scripts cannot enable sound through JSON output.

The built-in **Meeting notes** source needs no setup. It is enabled by default
for new and existing users and announces successful processing with Whytap's
color app icon. Settings → Notifications offers an off switch that survives relaunch. Notify → Sources also
offers the switch. Clicking a meeting event in the island or history opens that
exact note. Failures do not announce success; old notifications do not replay
on launch. This source runs inside Whytap and does not use a script slot or
require system notification permission. Its internal meeting target is not a
script payload field. External script links retain the validation below.

A coding agent can connect a source without rebuilding Whytap. Ask the agent for
the exact events you want; it requests the access and filters needed for that
source, then installs a private local script and manifest. This does not authorize
sending messages to other people. Whytap itself has no notification server or
provider-specific account setup.

## Local contract

The runtime publishes a complete guide in `notifications/README.md` inside
the bundle ID’s Application Support directory.

`<bundle-id>` is `com.rootwise.sidekey` for production and
`com.rootwise.sidekey.beta` for beta. The app's agent prompt points to the actual
resolved directory on each turn, including resumed sessions. Any local coding
agent can read that guide. Source implementation:
`Sources/Sidekey/Notifications/NotifySetupGuide.swift`.

Write `sources/<id>.json` atomically, mode 600. Required fields are `id`, `name`,
and `command` (an argv array whose first element is an absolute executable path).
Optional fields: `enabled` (true), `intervalSeconds` (5–86400), `tint` (`#RRGGBB`),
`logo`, `duration` (2–60 seconds, default 8). There are at most 16 sources.

```json
{
  "id": "example",
  "name": "Example",
  "command": ["/bin/zsh", "/absolute/path/to/example.zsh"],
  "intervalSeconds": 30,
  "tint": "#299FD6",
  "logo": "paperplane.fill"
}
```

The script writes one flushed UTF-8 JSON object per stdout line:

```json
{"id":"event-123","title":"Message from Alex","body":"The build is ready","tint":"#299FD6","logo":"paperplane.fill","duration":8,"link":"https://example.com/message/123"}
```

`title` has up to 200 characters; if omitted, the source name is shown.
Optional `body` has up to 8000 characters. Event fields override source defaults.
A stable event `id` is scoped
to the source and deduplicated across launches while retained in history (500
events). Scripts should also persist upstream cursors privately to avoid replaying
a backlog after reconnect. No historical pills replay on app launch.

A `logo` names an SF Symbol or an image in `logos/`, without its extension.
PNG, JPEG and PDF are supported up to 2 MiB; remote logo URLs and paths are not.
History keeps each event's content, color and logo. A link is optional and opens
only on a user click; supported schemes are http(s), tg, slack, linear, github
and mailto, plus `codex://threads/<thread-id>` for existing local Codex chats and
`claude://code/continue?session=local_<uuid>` for an existing local Code session
in Claude Desktop. Other agent-app actions, new-chat links and additional query
parameters are rejected. A
notification without a link simply dismisses. Clicks never execute a command.

For example, an agent source can emit a Codex completion notification:

```json
{"id":"session-123:turn-456:done","title":"Finished","logo":"codex","tint":"#373A42","link":"codex://threads/session-123"}
```

The bundled `codex` and `claude-code` logos are available. Configure a real
source of completion/needs-input events separately; choosing a logo does not
connect either app. The link must identify the exact originating session. For
Claude Code, use its supported hooks and the actual host's supported session
link. Claude Desktop 2.42304.0 uses its native `local_<uuid>` session ID for the
continuation route above. This differs from the CLI/hook `session_id`: match it
against `cliSessionId` in Desktop's local `claude-code-sessions` metadata, then
use that record's `sessionId`. Do not derive one by prepending `local_` to the
hook ID. This route was verified in the installed app's URL handler; live
navigation remains a manual acceptance check. Other terminals/IDEs need their
own supported destination. Never send a prompt or approve an operation in order
to test delivery.

## Lifetime, failures and privacy

Scripts run while Whytap is open, even when the drawer is closed. They pause on
system sleep and restart on wake. Disabling/removing a source or quitting Whytap
stops its process group, including helpers. The same happens within about a
second when Whytap is killed or crashes: a small guard process leads the group
and ends it when the app's end of its stdin closes. Scripts get /dev/null as
stdin. Do not daemonize or install a separate
LaunchAgent. Scripts that intentionally detach from their process group are
outside this cooperative contract. No shell interpolation is performed by Whytap.

A continuous script should stay alive. Clean exit restarts after 5 seconds unless
`intervalSeconds` is supplied; in that case a polling pass repeats after that
delay. Errors retry with backoff up to 60 seconds. Each source can deliver up to
10 events/second; a line is limited to 64 KiB and worker output to 1 MiB/second.
The visible queue holds 32 events; excess accepted events remain in history.

Store credentials in Keychain or the user's chosen credential manager. The
manifest, arguments and events must never contain credentials. Whytap does not
log script output and discards stderr, showing only generic failures/exit status
in Notify → Sources. Scripts are local programs running with the user's ordinary
permissions; this is not a filesystem sandbox.

Use a synthetic, uniquely identified event for setup verification, then confirm
its exact `<source-id>:<event-id>` in `history.json`. A running process does not
prove upstream connectivity. Never claim a Telegram connection based only on a
synthetic fixture. Removing a source preserves its script files, credentials and
notification history. Unreadable existing history is preserved rather than reset.

Notify workers receive `WHYTAP_NOTIFY_SOURCE` and `WHYTAP_NOTIFY_DIRECTORY`.
The original `EXODIA_NOTIFY_SOURCE` and `EXODIA_NOTIFY_DIRECTORY` aliases remain
available to existing local scripts.

## Portable backup

Keep worker files inside the owned notification directory as regular files.
Portable backup accepts printable ASCII names up to 120 bytes, without spaces,
colons, separators or a leading dot, and up to five nested directory levels.
Unsupported files fail the backup with their relative path; they are not
silently omitted. Keep secrets in the credential store rather than `.env` files.

Rebuildable dependency directories may contain a regular `CACHEDIR.TAG` whose
first 43 bytes are `Signature: 8a477f597d28d172789f06886806bc55`.
Backup excludes that directory in full and records a warning. Keep scripts,
dependency descriptors and persistent data outside it. A name such as `venv`
does not exclude anything by itself. Recreate dependencies and review executable
permissions and machine-specific paths before enabling the restored source.
