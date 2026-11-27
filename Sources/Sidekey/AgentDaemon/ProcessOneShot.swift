import Foundation

/// Runs a short CLI command (`auth status`, `login status`) to completion.
/// Both pipes drain while the child runs, so a large output cannot block it,
/// and a child that does not exit within `timeout` is terminated.
enum ProcessOneShot {
    static func run(binary: URL, args: [String], environment: [String: String],
                    timeout: TimeInterval = 20) -> ProcessResult? {
        let process = Process()
        process.executableURL = binary
        process.arguments = args
        process.environment = environment
        process.standardInput = FileHandle.nullDevice
        let out = Pipe()
        let err = Pipe()
        process.standardOutput = out
        process.standardError = err
        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }
        do { try process.run() } catch { return nil }

        let group = DispatchGroup()
        var stdout = Data()
        var stderr = Data()
        DispatchQueue.global(qos: .userInitiated).async(group: group) {
            stdout = out.fileHandleForReading.readDataToEndOfFile()
        }
        DispatchQueue.global(qos: .userInitiated).async(group: group) {
            stderr = err.fileHandleForReading.readDataToEndOfFile()
        }
        if exited.wait(timeout: .now() + timeout) == .timedOut {
            process.terminate()
            exited.wait()
        }
        group.wait()
        return ProcessResult(stdout: String(decoding: stdout, as: UTF8.self),
                             stderr: String(decoding: stderr, as: UTF8.self),
                             exitCode: process.terminationStatus)
    }
}
