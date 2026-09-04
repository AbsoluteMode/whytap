# The CLI session id is read through the same serial queue that writes it

## Context

`ClaudeCodeProvider` and `CodexProvider` capture the CLI's session id
(`session_id` for Claude Code, `thread_id` for Codex) from a streaming JSON
line. The streaming callback fires off the main thread, so each write was
posted with `sessionQueue.async`. The read was a plain stored property, and
a comment claimed this was safe "because the caller reads after the
AsyncStream has finished".

`AgentController` reads the id at the end of every turn and passes it back
as `resumeSessionID` on the next one, which is what keeps a conversation
with the local agent continuous.

## Decision

`lastSessionID` is now a computed property that reads the backing storage
inside `sessionQueue.sync`. Writes keep using `sessionQueue.async` on the
same serial queue.

## Why

Finishing an `AsyncStream` establishes no ordering with work already
queued on an unrelated `DispatchQueue`. The write and the read were simply
unordered, and the read could observe `nil` while the write sat in the
queue. Because `sessionQueue` is serial and FIFO, a `sync` read drains
every `async` write posted before it, which is precisely the guarantee the
old comment assumed but never enforced.

The consequence in production was not a crash but a silent one: a missed
id means the next turn runs without `--resume`, and the agent starts a
fresh session having apparently forgotten the conversation. That failure
is easy to misread as a model or CLI problem.

## What we tested

The first CI runs of the public repository, on GitHub's macOS runners,
failed `ClaudeRunStreamingTests.testLastSessionIDSetFromResultLine` with
`nil` where the result line had carried an id. The same suite is green on
a fast local machine, where the queued write always lands first. After the
change the test passes on both.

## Rejected

- Sleeping in the test until the value appears: hides the race instead of
  removing it and leaves the production reader exposed.
- Making the property `atomic`-style with a lock per access: the serial
  queue already exists for `activeHandle`, so reusing it keeps one
  synchronization mechanism per provider rather than two.

2026-09-04.
