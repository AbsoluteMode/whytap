# Custom monitoring dashboards

The Monitor feature consumes declarative JSON snapshots compatible with
ez-monitor. A collector obtains real measurements and replaces the snapshot;
the renderer only displays data. Snapshot content cannot execute a shell command,
install software or grant access to a server.

## Open Monitor in hover

Select Monitor from the hover capsule, catalog search or its feature hotkey.
All three use `.openPanel(.monitor)` and show `MonitorHoverPanel` in the same
compact-width drawer. The drawer follows the actual island width (310/312-point
examples) and matches the normal controls height for the current saved tool
count. Both modes use `controlsHoverPanelHeight(toolCount:)`: six tools give a
243-point host band/235-point content; three tools give 167/159 points. Music
adds 50 points to the host band for its strip and gap. The picker stays within
that height and scrolls vertically when more dashboards are available.

Keep the Monitor heading visible and precisely centered. Equal 88-point slots
for Back and Refresh center the heading independently of button content. Choose
**Server status** or a custom dashboard; **Back** returns to the picker, then
**Tools** returns to the capsules. The picker shows dashboard choices rather
than agent setup instructions or local paths; setup belongs in this guide.
Refresh uses the existing store. The panel starts polling when shown
and stops it on disappearance, reusing `MonitorStore` and the existing collectors.
No hover launch opens a separate window; the legacy `openMonitor` callback also
requests the inline panel. The old standalone window class is retained only for
compatibility. Inline `compactPresentation` stacks server CPU/RAM/load/GPU
metrics vertically and uses one flexible custom-widget column; standalone
presentation keeps its existing defaults. The store and polling are shared.

The inline view does not change snapshot validation, collector permissions or
private storage. Historical 2.2.3 verification passed 2,947 tests (8 skipped,
0 failures) and offscreen layout/text checks for the earlier wider drawer;
actual native-pointer and Monitor-button interaction was not tested live. The
historical 2.2.4 compact-candidate checks passed 69 focused tests and the full
2,947-test suite
(8 skipped, 0 failures), plus 18 capsule/search-layout offscreen renders at
310/312 points. Those renders do not exercise live Monitor buttons. Earlier
standalone-window verification does not prove the inline route or the compact
presentation or the later Monitor height/header changes. Current verification
is recorded in the [hover decision](../../.project-docs/decisions/2026-10-17-native-hover-glass.md).
Production acceptance stays separate. Do not show GUI test windows over the
user's work; use offscreen checks.

Generate a disconnected starting point:

```bash
python3 scripts/customize.py scaffold-dashboard --id custom-server-status --title 'Custom server status'
```

## Snapshot contract

| Field | Value |
| --- | --- |
| `id`, `title` | Stable dashboard ID and display title |
| `subtitle`, `systemImage` | Description and SF Symbol name |
| `preferredWidth`, `preferredHeight` | Native window size in points |
| `accentHex` | Optional six-digit accent color |
| `updatedAt` | Optional ISO 8601 timestamp from the collector |
| `staleAfterSeconds` | Freshness window, default 60 seconds |
| `widgets` | Ordered array of widget objects |

Each widget has `id`, `kind` and `title`. Supported kinds are `metric`, `progress`,
`status`, `text` and `chart`. Optional values are `value`, `unit`, `detail`,
`progress` (0 through 1), `trendPercent`, `status`, `accentHex` and `points`
(`[ { "label": "...", "value": 0 } ]`). Unknown or missing measurements should
appear unavailable, rather than zero. No collector should present cached numbers
as a current successful connection.

Dashboard files are bounded to 2 MB and 128 widgets. IDs must be unique within
their scope. Charts support up to 512 finite points. The built-in `server-status`
ID is reserved: use a different ID for a custom snapshot. Native validation is
defined by `Sources/Sidekey/Monitor/MonitorDashboard.swift`.

See [the disconnected example](examples/dashboard.json). It intentionally has no
server endpoint, address, identity or credential. Live snapshots and private
connection configuration belong in the user's application data, outside Git.

## Collector workflow

1. Ask the user's agent to connect an existing authorized source. Keep private
   SSH aliases and authentication in the user's configuration, not in this repo.
2. Fetch bounded measurements with a timeout. Do not restart services or modify
   servers to display monitoring data.
3. Write the next snapshot to an adjacent temporary file and rename it atomically
   after a successful JSON encode. Readers should never see a partial document.
4. Set `updatedAt` from the actual measurement time. Show source failures, absent
   GPU support and stale values explicitly. Keep the last useful snapshot without
   claiming that it refreshed.
5. Inspect Monitor, choose the dashboard and verify it against the same source.

## Validate and install

```bash
python3 scripts/customize.py validate-dashboard docs/customization/examples/dashboard.json
python3 scripts/customize.py install-dashboard docs/customization/examples/dashboard.json --flavor beta --dry-run
python3 scripts/customize.py install-dashboard docs/customization/examples/dashboard.json --flavor beta
```

The installer atomically writes a mode-0600 JSON file into
`Application Support/<bundle ID>/Monitor/dashboards/` for the current user.
Beta uses `com.rootwise.sidekey.beta`; production uses `com.rootwise.sidekey`.
It rejects symlink destinations and existing files unless `--replace` is explicit.
The native loader rereads snapshots, so an external collector can keep replacing
the same file without rebuilding the app. A missing timestamp displays unknown
freshness; an old timestamp displays stale data.

## Delete a dashboard

In Monitor, Control-click a custom dashboard in the picker (or the heading of
the open dashboard) and choose **Delete…**. The confirmation's default button
is Cancel. Confirming removes the board from Monitor on this Mac: its ID is
recorded in `Monitor/removed-dashboards.json` (`{"removed": ["<id>"]}`) and the
snapshot files with that ID are removed from `Monitor/dashboards/`. The board
stays deleted when its collector writes the snapshot again, including after a
relaunch. Whytap never stops or deletes the collector, its scripts or its
launchd agent: turn the collector off yourself if it should stop running.
Server status is built in and cannot be deleted. `install-dashboard` takes the
ID off the list, so installing the dashboard again brings it back. The
snapshot and the list change together: if either cannot be written (or the list
is unreadable), both stay as they were. Whytap's Delete and the installer run
only while holding an exclusive `flock` on `Monitor/removed-dashboards.lock`.
WHY:
[decision](../../.project-docs/decisions/2026-11-21-monitor-dashboard-delete.md)

The built-in Server status collector uses separate local `Monitor/servers.json`
configuration with existing SSH aliases or credential-store references. See
`Sources/Sidekey/Monitor/MonitorServer.swift` for that contract. Custom collectors
run separately and write passive snapshots; they are not commands embedded in
dashboard JSON. Use `discover --json` for the current source entry points.

## Portable backup

Owned Monitor files use the same portable path contract as
[notification workers](notifications.md#portable-backup): regular files,
printable ASCII names up to 120 bytes without spaces, colons, separators or
a leading dot, and up to five nested directory levels. An unsupported file
fails backup with its relative path instead of being silently omitted.
Use a valid regular `CACHEDIR.TAG` only for rebuildable dependencies and caches;
the whole tagged directory is excluded. Keep collector scripts, dependency
descriptors and persistent data outside it. Recreate dependencies and review
machine-specific connections before re-enabling restored collectors.
