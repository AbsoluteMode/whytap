import Darwin
import Foundation

/// The folder the user selected: its real path (no links) and the device and
/// inode of that directory when it was added.
struct FolderIdentity: Codable, Equatable, Sendable {
    var path: String
    var device: Int64
    var inode: UInt64
}

/// A folder on this Mac as a source, searched by Whytap itself (no MCP and no
/// index): file names and the text of small files, bounded like the old
/// project index.
///
/// Every listing, search and read goes through one opener on open
/// descriptors: the selected folder is reached from `/` one component at a
/// time with `O_NOFOLLOW` and must still be the same directory (device and
/// inode) as when it was added; below it, each entry is opened with `openat`
/// and `O_NOFOLLOW` and checked with `fstat` on the opened descriptor. Only
/// regular files are read, with bounded `pread`s that observe cancellation.
/// A name is reported only after its file passed that open. Hidden names,
/// build folders and credential-like files are refused.
/// WHY: .project-docs/decisions/2026-11-26-agent-sources.md (Folder)
struct FolderSource: Sendable {
    let identity: FolderIdentity

    static let maxFiles = 5000
    static let maxDepth = 24
    static let maxFileBytes = 64_000
    static let maxReadBytes = 32_000
    static let maxOffset = 64 * 1_048_576
    static let excludedDirectories: Set<String> = ["node_modules", "build", "dist", "DerivedData", "Pods", "vendor",
                                                   ".build", "target", "__pycache__", "venv", ".venv", "Library", "Caches"]
    static let refusal = "This file isn’t available to the Agent."
    static let missingReason = "The folder is missing or was replaced. Remove this source and add the folder again."

    static let tools: [MCPToolInfo] = [
        MCPToolInfo(name: "search", description: "Find files in this folder whose name or text contains the query (case-insensitive). Returns path:line: text.",
                    inputSchema: .object(["type": .string("object"),
                                          "properties": .object(["query": .object(["type": .string("string")])]),
                                          "required": .array([.string("query")])]),
                    readOnlyHint: true),
        MCPToolInfo(name: "read_file", description: "Read a text file in this folder by its path relative to the folder (up to 32 KB; offset continues).",
                    inputSchema: .object(["type": .string("object"),
                                          "properties": .object(["path": .object(["type": .string("string")]),
                                                                 "offset": .object(["type": .string("integer")])]),
                                          "required": .array([.string("path")])]),
                    readOnlyHint: true),
    ]

    init(identity: FolderIdentity) { self.identity = identity }

    /// The source's folder, or nil when the record has no identity (it is
    /// then refused rather than opened by path).
    init?(record: SourceRecord) {
        guard case .folder = record.transport, let identity = record.folder else { return nil }
        self.identity = identity
    }

    // MARK: - The selected folder

    /// The real path and identity of a folder the user picked.
    static func identify(_ path: String) -> FolderIdentity? {
        guard let real = realpath(path, nil) else { return nil }
        defer { free(real) }
        let canonical = String(cString: real)
        guard let fd = openAbsolute(canonical) else { return nil }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFDIR else { return nil }
        return FolderIdentity(path: canonical, device: Int64(info.st_dev), inode: UInt64(info.st_ino))
    }

