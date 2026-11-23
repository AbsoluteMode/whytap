import Foundation

/// App-owned instructions for the user's local agent. Paths are resolved on the
/// user's Mac, never embedded from a developer's source checkout or logged.
enum WhytapCustomizationContext {
    /// Repeat the discovery pointer on every turn, including resumed CLI sessions.
    static var notificationInstructions: String {
        """
        Whytap Notify supports agent-configured local script notifications to the
        left of the island. Setup contract on this Mac: \(NotifyPaths.root.appendingPathComponent("README.md").path)
        Registry: \(NotifyPaths.sources.path). Write a <source-id>.json manifest with
        id, name, command (literal argv, absolute executable), optional enabled,
        intervalSeconds, tint (#RRGGBB), logo, duration. The app runs these scripts
        only during its lifetime, stops their process groups on quit, and accepts
        one flushed JSON object per stdout line: title, optional body/id/tint/logo/
        duration/link. Read the local guide for limits, credentials, deduplication,
        validation and verification before installing. Ask the user for the source,
        filters and required authorized access; never invent a working connection.
        """
    }

    static var promptInstructions: String {
        """
        Whytap customization capabilities:
        You can help the user customize Whytap and add local monitoring dashboards.
        Monitor data directory on this Mac: \(MonitorPaths.root.path)
        Custom snapshot directory: \(MonitorPaths.dashboards.path)
        Optional Server status configuration: \(MonitorPaths.servers.path)

        Custom dashboards are passive JSON files named <id>.json in the snapshot
        directory. The app rereads them; no app rebuild is needed. The JSON root has
        id, title, optional subtitle/systemImage/accentHex/preferredWidth/preferredHeight,
        optional updatedAt (ISO 8601 with seconds and timezone), optional
        staleAfterSeconds (default 60), and widgets. Use a unique id containing letters,
        digits, dot, underscore or hyphen; start with a letter or digit. The id
        server-status is reserved for Server status. Monitor starts with no
        dashboards: it lists only what the user or their agent added. The user can delete any
        dashboard in Monitor, Server status included; its id is then listed in
        removed-dashboards.json in the Monitor data directory and hidden (Server status
        stops polling its servers). To bring one back, run
        `python3 scripts/customize.py restore-dashboard <id> --flavor prod` from the
        Whytap source checkout. Window bounds are
        width 320...1200, height 360...1200, freshness 5...86400 seconds. A file is
        limited to 2 MB and 128 widgets, with unique widget ids.
        A widget has id, kind (metric/progress/status/text/chart), title and optional
        value (string), unit, detail, progress (0...1), trendPercent, status, accentHex,
        points [{label: string, value: finite number}] (at most 512). Missing
        measurements are unavailable, never an invented zero. A missing updatedAt
        means unknown freshness; do not claim that an unconnected draft is live.
        Collectors run separately. Write snapshots atomically via a temporary file
        in the same directory, then rename; use private file permissions. Snapshot
        JSON never executes commands. Never put keys or passwords in snapshots,
        repository files, arguments or logs. Preserve unrelated dashboards.

        Server status is optional and is not listed until the user sets it up: the
        dashboard appears in Monitor only while servers.json names at least one
        server. Do not create servers.json unless the user asks to watch servers.
        It has refreshSeconds (10...3600, default 15)
        and servers [{id, name, group, sshTarget: "existing-ssh-alias"}]. Use only
        existing user-authorized SSH connections. The built-in collector obtains
        Linux CPU, RAM and supported NVIDIA GPU metrics with fixed read-only probes.
        It cannot execute custom commands supplied in JSON. Credential-store
        references can replace sshTarget with doppler: {project, config, prefix};
        it reads prefix_HOSTNAME, prefix_USER and prefix_PASSWORD in memory. Use
        one connection source per server and at most 16 servers. These are
        references, never credential values. Do not copy connection details into
        source control or alter servers
        merely to display measurements. Show connection failures and stale data.
        The user opens Monitor in hover and chooses the dashboard.

        For source changes, locate the user's Whytap checkout and read its AGENTS.md.
        Run python3 scripts/customize.py discover --json, then doctor --json for
        source entry points, contracts and local build prerequisites. The kit has
        context, scaffold-hover, scaffold-dashboard, validate-dashboard,
        install-dashboard, build, run and test commands. Source guide:
        https://github.com/AbsoluteMode/whytap/blob/main/docs/customization/README.md
        Build/run use scripts/dev-run.sh and the beta app; never use swift run to
        launch Whytap, replace the production app, reset permissions or delete user
        stores as an incidental customization step. Reviews may edit temporary
        files and run tests. GitHub Actions stays disabled; validate locally.
        """
    }
}
