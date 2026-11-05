# Customize Whytap with your coding agent

Use a local source checkout with Claude Code, Codex, OpenCode or another coding
harness. Each reads the same architecture, commands and contracts in `AGENTS.md`
or `CLAUDE.md`. The helpers below do not depend on a particular agent provider.

For the maintainer's parallel feature sessions, first read
[Parallel development, one working Whytap](../../.project-docs/processes/shared-app-development.md).
Workers build/test in their own worktrees; one integrator updates the shared
installed app and reports its included features and acceptance steps. The
standalone launch examples below do not authorize worktree app launches in
that workflow.

Start the harness in the Whytap checkout and give it a concrete request, for example:

> Add a Monitor dashboard for my servers. Read AGENTS.md and run the customization
> discovery command first. Reuse the existing dashboard contract, keep connection
> details outside the repository, run the relevant checks and show me the result
> in the development app.

For an existing tool:

> Change the hover toolbar to show three columns. Find the shared layout and
> height calculations, preserve the user's selected tools and feature hotkeys,
> run focused checks and launch the development app so I can inspect it.

## Start here

From the checkout root, using Python 3.9 or newer:

```bash
python3 scripts/customize.py discover --json
python3 scripts/customize.py doctor --json
python3 scripts/customize.py context hover
```

`discover` returns commands, source entry points, focused test filters and
capability contracts as JSON. `doctor` checks the local macOS/Swift toolchain,
required build resources and guidance synchronization. It does not inspect
credentials or the user's transcripts. Missing prerequisites cause a nonzero exit.

| Request | Guide | Entry point |
| --- | --- | --- |
| Hover tool, ordering or rows | [Hover tools](hover-tools.md) | `Settings/HoverTool.swift`, `Settings/HoverLayoutStore.swift` |
| Custom monitoring | [Dashboard contract](dashboards.md) | passive JSON snapshot plus a separate collector |
| Settings page | `Settings/SettingsWindowTab.swift` | `Settings/SettingsWindowView.swift` detail switch |
| Persistence, keys or migrations | [Local data](local-data.md) | use existing stores rather than new raw file writes |
| Agent execution | `AgentDaemon/NativeAgentProvider.swift`, `AgentDaemon/NativeAgentModel.swift`, `AgentDaemon/NativeAgentTools.swift`, `Agent/AgentController.swift` | Direct selected model, local tools, Tavily, bounded context and action policy |
| Dictation | `Streaming/`, `PostProcessor.swift` | preserve graceful finish, retained audio and delivery recovery |
| Meeting notes | `Meetings/MeetingsCoordinator.swift` | capture, staged audio, processing checkpoints and notes |

Source paths in this table are relative to `Sources/Sidekey/`. The executable
target is `Sources/SidekeyApp/`; `Sidekey` is the internal module name.

## Edit, check, inspect

1. Read `AGENTS.md`, the focused guide and any `// WHY:` document beside the code.
2. Make the requested change on a branch. Preserve unrelated local changes.
3. Run focused tests and compile the native app without launching it:

   ```bash
   python3 scripts/customize.py test --filter 'HoverToolTests|HoverLayoutStoreTests'
   swift build --product Sidekey
   ```

4. Supply a short acceptance checklist for the shared app's integrator. Inspect
   pointer clicks and keyboard activation when changing hover controls, and
   compare the visible window with the requested flow after safe integration.
5. Review `git diff --check` and the diff. Report what was changed, what passed and
   what still needs a real meeting, server or provider to verify.

For an explicitly requested standalone customization outside parallel feature
work, `python3 scripts/customize.py build` and `run` wrap `scripts/dev-run.sh`, which packages and signs
`build/Whytap-Beta-dev.app`. They never install over the production application.
The development app still has access to some existing local stores, including
meeting notes; use injected temporary stores for automated checks. The run command
may prompt for macOS permissions. Do not launch the app with `swift run`, reset TCC
or remove user data to work around a failed check.

Add `--dry-run` to `build`, `run` or `test` to print the exact argument list without
executing it. Helpers invoke subprocesses directly; user text is never evaluated
as a shell command. Build and test locally. GitHub Actions stays disabled.

## Generate a starting point

```bash
python3 scripts/customize.py scaffold-hover --id focusTimer --title 'Focus timer'
python3 scripts/customize.py scaffold-dashboard --id custom-server-status --title 'Custom server status'
```

These create drafts under `build/customization-scaffolds/`. A hover draft contains
a small SwiftUI view, the integration checklist and source map. A dashboard draft
contains an unconnected JSON snapshot. Neither changes the running app or the
user's hover layout. Existing output directories are never overwritten. Use a new
`--output` directory when creating another draft.

## Shared guidance

Edit only `.project-docs/agent-context.md`, then regenerate both harness entry files:

```bash
python3 scripts/customize.py sync-guidance --write
python3 scripts/customize.py sync-guidance --check --json
python3 -m unittest discover -s tools/customization -p 'test_*.py'
```

This source checkout workflow is the customization interface. The installed app
does not currently download source, rewrite itself, or install a third-party
harness. Its runtime agent and its source customization workflow are separate
entry points, both controlled by the user.

For monitoring requests, the built-in agent also receives
`WhytapCustomizationContext.promptInstructions`: resolved user-local directories,
the passive JSON schema, collector boundaries and source-kit navigation. It can
create a custom dashboard directly from that contract without locating a source
checkout. Changes to the native app still require editing and rebuilding source.

Custom notifications: [Notify scripts and agent setup](notifications.md).

For the running app's state, model routes and supported settings, use the
[local application-control plugin](app-control.md). It changes settings through
the app's stores; editing preferences files directly does not synchronize the
live routing store.
