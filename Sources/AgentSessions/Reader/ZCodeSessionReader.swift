import Foundation

/// Reads ZCode sessions from `~/.zcode/cli/db/db.sqlite` (`session` / `message` / `part`).
public struct ZCodeSessionReader: SessionReader, Sendable {
    public let source: AgentSource = .zcode

    private let fileSystem: any FileSystemProtocol
    private let sqlite: any SQLiteReader
    private let databasePath: String

    private enum Constants {
        static let interactiveTask = "interactive"
        static let textPart = "text"
        static let roleUser = "user"
        static let roleAssistant = "assistant"
    }

    private struct SessionRow {
        let id: String
        let directory: String?
        let title: String?
        let createdAt: Date
        let updatedAt: Date?
        let taskType: String?

        init?(_ raw: [String: Any]) {
            guard let id = raw["id"] as? String else { return nil }
            let createdMillis = (raw["time_created"] as? Int64)
                ?? (raw["time_created"] as? Int).map(Int64.init)
                ?? 0
            let updatedMillis = (raw["time_updated"] as? Int64)
                ?? (raw["time_updated"] as? Int).map(Int64.init)
            self.id = id
            directory = raw["directory"] as? String
            title = raw["title"] as? String
            createdAt = DateUtils.date(fromEpochMillis: Int(createdMillis))
            updatedAt = updatedMillis.map { DateUtils.date(fromEpochMillis: Int($0)) }
            taskType = raw["task_type"] as? String
        }
    }

    private struct MessageRow {
        let id: String
        let role: String
        let createdAt: Date?
        let sequence: Int64
        let modelId: String?

        init?(_ raw: [String: Any]) {
            guard let id = raw["id"] as? String else { return nil }
            let sequence = (raw["sequence"] as? Int64)
                ?? (raw["sequence"] as? Int).map(Int64.init)
                ?? 0
            guard let dataString = raw["data"] as? String,
                  let data = dataString.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let role = json["role"] as? String
            else {
                return nil
            }
            let createdMillis = ((json["time"] as? [String: Any])?["created"] as? Int64)
                ?? ((json["time"] as? [String: Any])?["created"] as? Int).map(Int64.init)
                ?? (raw["time_created"] as? Int64)
                ?? (raw["time_created"] as? Int).map(Int64.init)
            self.id = id
            self.role = role
            self.createdAt = createdMillis.map { DateUtils.date(fromEpochMillis: Int($0)) }
            self.sequence = sequence
            self.modelId = json["modelId"] as? String
        }
    }

    private struct PartRow {
        let messageId: String
        let type: String
        let text: String?
        let sequence: Int64

        init?(_ raw: [String: Any]) {
            guard let messageId = raw["message_id"] as? String else { return nil }
            let sequence = (raw["sequence"] as? Int64)
                ?? (raw["sequence"] as? Int).map(Int64.init)
                ?? 0
            guard let dataString = raw["data"] as? String,
                  let data = dataString.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let type = json["type"] as? String
            else {
                return nil
            }
            self.messageId = messageId
            self.type = type
            self.text = json["text"] as? String
            self.sequence = sequence
        }
    }

    public init(
        fileSystem: any FileSystemProtocol = DefaultFileSystem(),
        sqlite: any SQLiteReader = DefaultSQLiteReader(),
        databasePath: String? = nil
    ) {
        self.fileSystem = fileSystem
        self.sqlite = sqlite
        let home = fileSystem.homeDirectoryForCurrentUser
        self.databasePath = databasePath
            ?? home.appendingPathComponent(".zcode/cli/db/db.sqlite").path
    }

    public func listSessions() async throws -> [SessionSummary] {
        guard fileSystem.fileExists(atPath: databasePath) else { return [] }
        let rows = try loadSessionRows()
        return await SessionSummaryCollector.collect(rows) { row in
            try summary(for: row)
        }
    }

