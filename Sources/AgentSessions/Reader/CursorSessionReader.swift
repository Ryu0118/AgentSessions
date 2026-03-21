import Foundation

/// Reads Cursor sessions from either `store.db` files or agent transcript fallbacks.
public struct CursorSessionReader: SessionReader, Sendable {
    private static let decoder = JSONDecoder()

    public let source: AgentSource = .cursor

    private let fileSystem: any FileSystemProtocol
    private let sqlite: any SQLiteReader
    private let baseDir: URL
    private let transcriptStore: CursorTranscriptStore

    public init(
        fileSystem: any FileSystemProtocol = DefaultFileSystem(),
        sqlite: any SQLiteReader = DefaultSQLiteReader(),
        baseDir: URL? = nil
    ) {
        let homeDirectory = fileSystem.homeDirectoryForCurrentUser
        let chatsDirectory = baseDir ?? homeDirectory
            .appendingPathComponent(".cursor/chats")
        let projectsDirectory = homeDirectory
            .appendingPathComponent(".cursor/projects")

        self.fileSystem = fileSystem
        self.sqlite = sqlite
        self.baseDir = chatsDirectory
        transcriptStore = CursorTranscriptStore(
            fileSystem: fileSystem,
            projectsDir: projectsDirectory
        )
    }

    public func listSessions() async throws -> [SessionSummary] {
        async let dbSummaries = listDatabaseSessions()
        async let transcriptSummaries = transcriptStore.listSummaries()

        let merged = try mergeSummaries(
            databaseSummaries: await dbSummaries,
            transcriptSummaries: await transcriptSummaries
        )
        return merged
    }

    public func loadSession(id: String, storagePath directPath: String?, limit: Int?) async throws -> UnifiedConversation? {
        if let loaded = try loadDatabaseSession(id: id, directPath: directPath, limit: limit) {
            return loaded
        }

        return try transcriptStore.loadSession(
            id: id,
            projectPath: transcriptStore.projectPath(forSessionId: id),
            limit: limit
        )
    }

    /// Session metadata stored in Cursor's `meta` table.
    public struct CursorSessionMetadata {
        public let agentId: String
        public let name: String?
        public let createdAt: Date?
        public let lastUsedModel: String?

        public init(agentId: String, name: String?, createdAt: Date?, lastUsedModel: String?) {
            self.agentId = agentId
            self.name = name
            self.createdAt = createdAt
            self.lastUsedModel = lastUsedModel
        }
    }

    private struct MetadataRow {
        let key: String
        let value: String

        init?(_ raw: [String: Any]) {
            guard let key = raw["key"] as? String,
                  let value = raw["value"] as? String
            else {
                return nil
            }

            self.key = key
            self.value = value
        }
    }

    private struct WorkspaceJSON: Decodable {
        let folder: String?
    }

    /// Decodes the JSON payload stored in Cursor's `meta` table.
    public struct CursorSessionMetadataPayload: Decodable {
        public let agentId: String?
        public let name: String?
        public let createdAtMilliseconds: Double?
        public let lastUsedModel: String?

        private enum CodingKeys: String, CodingKey {
            case agentId
            case name
            case createdAt
            case lastUsedModel
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            agentId = try container.decodeIfPresent(String.self, forKey: .agentId)
            name = try container.decodeIfPresent(String.self, forKey: .name)
            lastUsedModel = try container.decodeIfPresent(String.self, forKey: .lastUsedModel)
            createdAtMilliseconds = Self.decodeMilliseconds(from: container)
        }

        private static func decodeMilliseconds(
            from container: KeyedDecodingContainer<CodingKeys>
        ) -> Double? {
            if let value = try? container.decodeIfPresent(Double.self, forKey: .createdAt) {
                return value
            }
            if let value = try? container.decodeIfPresent(Int64.self, forKey: .createdAt) {
                return Double(value)
            }
            if let value = try? container.decodeIfPresent(String.self, forKey: .createdAt) {
                return Double(value)
            }
            return nil
        }
    }

