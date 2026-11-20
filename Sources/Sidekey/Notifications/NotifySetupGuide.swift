import Foundation

enum NotifySetupGuide {
    static func contents(directory: URL) -> String {
        """
        # Whytap Notify: local script sources

        Notifications appear as the existing compact pill LEFT of the island.
        All notifications use a text card. Hover pauses dismissal, brightens
        and enlarges the card by 3% without clipping its rounded edges. Reduce
        Motion disables enlargement. Cards retain arrival order; the
        presentation is bounded to 33 events. Legacy presentation fields in source
        manifests, payloads and history are ignored. A missing title uses the source
        name, so former icon-only sources still work as cards.
        History (including each event's color and logo) and source controls are in
        Notify. Find Notify with Search all tools or add it through Settings > Toolbox.
        History keeps the newest 500 events. Unseen events leave a red dot on
        Notify in hover/search until history is opened, including after a restart;
        Monitor is not highlighted. Clear All clears history and current events
        immediately, without confirmation, and keeps connected sources enabled.
        Settings > Notifications lists all sources with individual on/off switches
        and a speaker icon for the notification sound: Off (default, crossed out),
        Glass, Ping or Pop. Choosing a sound plays a preview. Only new accepted arrivals sound; duplicates, restored
        history and suspended delivery stay silent. Bursts sound at most once per
        0.75 seconds. Sound follows macOS output/volume and is not a JSON field.
        No Whytap server or model request is needed to deliver a notification.

        ## Configure a source

        Ask the user which events they want, which chats/accounts or filters apply,
        and request only the access required by that integration. A request to show
        incoming messages does not authorize sending messages or changing accounts.
        Use the source's supported APIs and the user's own authorized access.
        Store credentials in macOS Keychain or their chosen credential manager.
        Never put secrets in source JSON, notification output, arguments or logs.

        Root: \(directory.path)
        Registry: \(directory.appendingPathComponent("sources").path)
        Logos: \(directory.appendingPathComponent("logos").path)
        History: \(directory.appendingPathComponent("history.json").path)

        Install an atomic UTF-8 JSON file named <id>.json in sources, mode 600.
        Required: id (1..64 letters/digits/dot/underscore/hyphen, starts alphanumeric),
        name (1..100 chars), command (argv array, first entry an absolute executable
        path). Optional: enabled (default true), intervalSeconds (5..86400), tint
        (#RRGGBB), logo, duration (2..60 seconds, default 8). At most 16 sources.
        Working files/cursors should be private files under the notification root.
        Preserve unrelated sources and notifications.

        Example source (use actual paths on this Mac):
        {"id":"example","name":"Example","command":["/bin/zsh","/absolute/path/example.zsh"],"tint":"#299FD6","logo":"paperplane.fill","intervalSeconds":30}

        Whytap supervises the command while the app runs, including with the drawer
        closed. No shell interpolation is performed: arguments are literal argv.
        Without intervalSeconds, keep the worker alive for streaming/long polling;
        clean exits restart after 5 seconds. With intervalSeconds, run one polling
        pass and exit; a successful pass repeats after that delay. Failures retry
        with bounded backoff up to 60 seconds. Sources pause on system sleep and
        restart after wake. Whytap stops the process group, including helpers,
        when the source is disabled/removed or the app quits, is killed or crashes.
        Stdin is /dev/null. Do not daemonize,
        detach, install LaunchAgents or arrange workers to survive Whytap.

        ## Emit events

        Write one UTF-8 JSON object per stdout line, and FLUSH it. Python receives
        PYTHONUNBUFFERED=1. Use stderr only for non-sensitive diagnostics; Whytap
        discards stderr and does not log script output. Maximum line 64 KiB and
        10 notifications/second/source; malformed lines do not become notifications.

        {"id":"upstream-event-123","title":"Message from Alex","body":"The build is ready","tint":"#299FD6","logo":"paperplane.fill","duration":8,"link":"https://example.com/message/123"}

        title has 1..200 chars; an omitted title uses the source name. Optional:
        body (up to 8000 chars), id (up to 256 bytes), tint, logo, duration, link.
        Event fields override source
        defaults. A stable id is deduplicated per source across launches while it
        remains in the retained history (500 events). Without id each event is new.
        Keep the upstream cursor/checkpoint in private storage so reconnects don't
        repeatedly deliver a backlog. Notifications aren't replayed on app launch.
        Link is optional: a pill without a link only dismisses. Links open only
        after a user click; supported schemes: https, http, tg, slack, linear,
        github, mailto, plus codex://threads/<thread-id> for an existing local
        Codex chat (no query/fragment or new-chat links), and
        claude://code/continue?session=local_<uuid> for an existing local session
        in Claude Desktop (only the one session parameter; no fragment). No
        executable, file or JavaScript links; a click never runs a command.

        logo is an SF Symbol or a local image name without extension. Put <name>.png,
        .jpg, .jpeg or .pdf (at most 2 MiB) in logos; no paths or remote image URLs.
        Bundled brand PDFs are also available. Unknown names fall back to a monogram.
        Color/logo are persisted with the event, so history keeps its presentation.
        Bundled logos include codex and claude-code. Example completion event:
        {"id":"session-123:turn-456:done","title":"Finished","logo":"codex","tint":"#373A42","link":"codex://threads/session-123"}
        A logo alone doesn't connect Codex or Claude Code. Configure actual
        completion/needs-input signals, and use the exact originating session's
        supported link. Claude Desktop 2.42304.0 supports the continuation route
        above. Its local_<uuid> ID differs from the hook session_id: match that
        ID against cliSessionId in Desktop's claude-code-sessions metadata and
        take the record's sessionId; never just prepend local_. Other terminal
        or IDE hosts need their own supported link. Do not send prompts or
        approve operations to test delivery.

        ## Verify and maintain

        First validate the JSON and run the command once with synthetic output in
        a temporary directory. Then install the source and have it emit one uniquely
        identified setup event. Within a few seconds confirm the exact event id in
        history.json (the stored id is <source id>:<event id>). A running process
        alone does not prove delivery or a connection to the real upstream source.
        Tell the user which source/filter was connected and what was verified.
        Don't claim a Telegram connection from a synthetic test alone.

        Settings > Notifications and Notify > Sources show runtime/configuration
        errors and an enable switch. Disabling keeps the setup and event history.
        Removing a source deletes only its manifest and stops it; script files,
        credential-manager entries and notification history are preserved.
        """
    }
}
