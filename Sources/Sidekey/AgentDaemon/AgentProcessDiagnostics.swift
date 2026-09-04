import Foundation

/// One-shot TCC attribution snapshot for a stuck child, captured on the
/// watchdog SOFT trigger. `lsappinfo info -only responsiblepid` returns NULL
/// when the responsible-process chain is broken (the diagnostic signature of a
/// TCC attribution failure — claude-code #59065). Runs synchronously; cheap
/// because it fires only on a (rare) hang. Never throws — returns a log line.
///
/// WHY: docs/decisions/2026-06-16-agent-turn-watchdog.md
enum AgentProcessDiagnostics {
    static func snapshot(pid: Int32) -> String {
        let responsible = run("/usr/bin/lsappinfo",
                              ["info", "-only", "responsiblepid", "\(pid)"])?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? "lsappinfo=unavailable"
        return "pid=\(pid) \(responsible)"
    }

    /// Runs a short-lived tool and returns its stdout, or nil on any failure.
    /// Bounded by `waitUntilExit` — these tools return in milliseconds.
    private static func run(_ path: String, _ args: [String]) -> String? {
        guard FileManager.default.isExecutableFile(atPath: path) else { return nil }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = args
        let out = Pipe()
        process.standardOutput = out
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        process.waitUntilExit()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        return String(decoding: data, as: UTF8.self)
    }
}