    /// Walks an absolute path from `/` without following any link.
    private static func openAbsolute(_ path: String) -> Int32? {
        guard path.hasPrefix("/") else { return nil }
        var directory = Darwin.open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard directory >= 0 else { return nil }
        for component in path.split(separator: "/", omittingEmptySubsequences: true) {
            let next = openat(directory, String(component), O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            close(directory)
            guard next >= 0 else { return nil }
            directory = next
        }
        return directory
    }

    /// The selected folder, if it is still the same directory.
    func openRoot() -> Int32? {
        guard let fd = Self.openAbsolute(identity.path) else { return nil }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFDIR,
              Int64(info.st_dev) == identity.device, UInt64(info.st_ino) == identity.inode else { close(fd); return nil }
        return fd
    }

    // MARK: - The one opener

    enum Kind { case directory, file }
    enum Failure: Error { case refused, missing }

    /// Opens one entry of an open directory without following a link and
    /// returns it only if it is a directory or a regular file.
    static func openChild(_ directory: Int32, _ name: String) -> (fd: Int32, kind: Kind)? {
        let fd = openat(directory, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_NOCTTY | O_CLOEXEC)
        guard fd >= 0 else { return nil }
        var info = stat()
        guard fstat(fd, &info) == 0 else { close(fd); return nil }
        switch info.st_mode & S_IFMT {
        case S_IFDIR: return (fd, .directory)
        case S_IFREG: return (fd, .file)
        default: close(fd); return nil
        }
    }

    static func isCredentialFile(_ name: String) -> Bool {
        let lower = name.lowercased()
        if lower.hasPrefix(".env") || lower.hasPrefix("id_rsa") || lower.hasPrefix("id_ed25519") || lower.hasPrefix("id_ecdsa") { return true }
        for suffix in [".pem", ".key", ".p12", ".pfx", ".keychain", ".keychain-db", ".kdbx", ".ppk", ".asc", ".gpg"]
            where lower.hasSuffix(suffix) { return true }
        for word in ["credential", "secret", "password", "token", ".netrc", ".npmrc", ".pypirc", "service-account"]
            where lower.contains(word) { return true }
        return false
    }

    static func isAllowedDirectory(_ name: String) -> Bool {
        !name.hasPrefix(".") && !excludedDirectories.contains(name)
    }

    static func isAllowedFile(_ name: String) -> Bool { !name.hasPrefix(".") && !isCredentialFile(name) }

    /// A relative path as checked components, or nil when the policy refuses it.
    static func components(_ relative: String) -> [String]? {
        guard !relative.isEmpty, !relative.hasPrefix("/"), !relative.hasPrefix("~"), relative.utf8.count <= 4096,
              !relative.contains("\0") else { return nil }
        let parts = relative.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        guard let last = parts.last, parts.count <= maxDepth, isAllowedFile(last) else { return nil }
        for part in parts.dropLast() where part == ".." || !isAllowedDirectory(part) { return nil }
        return parts
    }

    /// Opens a regular file under the selected folder.
    func open(_ components: [String]) throws -> Int32 {
        guard var directory = openRoot() else { throw Failure.missing }
        for component in components.dropLast() {
            let next = Self.openChild(directory, component)
            close(directory)
            guard let next, next.kind == .directory else { throw Failure.refused }
            directory = next.fd
        }
        defer { close(directory) }
        guard let file = Self.openChild(directory, components.last!) else {
            throw errno == ENOENT ? Failure.missing : Failure.refused
        }
        guard file.kind == .file else { close(file.fd); throw Failure.refused }
        return file.fd
    }

    /// Up to `limit` bytes from `offset` of an open file, in 16 KB steps that
    /// stop when the task is cancelled.
    static func read(_ file: Int32, offset: Int, limit: Int) throws -> Data {
        var data = Data(count: limit)
        var total = 0
        try data.withUnsafeMutableBytes { raw in
            while total < limit {
                try Task.checkCancellation()
                let count = pread(file, raw.baseAddress! + total, min(16_384, limit - total), off_t(offset + total))
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { break }
                total += count
            }
        }
        return data.prefix(total)
    }

    /// Every allowed regular file below the folder, opened by the one opener,
    /// in name order. `visit` gets its components and open descriptor.
    func walk(_ visit: ([String], Int32) throws -> Bool) throws {
        guard let root = openRoot() else { throw Failure.missing }
        var visited = 0
        func descend(_ directory: Int32, _ prefix: [String]) throws -> Bool {
            guard prefix.count < Self.maxDepth else { return true }
            let copy = dup(directory)
            guard copy >= 0, let stream = fdopendir(copy) else { if copy >= 0 { close(copy) }; return true }
            var names: [String] = []
            while let entry = readdir(stream) {
                let name = withUnsafePointer(to: entry.pointee.d_name) {
                    $0.withMemoryRebound(to: CChar.self, capacity: Int(entry.pointee.d_namlen) + 1) { String(cString: $0) }
                }
                if name != ".", name != ".." { names.append(name) }
            }
            closedir(stream)
            for name in names.sorted() {
                try Task.checkCancellation()
                guard !name.hasPrefix(".") else { continue }
                guard let child = Self.openChild(directory, name) else { continue }
                defer { close(child.fd) }
                switch child.kind {
                case .directory:
                    guard Self.isAllowedDirectory(name) else { continue }
                    guard try descend(child.fd, prefix + [name]) else { return false }
                case .file:
                    guard Self.isAllowedFile(name) else { continue }
                    visited += 1
                    if visited > Self.maxFiles { return false }
                    guard try visit(prefix + [name], child.fd) else { return false }
                }
            }
            return true
        }
        defer { close(root) }
        _ = try descend(root, [])
    }

    func call(_ tool: String, arguments: MCPValue, maxCharacters: Int) throws -> MCPToolResult {
        switch tool {
        case "search":
            guard let query = arguments["query"]?.string?.trimmingCharacters(in: .whitespaces), !query.isEmpty,
                  query.count <= 500 else {
                return MCPToolResult(text: "Missing query.", isError: true, shortened: false)
            }
            return clip(try search(query), maxCharacters)
        case "read_file":
            guard let path = arguments["path"]?.string, !path.isEmpty else {
                return MCPToolResult(text: "Missing path.", isError: true, shortened: false)
            }
            var offset = 0
            if let value = arguments["offset"], value != .null {
                guard let exact = value.int, exact >= 0, exact <= Self.maxOffset else {
                    return MCPToolResult(text: "offset must be a whole number from 0.", isError: true, shortened: false)
                }
                offset = exact
            }
            return clip(try read(path, offset: offset), maxCharacters)
        default:
            throw MCPError.notAllowed
        }
    }

    /// Files Whytap would search, for the proof line: the same walk.
    func countFiles() throws -> Int {
        var count = 0
        try walk { _, _ in count += 1; return true }
        return count
    }

    private func clip(_ text: String, _ limit: Int) -> MCPToolResult {
        MCPToolResult(text: String(text.prefix(limit)), isError: false, shortened: text.count > limit)
    }

    private func search(_ query: String) throws -> String {
        var results: [String] = []
        do {
            try walk { components, file in
                let relative = components.joined(separator: "/")
                // Reported only now: the entry opened as a regular file.
                if components.last!.localizedCaseInsensitiveContains(query) { results.append(relative) }
                let data = try Self.read(file, offset: 0, limit: Self.maxFileBytes + 1)
                guard data.count <= Self.maxFileBytes, !data.contains(0), let text = String(data: data, encoding: .utf8) else { return true }
                for (index, line) in text.components(separatedBy: .newlines).enumerated()
                where line.localizedCaseInsensitiveContains(query) {
                    results.append("\(relative):\(index + 1): \(line.trimmingCharacters(in: .whitespaces).prefix(240))")
                    if results.count >= 60 { break }
                }
                return results.count < 60
            }
        } catch Failure.missing { return Self.missingReason }
        return results.isEmpty ? "No matches." : results.joined(separator: "\n") + (results.count >= 60 ? "\n[More matches; narrow the query]" : "")
    }

    private func read(_ path: String, offset: Int) throws -> String {
        guard let components = Self.components(path) else { return Self.refusal }
        let file: Int32
        do { file = try open(components) }
        catch Failure.missing { return "No such file in this folder." }
        catch { return Self.refusal }
        defer { close(file) }
        let data = try Self.read(file, offset: offset, limit: Self.maxReadBytes + 1)
        guard !data.contains(0) else { return "This is a binary file." }
        return String(decoding: data.prefix(Self.maxReadBytes), as: UTF8.self)
            + (data.count > Self.maxReadBytes ? "\n[Shortened; continue at offset \(offset + Self.maxReadBytes)]" : "")
    }
}