    public func loadSession(id: String, storagePath _: String?, limit: Int?) async throws -> UnifiedConversation? {
        guard fileSystem.fileExists(atPath: databasePath) else { return nil }
        guard let row = try loadSessionRows().first(where: { $0.id == id || $0.id.hasSuffix(id) }) else {
            return nil
        }
        return try conversation(for: row, limit: limit)
    }

    /// Builds chat messages from ZCode message + text parts (reasoning/tool parts are skipped).
    static func messages(
        messageRows: [[String: Any]],
        partRows: [[String: Any]]
    ) -> (messages: [UnifiedMessage], model: String?) {
        let partsByMessage = Dictionary(grouping: partRows.compactMap(PartRow.init)) { $0.messageId }
        var messages: [UnifiedMessage] = []
        var model: String?

        let ordered = messageRows.compactMap(MessageRow.init).sorted { $0.sequence < $1.sequence }
        for message in ordered {
            if let modelId = message.modelId, !modelId.isEmpty {
                model = modelId
            }
            let role: MessageRole?
            switch message.role {
            case Constants.roleUser: role = .user
            case Constants.roleAssistant: role = .assistant
            default: role = nil
            }
            guard let role else { continue }
            let text = (partsByMessage[message.id] ?? [])
                .filter { $0.type == Constants.textPart }
                .sorted { $0.sequence < $1.sequence }
                .compactMap(\.text)
                .joined()
            guard !text.isEmpty else { continue }
            messages.append(UnifiedMessage(role: role, content: text, timestamp: message.createdAt))
        }
        return (messages, model)
    }

    private func summary(for row: SessionRow) throws -> SessionSummary {
        let conversation = try conversation(for: row, limit: nil)
        let userMessages = conversation.messages.filter { $0.role == .user }.map(\.content)
        return SessionSummary(
            id: row.id,
            source: .zcode,
            projectPath: row.directory,
            createdAt: row.createdAt,
            lastMessageAt: row.updatedAt ?? conversation.messages.last?.timestamp,
            model: conversation.model,
            messageCount: conversation.messages.count,
            lastUserMessage: MessageFilter.lastMeaningful(userMessages),
            byteSize: nil,
            storagePath: databasePath,
            initialPrompt: MessageFilter.firstMeaningful(userMessages)
        )
    }

    private func conversation(for row: SessionRow, limit: Int?) throws -> UnifiedConversation {
        let messageSQL = """
        SELECT id, data, sequence, time_created
        FROM message
        WHERE session_id = '\(escapeSQL(row.id))'
        ORDER BY sequence ASC
        """
        let partSQL = """
        SELECT message_id, data, sequence
        FROM part
        WHERE session_id = '\(escapeSQL(row.id))'
        ORDER BY sequence ASC
        """
        let messageRows = try sqlite.query(dbPath: databasePath, sql: messageSQL)
        let partRows = try sqlite.query(dbPath: databasePath, sql: partSQL)
        let assembled = Self.messages(messageRows: messageRows, partRows: partRows)
        let messages = limit.map { Array(assembled.messages.suffix($0)) } ?? assembled.messages
        return UnifiedConversation(
            id: row.id,
            source: .zcode,
            projectPath: row.directory,
            createdAt: row.createdAt,
            model: assembled.model,
            messages: messages
        )
    }

    private func loadSessionRows() throws -> [SessionRow] {
        let sql = """
        SELECT id, directory, title, time_created, time_updated, task_type, time_archived
        FROM session
        ORDER BY time_updated DESC
        """
        return try sqlite.query(dbPath: databasePath, sql: sql).compactMap { raw in
            guard let row = SessionRow(raw) else { return nil }
            if let archived = raw["time_archived"], !(archived is NSNull) {
                return nil
            }
            if let taskType = row.taskType, taskType != Constants.interactiveTask {
                return nil
            }
            return row
        }
    }

    private func escapeSQL(_ value: String) -> String {
        value.replacingOccurrences(of: "'", with: "''")
    }
}
