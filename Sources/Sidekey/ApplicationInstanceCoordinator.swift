import AppKit
import Darwin

/// All flavors use one advisory lock so only one copy starts hotkeys, provider
/// discovery and permission flows. The kernel releases it after any process exit.
/// Never unlink this file: another opener must keep locking the same inode.
// WHY: .project-docs/decisions/2026-10-19-one-running-copy.md
final class ApplicationInstanceLease {
    enum Attempt {
        case acquired(ApplicationInstanceLease)
        case busy(ownerPID: pid_t?)
    }

    enum LeaseError: Error, Equatable {
        case systemCall(Int32)
        case invalidFile
    }

    private var descriptor: Int32

    private init(descriptor: Int32) {
        self.descriptor = descriptor
    }

    deinit { release() }

    static func acquire(directory: URL, ownerPID: pid_t) throws -> Attempt {
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let file = directory.appendingPathComponent("runtime.lock")
        let descriptor = Darwin.open(file.path, O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw LeaseError.systemCall(errno) }
        var keepDescriptor = false
        defer { if !keepDescriptor { Darwin.close(descriptor) } }

        var fileInfo = stat()
        guard fstat(descriptor, &fileInfo) == 0 else { throw LeaseError.systemCall(errno) }
        guard fileInfo.st_mode & S_IFMT == S_IFREG, fileInfo.st_uid == getuid() else {
            throw LeaseError.invalidFile
        }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            let code = errno
            if code == EWOULDBLOCK || code == EAGAIN {
                return .busy(ownerPID: readOwnerPID(descriptor: descriptor))
            }
            throw LeaseError.systemCall(code)
        }

        // Change neither permissions nor owner metadata until ownership is ours.
        guard fchmod(descriptor, 0o600) == 0,
              ftruncate(descriptor, 0) == 0 else { throw LeaseError.systemCall(errno) }
        let metadata = Array("\(ownerPID)\n".utf8)
        let written = metadata.withUnsafeBytes { buffer in
            Darwin.write(descriptor, buffer.baseAddress, buffer.count)
        }
        guard written == metadata.count else { throw LeaseError.systemCall(errno) }

        keepDescriptor = true
        return .acquired(ApplicationInstanceLease(descriptor: descriptor))
    }

    private static func readOwnerPID(descriptor: Int32) -> pid_t? {
        var bytes = [UInt8](repeating: 0, count: 32)
        let count = bytes.withUnsafeMutableBytes { buffer in
            pread(descriptor, buffer.baseAddress, buffer.count, 0)
        }
        guard count > 0, count < bytes.count,
              let text = String(bytes: bytes.prefix(count), encoding: .utf8),
              let pid = pid_t(text.trimmingCharacters(in: .whitespacesAndNewlines)), pid > 0 else {
            return nil
        }
        return pid
    }

    var closesOnExec: Bool {
        descriptor >= 0 && fcntl(descriptor, F_GETFD) & FD_CLOEXEC != 0
    }

    func release() {
        guard descriptor >= 0 else { return }
        Darwin.close(descriptor)
        descriptor = -1
    }
}

struct RunningExodiaInstance: Equatable {
    let processIdentifier: pid_t
    let identity: AppBuildIdentity
    let hasFinishedLaunching: Bool

    init(processIdentifier: pid_t, identity: AppBuildIdentity, hasFinishedLaunching: Bool = true) {
        self.processIdentifier = processIdentifier
        self.identity = identity
        self.hasFinishedLaunching = hasFinishedLaunching
    }
}

struct ApplicationInstanceConflict: Equatable {
    enum Reason: Equatable { case alreadyRunning, coordinationUnavailable }
    let reason: Reason
    let existing: RunningExodiaInstance?
    let requested: AppBuildIdentity
}