    /// Discovers `store.db` files under Cursor's `<workspace-hash>/<session-id>/` hierarchy.
    public func findStoreDatabases(in directory: URL) throws -> [String] {
        try fileSystem.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )
        .flatMap { workspaceDirectory in
            (try? fileSystem.contentsOfDirectory(
                at: workspaceDirectory,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            ))
            .map { $0.map { $0.appendingPathComponent("store.db") } } ?? []
        }
        .filter { fileSystem.fileExists(atPath: $0.path) }
        .map(\.path)
    }

    public func readMetadata(fromDatabaseAt databasePath: String) throws -> CursorSessionMetadata? {
        let rows = try sqlite.query(dbPath: databasePath, sql: "SELECT key, value FROM meta")

        for row in rows {
            guard let metadataRow = MetadataRow(row),
                  let jsonData = CursorBlobParser.hexDecode(metadataRow.value),
                  let payload = try? Self.decoder.decode(CursorSessionMetadataPayload.self, from: jsonData),
                  let agentId = payload.agentId,
                  !agentId.isEmpty
            else {
                continue
            }

            return CursorSessionMetadata(
                agentId: agentId,
                name: payload.name,
                createdAt: payload.createdAtMilliseconds.map {
                    Date(timeIntervalSince1970: $0 / 1000.0)
                },
                lastUsedModel: payload.lastUsedModel
            )
        }

        return nil
    }

    public func conversation(
        fromDatabaseAt databasePath: String,
        metadata: CursorSessionMetadata,
        limit: Int?,
        projectPath: String? = nil
    ) throws -> UnifiedConversation {
        let blobs = try loadMessageBlobs(fromDatabaseAt: databasePath, limit: limit)
        let messages = limitedMessages(from: blobs, limit: limit)

        return UnifiedConversation(
            id: metadata.agentId,
            source: .cursor,
            projectPath: projectPath ?? resolveProjectPath(dbPath: databasePath, sessionId: metadata.agentId),
            createdAt: metadata.createdAt ?? Date.distantPast,
            model: metadata.lastUsedModel,
            messages: messages
        )
    }

    public func summary(forDatabaseAt databasePath: String) throws -> SessionSummary {
        guard let metadata = try readMetadata(fromDatabaseAt: databasePath) else {
            throw SessionReaderError.invalidMetadata("No valid metadata found in \(databasePath)")
        }

        let databaseURL = URL(fileURLWithPath: databasePath)
        return SessionSummary(
            id: metadata.agentId,
            source: .cursor,
            projectPath: resolveProjectPath(dbPath: databasePath, sessionId: metadata.agentId),
            createdAt: metadata.createdAt ?? Date.distantPast,
            lastMessageAt: FileSystemHelper.fileModificationDate(databaseURL, fileSystem: fileSystem),
            model: metadata.lastUsedModel,
            messageCount: 0,
            lastUserMessage: metadata.name?.isEmpty == false ? metadata.name : nil,
            byteSize: FileSystemHelper.fileSize(databaseURL, fileSystem: fileSystem),
            storagePath: databasePath
        )
    }

    private func listDatabaseSessions() async throws -> [SessionSummary] {
        guard fileSystem.fileExists(atPath: baseDir.path) else {
            return []
        }

        let dbPaths = try findStoreDatabases(in: baseDir)

        return await withTaskGroup(of: SessionSummary?.self, returning: [SessionSummary].self) { group in
            for dbPath in dbPaths {
                group.addTask {
                    try? self.summary(forDatabaseAt: dbPath)
                }
            }

            var results: [SessionSummary] = []
            for await result in group {
                if let result {
                    results.append(result)
                }
            }
            return results
        }
    }

    private func loadDatabaseSession(id: String, directPath: String?, limit: Int?) throws -> UnifiedConversation? {
        let dbPaths = try candidateDatabasePaths(directPath: directPath)
        guard let (dbPath, metadata) = findMatchingDatabaseSession(
            id: id,
            dbPaths: dbPaths,
            directPath: directPath
        ) else {
            return nil
        }

        return try conversation(
            fromDatabaseAt: dbPath,
            metadata: metadata,
            limit: limit,
            projectPath: resolveProjectPath(dbPath: dbPath, sessionId: metadata.agentId)
        )
    }

    private func candidateDatabasePaths(directPath: String?) throws -> [String] {
        if let directPath, fileSystem.fileExists(atPath: directPath) {
            return [directPath]
        }
        guard fileSystem.fileExists(atPath: baseDir.path) else {
            return []
        }
        return try findStoreDatabases(in: baseDir)
    }

    private func findMatchingDatabaseSession(
        id: String,
        dbPaths: [String],
        directPath _: String?
    ) -> (dbPath: String, metadata: CursorSessionMetadata)? {
        dbPaths.lazy
            .compactMap { path -> (String, CursorSessionMetadata)? in
                guard let metadata = try? readMetadata(fromDatabaseAt: path) else {
                    return nil
                }
                return (path, metadata)
            }
            .first(where: { $0.1.agentId == id })
    }

    /// Prefers `store.db` summaries when IDs collide because they carry richer metadata than transcripts.
    private func mergeSummaries(
        databaseSummaries: [SessionSummary],
        transcriptSummaries: [SessionSummary]
    ) -> [SessionSummary] {
        var summariesByID: [String: SessionSummary] = [:]

        for summary in transcriptSummaries {
            summariesByID[summary.id] = summary
        }
        for summary in databaseSummaries {
            summariesByID[summary.id] = summary
        }

        return Array(summariesByID.values)
    }

    /// Oversamples recent blobs when limiting so deduplication still has enough context to keep turn order sensible.
    private func loadMessageBlobs(fromDatabaseAt databasePath: String, limit: Int?) throws -> [(id: String, data: Data)] {
        if let limit, limit > 0 {
            let recentBlobLimit = max(limit * 8, 800)
            return try sqlite.queryRecentBlobs(dbPath: databasePath, limit: recentBlobLimit)
        }

        return try sqlite.queryBlobs(dbPath: databasePath)
    }

    private func limitedMessages(from blobs: [(id: String, data: Data)], limit: Int?) -> [UnifiedMessage] {
        let allMessages = blobs.compactMap { CursorBlobParser.extractMessage(from: $0.data) }
        let deduplicatedMessages = deduplicateMessages(allMessages)

        guard let limit, limit > 0 else {
            return deduplicatedMessages
        }
        return Array(deduplicatedMessages.suffix(limit))
    }

    /// Cursor can store the same turn in multiple blob shapes, so deduplicate by role plus a stable content prefix.
    private func deduplicateMessages(_ messages: [UnifiedMessage]) -> [UnifiedMessage] {
        var seen = Set<String>()
        return messages.filter { message in
            let key = "\(message.role.rawValue):\(message.content.prefix(200))"
            return seen.insert(key).inserted
        }
    }

    /// Resolves the project path by looking up Cursor's workspace hash in `workspaceStorage`.
    private func resolveWorkspacePath(dbPath: String) -> String? {
        let databaseURL = URL(fileURLWithPath: dbPath)
        let workspaceHash = databaseURL
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .lastPathComponent

        let workspaceStorage = resolveWorkspaceStorageDirectory()
        let workspaceJSON = workspaceStorage
            .appendingPathComponent(workspaceHash)
            .appendingPathComponent("workspace.json")

        guard let data = fileSystem.contents(atPath: workspaceJSON.path),
              let workspace = try? Self.decoder.decode(WorkspaceJSON.self, from: data),
              let folder = workspace.folder,
              folder.hasPrefix("file://")
        else {
            return nil
        }

        return String(folder.dropFirst("file://".count))
    }

    private func resolveWorkspaceStorageDirectory() -> URL {
        #if os(macOS)
            return fileSystem.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Application Support/Cursor/User/workspaceStorage")
        #elseif os(Windows)
            return URL(fileURLWithPath: ProcessInfo.processInfo.environment["APPDATA"] ?? "")
                .appendingPathComponent("Cursor/User/workspaceStorage")
        #else
            return fileSystem.homeDirectoryForCurrentUser
                .appendingPathComponent(".config/Cursor/User/workspaceStorage")
        #endif
    }

    private func resolveProjectPath(dbPath: String, sessionId: String) -> String? {
        resolveWorkspacePath(dbPath: dbPath) ?? transcriptStore.projectPath(forSessionId: sessionId)
    }
}
