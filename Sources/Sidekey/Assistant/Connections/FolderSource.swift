import Foundation

/// A folder on this Mac as a source, searched by Whytap itself (no MCP and no
/// index): file names and the text of small files, bounded like the old
/// project index. Hidden files, symbolic links, build folders and common
/// credential files are never read. Paths cannot leave the folder.
/// WHY: .project-docs/decisions/2026-11-26-agent-sources.md
struct FolderSource: Sendable {
    let root: URL

    static let maxFiles = 5000
    static let maxFileBytes = 64_000
    static let maxReadBytes = 32_000
    static let excludedDirectories: Set<String> = ["node_modules", "build", "dist", "DerivedData", "Pods", "vendor",
                                                   ".build", "target", "__pycache__", "venv", ".venv", "Library", "Caches"]

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

    static func isCredentialFile(_ name: String) -> Bool {
        let lower = name.lowercased()
        if lower.hasPrefix(".env") || lower.hasPrefix("id_rsa") || lower.hasPrefix("id_ed25519") || lower.hasPrefix("id_ecdsa") { return true }
        for suffix in [".pem", ".key", ".p12", ".pfx", ".keychain", ".keychain-db", ".kdbx", ".ppk", ".asc", ".gpg"]
            where lower.hasSuffix(suffix) { return true }
        for word in ["credential", "secret", "password", "token", ".netrc", ".npmrc", ".pypirc", "service-account"]
            where lower.contains(word) { return true }
        return false
    }

    func call(_ tool: String, arguments: MCPValue, maxCharacters: Int) throws -> MCPToolResult {
        switch tool {
        case "search":
            guard let query = arguments["query"]?.string?.trimmingCharacters(in: .whitespaces), !query.isEmpty else {
                return MCPToolResult(text: "Missing query.", isError: true, shortened: false)
            }
            return clip(try search(query), maxCharacters)
        case "read_file":
            guard let path = arguments["path"]?.string, !path.isEmpty else {
                return MCPToolResult(text: "Missing path.", isError: true, shortened: false)
            }
            return clip(try read(path, offset: max(0, arguments["offset"]?.int ?? 0)), maxCharacters)
        default:
            throw MCPError.notAllowed
        }
    }

    /// Text files Whytap would search, for the proof line.
    func countFiles() -> Int {
        var count = 0
        walk { _, _ in count += 1; return true }
        return count
    }

    private func clip(_ text: String, _ limit: Int) -> MCPToolResult {
        MCPToolResult(text: String(text.prefix(limit)), isError: false, shortened: text.count > limit)
    }

    private func walk(_ visit: (URL, Int) throws -> Bool) rethrows {
        let keys: [URLResourceKey] = [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]
        guard let files = FileManager.default.enumerator(at: root, includingPropertiesForKeys: keys,
                                                         options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { return }
        var visited = 0
        for case let file as URL in files {
            guard let values = try? file.resourceValues(forKeys: Set(keys)) else { continue }
            if values.isSymbolicLink == true { if values.isDirectory == true { files.skipDescendants() }; continue }
            if values.isDirectory == true {
                if Self.excludedDirectories.contains(file.lastPathComponent) { files.skipDescendants() }
                continue
            }
            guard values.isRegularFile == true, !Self.isCredentialFile(file.lastPathComponent) else { continue }
            visited += 1
            if visited > Self.maxFiles { return }
            guard try visit(file, values.fileSize ?? 0) else { return }
        }
    }

    private func search(_ query: String) throws -> String {
        var results: [String] = []
        let prefix = root.standardizedFileURL.path + "/"
        try walk { file, size in
            try Task.checkCancellation()
            let relative = file.standardizedFileURL.path.replacingOccurrences(of: prefix, with: "")
            if file.lastPathComponent.localizedCaseInsensitiveContains(query) { results.append(relative) }
            if size <= Self.maxFileBytes, let data = try? Data(contentsOf: file), !data.contains(0),
               let text = String(data: data, encoding: .utf8) {
                for (index, line) in text.components(separatedBy: .newlines).enumerated()
                where line.localizedCaseInsensitiveContains(query) {
                    results.append("\(relative):\(index + 1): \(line.trimmingCharacters(in: .whitespaces).prefix(240))")
                    if results.count >= 60 { break }
                }
            }
            return results.count < 60
        }
        return results.isEmpty ? "No matches." : results.joined(separator: "\n") + (results.count >= 60 ? "\n[More matches; narrow the query]" : "")
    }

    private func read(_ path: String, offset: Int) throws -> String {
        let candidate = root.appendingPathComponent(path).standardizedFileURL.resolvingSymlinksInPath()
        let base = root.standardizedFileURL.resolvingSymlinksInPath().path + "/"
        guard candidate.path.hasPrefix(base) else { return "This path is outside the folder." }
        let components = candidate.path.dropFirst(base.count).split(separator: "/")
        guard !components.contains(where: { $0.hasPrefix(".") || Self.excludedDirectories.contains(String($0)) }),
              !Self.isCredentialFile(candidate.lastPathComponent) else { return "This file isn’t available to the Agent." }
        let handle = try FileHandle(forReadingFrom: candidate)
        defer { try? handle.close() }
        try handle.seek(toOffset: UInt64(offset))
        let data = try handle.read(upToCount: Self.maxReadBytes + 1) ?? Data()
        guard !data.contains(0) else { return "This is a binary file." }
        return String(decoding: data.prefix(Self.maxReadBytes), as: UTF8.self)
            + (data.count > Self.maxReadBytes ? "\n[Shortened; continue at offset \(offset + Self.maxReadBytes)]" : "")
    }
}
