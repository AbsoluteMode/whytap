import Foundation

/// Anything that can send one request to the Case broker and return its answer.
public protocol CaseBrokerCalling {
    func send(_ request: CaseBrokerRequest) throws -> CaseBrokerResponse
}

public enum CaseBrokerClientError: Error, Equatable {
    /// Could not connect (no socket, refused). Nothing was sent.
    case unavailable
    /// Connected, but the exchange failed or the answer was unusable.
    case protocolFailure
}

/// Blocking client for the broker's Unix socket: one request per connection,
/// newline-delimited JSON.
public final class UnixSocketBrokerClient: CancellableCaseBrokerCalling {
    private let socketURL: URL
    private let timeout: TimeInterval

    /// `timeout` bounds each read/write; approval prompts can take a minute.
    public init(socketURL: URL, timeout: TimeInterval = 120) {
        self.socketURL = socketURL
        self.timeout = timeout
    }

    public func send(_ request: CaseBrokerRequest) throws -> CaseBrokerResponse {
        try send(request, cancellation: nil)
    }

    public func send(_ request: CaseBrokerRequest, cancellation: AppControlCancellation?) throws -> CaseBrokerResponse {
        guard cancellation?.isCancelled != true else { throw CaseBrokerClientError.protocolFailure }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw CaseBrokerClientError.unavailable }
        // Closed, not inherited, when an MCP helper execs a new build.
        _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
        cancellation?.attach(fd)
        defer { cancellation?.detach(); close(fd) }
        var noSigPipe: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))
        var tv = timeval(tv_sec: Int(timeout), tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = Array(socketURL.path.utf8)
        let capacity = MemoryLayout.size(ofValue: addr.sun_path)
        guard pathBytes.count < capacity else { throw CaseBrokerClientError.unavailable }
        withUnsafeMutableBytes(of: &addr.sun_path) { raw in
            for (i, b) in pathBytes.enumerated() { raw[i] = b }
            raw[pathBytes.count] = 0
        }
        let connected = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard connected == 0 else { throw CaseBrokerClientError.unavailable }
        // A cancellation before connect cannot shut down an unconnected socket.
        // Recheck before writing; after connect cancellation interrupts I/O.
        guard cancellation?.isCancelled != true else { throw CaseBrokerClientError.protocolFailure }

        let line = try CaseBrokerCodec.encodeLine(request)
        var sent = 0
        try line.withUnsafeBytes { raw in
            while sent < line.count {
                let n = write(fd, raw.baseAddress! + sent, line.count - sent)
                if n <= 0 { throw CaseBrokerClientError.protocolFailure }
                sent += n
            }
        }

        var response = Data()
        var buf = [UInt8](repeating: 0, count: 4096)
        while !response.contains(0x0A) {
            let n = read(fd, &buf, buf.count)
            if n < 0 { throw CaseBrokerClientError.protocolFailure }
            if n == 0 { break }
            response.append(contentsOf: buf[0..<n])
        }
        guard !response.isEmpty,
              let decoded = try? CaseBrokerCodec.decodeLine(CaseBrokerResponse.self, from: response)
        else { throw CaseBrokerClientError.protocolFailure }
        return decoded
    }
}

/// Wraps a client: on `.unavailable` it asks the app to start (`launch`) once
/// and retries until `timeout` passes.
public final class LaunchingBrokerClient: CancellableCaseBrokerCalling {
    private let inner: CaseBrokerCalling
    private let launch: () -> Void
    private let timeout: TimeInterval
    private let pollInterval: TimeInterval
    private let sleep: (TimeInterval) -> Void
    private let now: () -> Date

    public init(
        inner: CaseBrokerCalling,
        launch: @escaping () -> Void,
        timeout: TimeInterval = 5,
        pollInterval: TimeInterval = 0.1,
        sleep: @escaping (TimeInterval) -> Void = { Thread.sleep(forTimeInterval: $0) },
        now: @escaping () -> Date = Date.init
    ) {
        self.inner = inner
        self.launch = launch
        self.timeout = timeout
        self.pollInterval = pollInterval
        self.sleep = sleep
        self.now = now
    }

    public func send(_ request: CaseBrokerRequest) throws -> CaseBrokerResponse {
        try send(request, cancellation: nil)
    }

    public func send(_ request: CaseBrokerRequest, cancellation: AppControlCancellation?) throws -> CaseBrokerResponse {
        func attempt() throws -> CaseBrokerResponse {
            guard cancellation?.isCancelled != true else { throw CaseBrokerClientError.protocolFailure }
            if let inner = inner as? CancellableCaseBrokerCalling { return try inner.send(request, cancellation: cancellation) }
            return try inner.send(request)
        }
        do { return try attempt() } catch CaseBrokerClientError.unavailable {}
        guard cancellation?.isCancelled != true else { throw CaseBrokerClientError.protocolFailure }
        launch()
        let deadline = now().addingTimeInterval(timeout)
        while now() < deadline {
            sleep(pollInterval)
            do { return try attempt() } catch CaseBrokerClientError.unavailable {}
        }
        throw CaseBrokerClientError.unavailable
    }
}

/// Finds the enclosing app's bundle ID from the helper's own location:
/// `<App>.app/Contents/Helpers/whytap` -> `<App>.app/Contents/Info.plist`.
public enum CaseHostBundle {
    public static func bundleID(forExecutable executable: URL) -> String? {
        let resolved = executable.resolvingSymlinksInPath()
        let helpers = resolved.deletingLastPathComponent()
        let contents = helpers.deletingLastPathComponent()
        guard helpers.lastPathComponent == "Helpers", contents.lastPathComponent == "Contents",
              contents.deletingLastPathComponent().pathExtension == "app",
              let data = try? Data(contentsOf: contents.appendingPathComponent("Info.plist")),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let id = plist["CFBundleIdentifier"] as? String, !id.isEmpty
        else { return nil }
        return id
    }
}
