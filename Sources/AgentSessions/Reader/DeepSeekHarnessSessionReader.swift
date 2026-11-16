import Foundation

/// Reads DeepSeek Harness sessions from `~/.dsh/sessions/<encoded-cwd>/session-<id>/session.v4.jsonl.zstd`.
public struct DeepSeekHarnessSessionReader: SessionReader, Sendable {
    public let source: AgentSource = .deepseekHarness

    private let fileSystem: any FileSystemProtocol
    private let sessionsDir: URL
    private let projcacheDir: URL

    private enum Constants {
        static let sessionFileName = "session.v4.jsonl.zstd"
        static let sessionPrefix = "session-"
        static let userMessage = "user/message"
        static let assistantMessage = "assistant/message"
        static let sessionType = "session"
        static let textBlock = "text"
    }

    private struct SessionLocation {
        let id: String
        let fileURL: URL
        let projectPath: String?
    }

    private struct SessionEvent: Decodable {
        let type: String
        let time: Int64?
        let data: EventData?
        let id: String?
        let cwd: String?
        let createdAt: Int64?
        let version: Int?

        struct EventData: Decodable {
            let content: [ContentBlock]?
            let message: NestedMessage?
            let role: String?
            let id: String?

            struct NestedMessage: Decodable {
                let role: String?
                let content: [ContentBlock]?
            }

            struct ContentBlock: Decodable {
                let type: String?
                let text: String?
            }
        }
    }

    public init(
        fileSystem: any FileSystemProtocol = DefaultFileSystem(),
        baseDir: URL? = nil
    ) {
        self.fileSystem = fileSystem
        let root = baseDir ?? fileSystem.homeDirectoryForCurrentUser.appendingPathComponent(".dsh")
        sessionsDir = root.appendingPathComponent("sessions")
        projcacheDir = root.appendingPathComponent("storages/session_projcache/sessions")
    }

    public func listSessions() async throws -> [SessionSummary] {
        guard fileSystem.fileExists(atPath: sessionsDir.path) else { return [] }
        let locations = try findSessionLocations()
        return await SessionSummaryCollector.collect(locations) { location in
            try summary(for: location)
        }
    }

    public func loadSession(id: String, storagePath: String?, limit: Int?) async throws -> UnifiedConversation? {
        if let storagePath {
            let fileURL = URL(fileURLWithPath: storagePath)
            let location = SessionLocation(
                id: id,
                fileURL: fileURL,
                projectPath: projectPathHint(for: fileURL)
            )
            return try conversation(from: location, limit: limit)
        }
        guard fileSystem.fileExists(atPath: sessionsDir.path) else { return nil }
        guard let location = try findSessionLocations().first(where: {
            $0.id == id || $0.id.hasSuffix(id) || $0.id.contains(id)
        }) else {
            return nil
        }
        return try conversation(from: location, limit: limit)
    }

    /// Parses NDJSON session events into unified chat messages (text blocks only).
    private static func messages(from events: [SessionEvent]) -> (messages: [UnifiedMessage], model: String?, cwd: String?, createdAt: Date?, sessionId: String?) {
        var messages: [UnifiedMessage] = []
        var cwd: String?
        var createdAt: Date?
        var sessionId: String?

        for event in events {
            if event.type == Constants.sessionType {
                cwd = event.cwd
                if let created = event.createdAt {
                    createdAt = DateUtils.date(fromEpochMillis: Int(created))
                }
                sessionId = event.id
                continue
            }

            guard let role = role(for: event),
                  let text = textContent(from: event),
                  !text.isEmpty
            else {
                continue
            }
            let timestamp = event.time.map { DateUtils.date(fromEpochMillis: Int($0)) }
            messages.append(UnifiedMessage(role: role, content: text, timestamp: timestamp))
        }
        return (messages, nil, cwd, createdAt, sessionId)
    }

    static func decompressZstd(_ data: Data) throws -> Data {
        try ZstdCodec.decompress(data)
    }

