import Foundation

enum AgentDaemonWorkingDirectory {
    /// The single real memory file. Codex reads `AGENTS.md` natively; Claude
    /// Code reads `CLAUDE.md` natively, so a `CLAUDE.md` SYMLINK points at this
    /// same file (see `ensureMemory` Step 4). One real file, two names — no
    /// content duplication, nothing to keep in sync.
    static let memoryFileName = "AGENTS.md"

    /// `WHYTAP_MEMORY.md` is the old real file, migrated into `AGENTS.md` on
    /// first `ensure()`. `CLAUDE.md` is the Claude-facing symlink alias to
    /// `AGENTS.md` (a real user-authored `CLAUDE.md` is folded in first, then
    /// replaced by the alias).
    private static let legacyMemoryFileName = "WHYTAP_MEMORY.md"
    private static let claudeAliasFileName = "CLAUDE.md"

    /// Returns (and creates if absent) `~/Library/Application Support/whytap/agent`.
    ///
    /// This is the stable working directory passed to every `claude -p` spawn.
    /// Having a dedicated directory means the user's global CLAUDE.md and MCP
    /// server config load from the conventional location, and any files the
    /// agent writes land in a known, inspectable place.
    @discardableResult
    static func ensure() throws -> URL {
        let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first!
        return try ensure(appSupportDirectory: appSupport)
    }

    @discardableResult
    static func ensure(
        appSupportDirectory: URL,
        fileManager: FileManager = .default
    ) throws -> URL {
        let dir = appSupportDirectory
            .appendingPathComponent("whytap", isDirectory: true)
            .appendingPathComponent("agent", isDirectory: true)

        if !fileManager.fileExists(atPath: dir.path) {
            try fileManager.createDirectory(
                at: dir,
                withIntermediateDirectories: true,
                attributes: nil
            )
        }
        try ensureMemory(in: dir, fileManager: fileManager)
        return dir
    }

    /// Brings the working directory to its target shape — exactly one real
    /// `AGENTS.md`, no aliases — from any prior on-disk state. Idempotent:
    /// safe to call repeatedly, never destroys user bytes.
    ///
    /// The migration is a sequence of moves/merges, not a single transaction.
    /// Safety rests on convergent re-entry: `ensure()` runs on every launch, and
    /// re-running from any partial state (a crash between steps) reaches the same
    /// final shape. The one step that could otherwise lose bytes — promoting the
    /// legacy file — uses `moveItem`, an atomic same-volume rename, so the real
    /// content is never in flight.
    private static func ensureMemory(in dir: URL, fileManager: FileManager) throws {
        let memory = dir.appendingPathComponent(memoryFileName)

        // Step 1: if AGENTS.md is currently a symlink (legacy alias to
        // WHYTAP_MEMORY.md), drop the link so we can promote the real file or
        // create a fresh one. `fileExists` follows symlinks, so this check has
        // to come before it.
        if isSymbolicLink(at: memory, fileManager: fileManager) {
            try fileManager.removeItem(at: memory)
        }

        // Step 2: promote a legacy real WHYTAP_MEMORY.md into AGENTS.md,
        // preserving its bytes. Only when no real AGENTS.md already exists
        // (a prior migration would have produced one).
        let legacyMemory = dir.appendingPathComponent(legacyMemoryFileName)
        if fileManager.fileExists(atPath: legacyMemory.path) {
            if fileManager.fileExists(atPath: memory.path) {
                // Both real files somehow coexist: fold the legacy content in
                // rather than clobber the existing AGENTS.md, then remove it.
                try mergeFile(legacyMemory, named: legacyMemoryFileName, into: memory, fileManager: fileManager)
                try fileManager.removeItem(at: legacyMemory)
            } else {
                try fileManager.moveItem(at: legacyMemory, to: memory)
            }
        }

        // Step 3: ensure a real AGENTS.md exists (empty on a fresh install).
        if !fileManager.fileExists(atPath: memory.path) {
            try Data().write(to: memory)
        }

        // Step 4: CLAUDE.md is a SYMLINK alias to AGENTS.md. Claude Code reads
        // CLAUDE.md natively (not AGENTS.md), so the alias lets it pick up the
        // memory directly — no dependence on a prompt instruction, and it works
        // on every turn (the preamble pointer only ships on the first). One real
        // file (AGENTS.md) under two names: no duplication, nothing to sync.
        // Recreated each ensure() so any stale/real CLAUDE.md converges to it.
        let claude = dir.appendingPathComponent(claudeAliasFileName)
        if isSymbolicLink(at: claude, fileManager: fileManager) {
            // Already an alias — drop it so we can recreate pointing at AGENTS.md.
            try fileManager.removeItem(at: claude)
        } else if fileManager.fileExists(atPath: claude.path) {
            // A real user-authored CLAUDE.md: fold its bytes into AGENTS.md
            // first so nothing is lost, then replace it with the alias.
            try mergeFile(claude, named: claudeAliasFileName, into: memory, fileManager: fileManager)
            try fileManager.removeItem(at: claude)
        }
        // Relative destination so the alias survives if the dir is moved.
        try fileManager.createSymbolicLink(
            atPath: claude.path,
            withDestinationPath: memoryFileName
        )
    }

    /// Appends the content of `source` to the memory file under a labelled
    /// heading so its provenance is clear and user bytes are never dropped.
    /// No-op when the source is empty or whitespace-only. Reads and writes RAW
    /// bytes: content is only decoded for the emptiness check, so a source that
    /// is not valid UTF-8 is preserved rather than silently discarded. The
    /// caller removes the source only after this returns, so a throw here leaves
    /// the source intact.
    private static func mergeFile(
        _ source: URL,
        named name: String,
        into memory: URL,
        fileManager: FileManager
    ) throws {
        let data = try Data(contentsOf: source)
        if data.isEmpty { return }
        if let text = String(data: data, encoding: .utf8),
           text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return
        }
        var block = Data("\n\n## Imported from \(name)\n\n".utf8)
        block.append(data)
        block.append(Data("\n".utf8))
        if let handle = try? FileHandle(forWritingTo: memory) {
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: block)
        } else {
            try block.write(to: memory, options: .atomic)
        }
    }

    /// Whether the path is a symbolic link. Uses `destinationOfSymbolicLink`,
    /// which only succeeds for links — `FileManager.fileExists` follows links
    /// and so cannot distinguish a link from its target.
    private static func isSymbolicLink(at url: URL, fileManager: FileManager) -> Bool {
        (try? fileManager.destinationOfSymbolicLink(atPath: url.path)) != nil
    }
}
