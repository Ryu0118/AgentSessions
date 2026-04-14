import Foundation

/// Metadata inferred from a partial Claude Code session scan.
private struct SessionMetadata {
    var createdAt: Date?
    var model: String?
    var resolvedProjectPath: String?
    var hasSidechain: Bool

    var isObserver: Bool {
        hasSidechain || (resolvedProjectPath?.contains("observer-sessions") == true)
    }
}

/// Reads Claude Code JSONL sessions from the local session store.
public struct ClaudeCodeSessionReader: SessionReader, Sendable {
    private struct SessionFile: Sendable {
        let file: URL
        let projectPath: String?
    }

    public let source: AgentSource = .claudeCode
    private let fileSystem: any FileSystemProtocol
    private let baseDir: URL
    private let fileReader: JSONLFileReader

    public init(
        fileSystem: any FileSystemProtocol = DefaultFileSystem(),
        baseDir: URL? = nil
    ) {
        self.fileSystem = fileSystem
        self.baseDir = baseDir ?? fileSystem.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/projects")
        fileReader = JSONLFileReader(fileSystem: fileSystem)
    }

    public func listSessions() async throws -> [SessionSummary] {
        guard fileSystem.fileExists(atPath: baseDir.path) else {
            return []
        }
        let projectDirs = try fileSystem.contentsOfDirectory(
            at: baseDir, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
        )

        let sessionFiles = try sessionFiles(in: projectDirs)
        return await SessionSummaryCollector.collect(sessionFiles) { sessionFile in
            try summary(for: sessionFile.file, projectPath: sessionFile.projectPath)
        }
    }

    public func loadSession(id: String, storagePath _: String?, limit: Int?) async throws -> UnifiedConversation? {
        guard fileSystem.fileExists(atPath: baseDir.path) else { return nil }
        let projectDirs = try fileSystem.contentsOfDirectory(
            at: baseDir, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
        )

        let sessionFiles = try sessionFiles(in: projectDirs)

        // 1) Filename stem (UUID or legacy slug-as-filename).
        for sessionFile in sessionFiles where sessionFile.file.deletingPathExtension().lastPathComponent == id {
            return try conversation(
                from: sessionFile.file,
                sessionId: id,
                projectPath: sessionFile.projectPath,
                limit: limit
            )
        }

        // 2) JSON may carry the resume slug in `sessionId`, `customTitle`, or `agentName` while the filename is a UUID.
        for sessionFile in sessionFiles {
            if try file(sessionFile.file, hasSessionIdentifier: id) {
                return try conversation(
                    from: sessionFile.file,
                    sessionId: id,
                    projectPath: sessionFile.projectPath,
                    limit: limit
                )
            }
        }
        return nil
    }