    /// Encodes a workspace path the same way DeepSeek Harness names session parent directories.
    public static func encodedWorkspaceDirectory(for path: String) -> String {
        let trimmed = path.hasPrefix("/") ? String(path.dropFirst()) : path
        return "--" + trimmed.replacingOccurrences(of: "/", with: "-") + "--"
    }

    private func summary(for location: SessionLocation) throws -> SessionSummary {
        // Prefer projcache for list metadata so we do not decompress every zstd log.
        if let cache = projcacheRecord(for: location.id) {
            let byteSize = (try? fileSystem.attributesOfItem(atPath: location.fileURL.path)[.size] as? NSNumber)?.int64Value
            let createdAt = cache.createdAt ?? Date(timeIntervalSince1970: 0)
            let initialPrompt = cache.firstPrompt
            let lastUserMessage = cache.title ?? initialPrompt
            return SessionSummary(
                id: location.id,
                source: .deepseekHarness,
                projectPath: cache.cwd ?? location.projectPath,
                createdAt: createdAt,
                lastMessageAt: cache.updatedAt ?? createdAt,
                model: cache.model,
                messageCount: cache.promptCount,
                lastUserMessage: lastUserMessage.map { String($0.prefix(200)) },
                byteSize: byteSize,
                storagePath: location.fileURL.path,
                initialPrompt: initialPrompt.map { String($0.prefix(200)) }
            )
        }

        let conversation = try conversation(from: location, limit: nil)
        let userMessages = conversation.messages.filter { $0.role == .user }.map(\.content)
        let byteSize = (try? fileSystem.attributesOfItem(atPath: location.fileURL.path)[.size] as? NSNumber)?.int64Value
        return SessionSummary(
            id: location.id,
            source: .deepseekHarness,
            projectPath: conversation.projectPath ?? location.projectPath,
            createdAt: conversation.createdAt,
            lastMessageAt: conversation.messages.last?.timestamp,
            model: conversation.model,
            messageCount: conversation.messages.count,
            lastUserMessage: MessageFilter.lastMeaningful(userMessages),
            byteSize: byteSize,
            storagePath: location.fileURL.path,
            initialPrompt: MessageFilter.firstMeaningful(userMessages)
        )
    }

    private struct ProjcacheRecord {
        let cwd: String?
        let createdAt: Date?
        let updatedAt: Date?
        let title: String?
        let firstPrompt: String?
        let promptCount: Int
        let model: String?
    }

    private func projcacheRecord(for sessionId: String) -> ProjcacheRecord? {
        let cacheFile = projcacheDir.appendingPathComponent("\(sessionId).json")
        guard let data = fileSystem.contents(atPath: cacheFile.path),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let record = json["record"] as? [String: Any]
        else {
            return nil
        }
        let identity = record["identity"] as? [String: Any]
        let rows = record["rows"] as? [String: Any]
        let title = (rows?["title"] as? [String: Any])?["val"] as? String
        let titleInput = (rows?["titleInput"] as? [String: Any])?["val"] as? [String: Any]
        let firstPrompt = (titleInput?["first"] as? [String: Any])?["text"] as? String
        let promptCount = titleInput?["count"] as? Int ?? 0
        let modelSelection = (rows?["modelSelection"] as? [String: Any])?["val"] as? [String: Any]
        let model = modelSelection?["model"] as? String
        let createdMillis = identity?["createdAt"] as? Int64
            ?? (identity?["createdAt"] as? Int).map(Int64.init)
        // Prefer the highest seq among known rows as a cheap updatedAt proxy.
        let updatedMillis = [
            (rows?["title"] as? [String: Any])?["seq"] as? Int64,
            (rows?["titleInput"] as? [String: Any])?["seq"] as? Int64,
        ].compactMap { $0 }.max().flatMap { seq -> Int64? in
            // seq is not epoch time; keep createdAt when we lack a real timestamp.
            _ = seq
            return createdMillis
        }
        return ProjcacheRecord(
            cwd: identity?["cwd"] as? String,
            createdAt: createdMillis.map { DateUtils.date(fromEpochMillis: Int($0)) },
            updatedAt: updatedMillis.map { DateUtils.date(fromEpochMillis: Int($0)) },
            title: title,
            firstPrompt: firstPrompt,
            promptCount: promptCount,
            model: model
        )
    }