@MainActor
final class ApplicationInstanceCoordinator {
    /// Shared by every flavor and by the headless restore point commands.
    nonisolated static let leaseDirectory = FileManager.default.urls(
        for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("whytap/instance", isDirectory: true)

    static let shared = ApplicationInstanceCoordinator(
        directory: leaseDirectory,
        currentPID: getpid(),
        identity: .current,
        runningInstances: liveRunningInstances,
        presentConflict: presentLiveConflict
    )

    nonisolated static let bundleIdentifiers: Set<String> = [
        "com.rootwise.sidekey", "com.rootwise.sidekey.beta"
    ]

    private let directory: URL
    private let currentPID: pid_t
    private let identity: AppBuildIdentity
    private let runningInstances: () -> [RunningExodiaInstance]
    private let presentConflict: (ApplicationInstanceConflict) -> Void
    private var lease: ApplicationInstanceLease?

    init(
        directory: URL,
        currentPID: pid_t,
        identity: AppBuildIdentity,
        runningInstances: @escaping () -> [RunningExodiaInstance],
        presentConflict: @escaping (ApplicationInstanceConflict) -> Void
    ) {
        self.directory = directory
        self.currentPID = currentPID
        self.identity = identity
        self.runningInstances = runningInstances
        self.presentConflict = presentConflict
    }

    /// Called before constructing AppDelegate. No credentials, providers,
    /// permissions or hotkey monitors are accessed on a rejected launch.
    func canLaunch() -> Bool {
        if lease != nil { return true }
        do {
            switch try ApplicationInstanceLease.acquire(directory: directory, ownerPID: currentPID) {
            case .acquired(let acquired):
                // New contenders are protected by the lock. Only legacy copies
                // without that protocol need a separate workspace check; treating
                // a new contender as legacy could make two racing launches reject
                // each other. Packaging sets the marker only for aware binaries.
                // A running legacy process may have had its bundle replaced on
                // disk. Its new Info.plist marker must not hide that process.
                // A new contender has not run AppDelegate.main yet, hence has
                // not finished launching and can safely defer to our lock.
                let legacy = peers().first {
                    !$0.identity.usesInstanceLease || $0.hasFinishedLaunching
                }
                if let legacy {
                    acquired.release()
                    presentConflict(.init(reason: .alreadyRunning, existing: legacy, requested: identity))
                    return false
                }
                lease = acquired
                return true
            case .busy(let ownerPID):
                let applications = peers()
                let owner = applications.first { $0.processIdentifier == ownerPID }
                    ?? applications.first
                presentConflict(.init(reason: .alreadyRunning, existing: owner, requested: identity))
                return false
            }
        } catch {
            presentConflict(.init(reason: .coordinationUnavailable, existing: nil, requested: identity))
            return false
        }
    }

    private func peers() -> [RunningExodiaInstance] {
        runningInstances().filter {
            $0.processIdentifier != currentPID
                && Self.bundleIdentifiers.contains($0.identity.bundleIdentifier)
        }
    }

    private static func liveRunningInstances() -> [RunningExodiaInstance] {
        NSWorkspace.shared.runningApplications.compactMap { application in
            guard !application.isTerminated,
                  let identifier = application.bundleIdentifier,
                  bundleIdentifiers.contains(identifier),
                  let url = application.bundleURL else { return nil }
            let info = Bundle(url: url)?.infoDictionary ?? ["CFBundleIdentifier": identifier]
            return RunningExodiaInstance(
                processIdentifier: application.processIdentifier,
                identity: AppBuildIdentity(info: info, bundleURL: url),
                hasFinishedLaunching: application.isFinishedLaunching
            )
        }
    }

    private static func presentLiveConflict(_ conflict: ApplicationInstanceConflict) {
        let application = NSApplication.shared
        application.setActivationPolicy(.regular)
        application.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.alertStyle = .informational
        if let existing = conflict.existing {
            alert.messageText = "Whytap is already running"
            alert.informativeText = "Running: \(existing.identity.summary)\n\(existing.identity.bundlePath)\n\nRequested: \(conflict.requested.summary)\n\(conflict.requested.bundlePath)\n\nThis copy will quit so your shortcuts and current work stay with the running app. To switch copies, quit the running app first, then open the copy you want."
            alert.addButton(withTitle: "Activate Running App")
            alert.addButton(withTitle: "Quit This Copy")
            if alert.runModal() == .alertFirstButtonReturn,
               let running = NSRunningApplication(processIdentifier: existing.processIdentifier),
               !running.isTerminated,
               let identifier = running.bundleIdentifier,
               bundleIdentifiers.contains(identifier) {
                _ = running.activate(options: [])
            }
        } else {
            alert.messageText = conflict.reason == .alreadyRunning
                ? "Whytap is already starting" : "Whytap could not start safely"
            alert.informativeText = conflict.reason == .alreadyRunning
                ? "Another Whytap copy owns the shortcuts. This copy will quit without interrupting it."
                : "Whytap could not reserve its shortcuts. Quit any other Whytap copies, then open Whytap again."
            alert.addButton(withTitle: "Quit This Copy")
            alert.runModal()
        }
    }
}