    public func jsonlFiles(in directory: URL) throws -> [URL] {
        guard fileSystem.fileExists(atPath: directory.path) else { return [] }
        return try fileSystem.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
        ).filter { $0.pathExtension == "jsonl" }
    }

    private func sessionFiles(in projectDirs: [URL]) throws -> [SessionFile] {
        try projectDirs.flatMap { projectDir in
            let projectPath = decodeProjectPath(projectDir.lastPathComponent)
            return try jsonlFiles(in: projectDir).map {
                SessionFile(file: $0, projectPath: projectPath)
            }
        }
    }

    /// Scans partial entry slices to recover metadata without decoding the whole session file.
    private func scanMetadata(entries: some Sequence<ClaudeCodeEntry>, projectPath: String?) -> SessionMetadata {
        var meta = SessionMetadata(
            createdAt: nil, model: nil, resolvedProjectPath: projectPath, hasSidechain: false
        )
        for entry in entries {
            if let cwd = entry.cwd, !cwd.isEmpty {
                meta.resolvedProjectPath = cwd
            }
            if entry.isSidechain == true {
                meta.hasSidechain = true
            }
            if meta.createdAt == nil, let timestamp = entry.timestamp {
                meta.createdAt = parseISO8601(timestamp)
            }
            if meta.model == nil, let model = entry.model {
                meta.model = model
            }
        }
        return meta
    }

    /// Builds a summary using head reads for metadata and tail reads for the latest user prompt.
    public func summary(for file: URL, projectPath: String?) throws -> SessionSummary {
        let fileStem = file.deletingPathExtension().lastPathComponent
        let resumeScan = try scanFrontResumeEntries(file: file)
        let sessionId = preferredResumeDisplayId(from: resumeScan, fileStem: fileStem)
        let rawHead = try readRawHeadEntries(file: file)
        let headEntries = rawHead.filter { !shouldSkipEntry($0) }
        let meta = scanMetadata(entries: headEntries, projectPath: projectPath)

        // First meaningful user message from head entries (used for session lookup by opening prompt).
        let headUserMessages = headEntries.compactMap { entry -> String? in
            guard extractRole(from: entry) == .user else { return nil }
            let content = extractContent(from: entry)
            let decoded = ClaudeCodeContentDecoder.decode(content)
            return decoded.isEmpty ? nil : decoded
        }
        let initialPrompt = MessageFilter.firstMeaningful(headUserMessages)

        // Read only the tail to avoid loading very large observer sessions just for the preview line.
        let userMessages: [String] = try fileReader.readRecentValues(
            from: file,
            as: ClaudeCodeEntry.self,
            initialMaxBytes: 262_144,
            limit: 20
        ) { entry in
            guard extractRole(from: entry) == .user else {
                return nil
            }
            let content = extractContent(from: entry)
            return content.isEmpty ? nil : content
        }
        let decodedMessages = userMessages.map { ClaudeCodeContentDecoder.decode($0) }
        let lastUserMessage = MessageFilter.lastMeaningful(decodedMessages)

        let lastMessageAt = FileSystemHelper.fileModificationDate(file, fileSystem: fileSystem)

        return SessionSummary(
            id: sessionId,
            source: .claudeCode,
            projectPath: meta.resolvedProjectPath,
            createdAt: meta.createdAt ?? Date.distantPast,
            lastMessageAt: lastMessageAt,
            model: meta.model,
            messageCount: 0,
            lastUserMessage: lastUserMessage,
            byteSize: FileSystemHelper.fileSize(file, fileSystem: fileSystem),
            isObserverSession: meta.isObserver,
            initialPrompt: initialPrompt
        )
    }

    public func conversation(from file: URL, sessionId: String, projectPath: String?, limit: Int?) throws -> UnifiedConversation {
        let meta = try readConversationMetadata(file: file, projectPath: projectPath)
        let messages = try readConversationMessages(file: file, limit: limit)

        return UnifiedConversation(
            id: sessionId,
            source: .claudeCode,
            projectPath: meta.resolvedProjectPath,
            createdAt: meta.createdAt ?? Date.distantPast,
            model: meta.model,
            messages: messages,
            isObserverSession: meta.isObserver
        )
    }

    private func readConversationMetadata(file: URL, projectPath: String?) throws -> SessionMetadata {
        try scanMetadata(entries: readMetadataEntries(file: file), projectPath: projectPath)
    }

    private func readConversationMessages(file: URL, limit: Int?) throws -> [UnifiedMessage] {
        if let limit, limit > 0 {
            return try fileReader.readRecentValues(
                from: file,
                as: ClaudeCodeEntry.self,
                initialMaxBytes: 262_144,
                limit: limit,
                transform: mapMessage(from:)
            )
        }

        return try parseMessages(fileReader.readAllEntries(from: file, as: ClaudeCodeEntry.self))
    }

    /// Head lines without filtering — metadata (cwd, model) from early user/assistant turns.
    private func readRawHeadEntries(file: URL) throws -> [ClaudeCodeEntry] {
        try fileReader.readHeadEntries(
            from: file,
            as: ClaudeCodeEntry.self,
            maxBytes: 32768,
            maxLines: 50
        )
    }

    private enum ResumeScanLimits {
        /// Slug metadata (`custom-title`) can appear thousands of lines in after snapshots and progress noise.
        static let maxBytes = 8 * 1024 * 1024
    }

    /// Reads the front of the file far enough to capture `custom-title` / `agent-name` resume labels.
    private func scanFrontResumeEntries(file: URL) throws -> [ClaudeCodeEntry] {
        try fileReader.readHeadEntries(
            from: file,
            as: ClaudeCodeEntry.self,
            maxBytes: ResumeScanLimits.maxBytes
        )
    }

    private func readMetadataEntries(file: URL) throws -> [ClaudeCodeEntry] {
        try readRawHeadEntries(file: file).filter { !shouldSkipEntry($0) }
    }

    /// Prefers `custom-title` / `agent-name`, then a `sessionId` that differs from the filename stem (slug-in-JSON).
    private func preferredResumeDisplayId(from entries: [ClaudeCodeEntry], fileStem: String) -> String {
        for entry in entries {
            if entry.entryType == .customTitle, let title = entry.customTitle, !title.isEmpty {
                return title
            }
        }
        for entry in entries {
            if entry.entryType == .agentName, let name = entry.agentName, !name.isEmpty {
                return name
            }
        }
        for entry in entries {
            if let sid = entry.sessionId, !sid.isEmpty, sid != fileStem {
                return sid
            }
        }
        return fileStem
    }

    /// True when any scanned line carries the resume id on `sessionId`, `customTitle`, or `agentName`.
    private func file(_ file: URL, hasSessionIdentifier id: String) throws -> Bool {
        try scanFrontResumeEntries(file: file).contains { matchesResumeIdentifier(entry: $0, id: id) }
    }

    private func matchesResumeIdentifier(entry: ClaudeCodeEntry, id: String) -> Bool {
        if entry.sessionId == id { return true }
        if entry.customTitle == id { return true }
        if entry.agentName == id { return true }
        return false
    }

    private func parseMessages(_ entries: [ClaudeCodeEntry]) -> [UnifiedMessage] {
        entries.compactMap(mapMessage(from:))
    }

    private func mapMessage(from entry: ClaudeCodeEntry) -> UnifiedMessage? {
        guard !shouldSkipEntry(entry),
              let role = extractRole(from: entry),
              role == .user || role == .assistant
        else {
            return nil
        }

        let content = extractContent(from: entry)
        guard !content.isEmpty else {
            return nil
        }

        return UnifiedMessage(
            role: role,
            content: content,
            timestamp: entry.timestamp.flatMap(parseISO8601)
        )
    }

    public func decodeLine(_ line: String) -> ClaudeCodeEntry? {
        JSONLParser.decodeLine(line, as: ClaudeCodeEntry.self)
    }

    public func shouldSkipEntry(_ entry: ClaudeCodeEntry) -> Bool {
        // Progress and file-history snapshots are implementation noise, not user-visible conversation turns.
        switch entry.entryType {
        case .progress, .fileHistorySnapshot, .customTitle, .agentName:
            return true
        case .user, .assistant, .system, .none:
            return false
        }
    }

    public func extractRole(from entry: ClaudeCodeEntry) -> MessageRole? {
        if entry.entryType == .user {
            return .user
        }
        if entry.message?.messageRole == .assistant {
            return .assistant
        }
        return nil
    }

    public func extractContent(from entry: ClaudeCodeEntry) -> String {
        entry.message?.content?.textContent ?? ""
    }

    /// Decode encoded-cwd: "-Users-example-workspace-foo" → "/Users/example/workspace/foo"
    public static func decodeProjectPath(_ encoded: String) -> String? {
        guard encoded.hasPrefix("-") else { return nil }
        return "/" + encoded.dropFirst().replacingOccurrences(of: "-", with: "/")
    }

    private func decodeProjectPath(_ encoded: String) -> String? {
        Self.decodeProjectPath(encoded)
    }

    private func parseISO8601(_ string: String) -> Date? {
        DateUtils.parseISO8601(string)
    }
}