    private func conversation(from location: SessionLocation, limit: Int?) throws -> UnifiedConversation {
        guard let compressed = fileSystem.contents(atPath: location.fileURL.path) else {
            throw SessionReaderError.cannotReadFile(location.fileURL.path)
        }
        let decompressed = try Self.decompressZstd(compressed)
        guard let text = String(data: decompressed, encoding: .utf8) else {
            throw SessionReaderError.cannotReadFile(location.fileURL.path)
        }
        let events = text.split(whereSeparator: \.isNewline).compactMap { line -> SessionEvent? in
            guard let data = line.data(using: .utf8) else { return nil }
            return try? JSONDecoder().decode(SessionEvent.self, from: data)
        }
        let assembled = Self.messages(from: events)
        let messages = limit.map { Array(assembled.messages.suffix($0)) } ?? assembled.messages
        let createdAt = assembled.createdAt
            ?? messages.first?.timestamp
            ?? Date(timeIntervalSince1970: 0)
        return UnifiedConversation(
            id: assembled.sessionId ?? location.id,
            source: .deepseekHarness,
            projectPath: assembled.cwd ?? location.projectPath,
            createdAt: createdAt,
            model: assembled.model ?? projcacheModel(for: location.id),
            messages: messages
        )
    }

    private func findSessionLocations() throws -> [SessionLocation] {
        let workspaceDirs = try fileSystem.contentsOfDirectory(
            at: sessionsDir,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )
        var locations: [SessionLocation] = []
        for workspaceDir in workspaceDirs {
            let sessionDirs = (try? fileSystem.contentsOfDirectory(
                at: workspaceDir,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            )) ?? []
            for sessionDir in sessionDirs {
                let fileURL = sessionDir.appendingPathComponent(Constants.sessionFileName)
                guard fileSystem.fileExists(atPath: fileURL.path) else { continue }
                let id = sessionDir.lastPathComponent
                locations.append(
                    SessionLocation(
                        id: id,
                        fileURL: fileURL,
                        projectPath: projectPathHint(for: fileURL)
                    )
                )
            }
        }
        return locations
    }

    private func projectPathHint(for fileURL: URL) -> String? {
        // .../<encoded-cwd>/session-<id>/session.v4.jsonl.zstd
        let encoded = fileURL
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .lastPathComponent
        return Self.decodeWorkspaceDirectory(encoded)
    }

    static func decodeWorkspaceDirectory(_ encoded: String) -> String? {
        guard encoded.hasPrefix("--"), encoded.hasSuffix("--"), encoded.count > 4 else {
            return nil
        }
        // Encoding replaces `/` with `-`, which is lossy; prefer cwd from the session event when loading.
        let inner = String(encoded.dropFirst(2).dropLast(2))
        return "/" + inner.replacingOccurrences(of: "-", with: "/")
    }

    private func projcacheModel(for sessionId: String) -> String? {
        projcacheRecord(for: sessionId)?.model
    }

    private static func role(for event: SessionEvent) -> MessageRole? {
        switch event.type {
        case Constants.userMessage: return .user
        case Constants.assistantMessage: return .assistant
        default: return nil
        }
    }

    private static func textContent(from event: SessionEvent) -> String? {
        let blocks = event.data?.message?.content ?? event.data?.content ?? []
        let texts = blocks.compactMap { block -> String? in
            guard block.type == Constants.textBlock || block.type == nil else { return nil }
            return block.text
        }
        let joined = texts.joined()
        return joined.isEmpty ? nil : joined
    }
}
