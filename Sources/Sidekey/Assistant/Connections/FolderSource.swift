import Darwin
import Foundation

/// A folder on this Mac as a source, searched by Whytap itself (no MCP and no
/// index): file names and the text of small files, bounded like the old
/// project index.
///
/// The policy is enforced on the object actually opened: the path is walked
/// from the selected folder one component at a time with `openat` and
/// `O_NOFOLLOW`, so a symbolic link anywhere in the path is refused; only a
/// regular file (checked with `fstat` on the open descriptor) is read, with a
/// bounded read. Hidden names, build folders and credential-like files are
/// refused. Search and read use the same opener.
/// WHY: .project-docs/decisions/2026-11-26-agent-sources.md (Folder)
struct FolderSource: Sendable {
    let root: URL

    static let maxFiles = 5000
    static let maxFileBytes = 64_000
    static let maxReadBytes = 32_000
    static let maxOffset = 64 * 1_048_576
    static let excludedDirectories: Set<String> = ["node_modules", "build", "dist", "DerivedData", "Pods", "vendor",
                                                   ".build", "target", "__pycache__", "venv", ".venv", "Library", "Caches"]
    static let refusal = "This file isn’t available to the Agent."

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

    var rootIsDirectory: Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: root.path, isDirectory: &isDirectory) && isDirectory.boolValue
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

    /// A relative path as checked components, or nil when the policy refuses it.
    static func components(_ relative: String) -> [String]? {
        guard !relative.isEmpty, !relative.hasPrefix("/"), !relative.hasPrefix("~"), relative.utf8.count <= 4096,
              !relative.contains("\0") else { return nil }
        let parts = relative.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        guard let last = parts.last, !isCredentialFile(last) else { return nil }
        for part in parts where part == "." || part == ".." || part.hasPrefix(".") || excludedDirectories.contains(part) {
            return nil
        }
        return parts
    }

    enum Failure: Error { case refused, missing }

    /// Opens a regular file under the folder without following any link.
    func open(_ components: [String]) throws -> Int32 {
        // The selected folder itself must still be a folder, not a link put in its place.
        var directory = Darwin.open(root.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard directory >= 0 else { throw Failure.missing }
        for component in components.dropLast() {
            let next = openat(directory, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            close(directory)
            guard next >= 0 else { throw errno == ENOENT ? Failure.missing : Failure.refused }
            directory = next
        }
        defer { close(directory) }
        let file = openat(directory, components.last!, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard file >= 0 else { throw errno == ENOENT ? Failure.missing : Failure.refused }
        var info = stat()
        guard fstat(file, &info) == 0, info.st_mode & S_IFMT == S_IFREG else { close(file); throw Failure.refused }
        return file
    }

    /// Up to `limit` bytes from `offset` of an open file.
    static func read(_ file: Int32, offset: Int, limit: Int) -> Data {
        var data = Data(count: limit)
        var total = 0
        data.withUnsafeMutableBytes { raw in
            while total < limit {
                let count = pread(file, raw.baseAddress! + total, limit - total, off_t(offset + total))
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { break }
                total += count
            }
        }
        return data.prefix(total)
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
            return clip(read(path, offset: offset), maxCharacters)
        default:
            throw MCPError.notAllowed
        }
    }

    /// Text files Whytap would search, for the proof line.
    func countFiles() -> Int {
        var count = 0
        walk { _ in count += 1; return true }
        return count
    }

    private func clip(_ text: String, _ limit: Int) -> MCPToolResult {
        MCPToolResult(text: String(text.prefix(limit)), isError: false, shortened: text.count > limit)
    }

    /// Relative paths of files the policy allows, without following links.
    private func walk(_ visit: ([String]) throws -> Bool) rethrows {
        let keys: [URLResourceKey] = [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey]
        guard let files = FileManager.default.enumerator(at: root, includingPropertiesForKeys: keys,
                                                         options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { return }
        let prefix = root.standardizedFileURL.path.hasSuffix("/") ? root.standardizedFileURL.path : root.standardizedFileURL.path + "/"
        var visited = 0
        for case let file as URL in files {
            if Task.isCancelled { return }
            guard let values = try? file.resourceValues(forKeys: Set(keys)) else { continue }
            if values.isSymbolicLink == true { if values.isDirectory == true { files.skipDescendants() }; continue }
            if values.isDirectory == true {
                if Self.excludedDirectories.contains(file.lastPathComponent) { files.skipDescendants() }
                continue
            }
            let path = file.standardizedFileURL.path
            guard values.isRegularFile == true, path.hasPrefix(prefix),
                  let components = Self.components(String(path.dropFirst(prefix.count))) else { continue }
            visited += 1
            if visited > Self.maxFiles { return }
            guard try visit(components) else { return }
        }
    }

    private func search(_ query: String) throws -> String {
        var results: [String] = []
        try walk { components in
            try Task.checkCancellation()
            let relative = components.joined(separator: "/")
            if components.last!.localizedCaseInsensitiveContains(query) { results.append(relative) }
            // The same opener as read_file: no links, regular files, bounded.
            guard let file = try? open(components) else { return true }
            defer { close(file) }
            let data = Self.read(file, offset: 0, limit: Self.maxFileBytes + 1)
            guard data.count <= Self.maxFileBytes, !data.contains(0), let text = String(data: data, encoding: .utf8) else { return true }
            for (index, line) in text.components(separatedBy: .newlines).enumerated()
            where line.localizedCaseInsensitiveContains(query) {
                results.append("\(relative):\(index + 1): \(line.trimmingCharacters(in: .whitespaces).prefix(240))")
                if results.count >= 60 { break }
            }
            return results.count < 60
        }
        return results.isEmpty ? "No matches." : results.joined(separator: "\n") + (results.count >= 60 ? "\n[More matches; narrow the query]" : "")
    }

    private func read(_ path: String, offset: Int) -> String {
        guard let components = Self.components(path) else { return Self.refusal }
        let file: Int32
        do { file = try open(components) }
        catch Failure.missing { return "No such file in this folder." }
        catch { return Self.refusal }
        defer { close(file) }
        let data = Self.read(file, offset: offset, limit: Self.maxReadBytes + 1)
        guard !data.contains(0) else { return "This is a binary file." }
        return String(decoding: data.prefix(Self.maxReadBytes), as: UTF8.self)
            + (data.count > Self.maxReadBytes ? "\n[Shortened; continue at offset \(offset + Self.maxReadBytes)]" : "")
    }
}
