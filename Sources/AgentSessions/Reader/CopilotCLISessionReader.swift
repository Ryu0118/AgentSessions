import Foundation

private enum CopilotEventType: String {
    case userMessage = "user.message"
    case assistantMessage = "assistant.message"
    case modelChange = "session.model_change"
}

private enum CopilotWorkspaceKey: String, CaseIterable {
    case currentDirectory = "cwd"
    case gitRoot = "git_root"
}

private enum CopilotStorageComponent: String {
    case directory = ".copilot"
    case sessionStateDirectory = "session-state"
    case eventsFile = "events.jsonl"
    case workspaceFile = "workspace.yaml"
}

private struct CopilotEvent: Decodable, Sendable {
    let type: String
    let timestamp: String?
    let data: CopilotEventData?

    var eventType: CopilotEventType? {
        CopilotEventType(rawValue: type)
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        type = try container.decode(String.self, forKey: .type)
        timestamp = try? container.decodeIfPresent(String.self, forKey: .timestamp)
        data = try? container.decodeIfPresent(CopilotEventData.self, forKey: .data)
    }

    private enum CodingKeys: String, CodingKey {
        case type
        case timestamp
        case data
    }
}

private struct CopilotEventData: Decodable, Sendable {
    let content: String?
    let model: String?
    let newModel: String?

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        content = try? container.decodeIfPresent(String.self, forKey: .content)
        model = try? container.decodeIfPresent(String.self, forKey: .model)
        newModel = try? container.decodeIfPresent(String.self, forKey: .newModel)
    }

    private enum CodingKeys: String, CodingKey {
        case content
        case model
        case newModel
    }
}

/// Reads GitHub Copilot CLI sessions from `~/.copilot/session-state/`.
public struct CopilotCLISessionReader: SessionReader, Sendable {
    public let source: AgentSource = .copilotCLI

    private let fileSystem: any FileSystemProtocol
    private let sessionsDirectory: URL

    public init(fileSystem: any FileSystemProtocol = DefaultFileSystem(), baseDirectory: URL? = nil) {
        self.fileSystem = fileSystem
        let root = baseDirectory ?? fileSystem.homeDirectoryForCurrentUser
            .appendingPathComponent(CopilotStorageComponent.directory.rawValue)
        sessionsDirectory = root.appendingPathComponent(CopilotStorageComponent.sessionStateDirectory.rawValue)
    }

    public func listSessions() async throws -> [SessionSummary] {
        guard fileSystem.fileExists(atPath: sessionsDirectory.path) else { return [] }
        let sessionDirectories = try fileSystem.contentsOfDirectory(
            at: sessionsDirectory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ).filter(isDirectory)

        return await SessionSummaryCollector.collect(sessionDirectories) { sessionDirectory in
            try summary(for: sessionDirectory)
        }
    }

    public func loadSession(id: String, storagePath: String?, limit: Int?) async throws -> UnifiedConversation? {
        guard storagePath != nil || Self.isSessionIDPathComponent(id) else { return nil }
        let sessionDirectory = storagePath.map(URL.init(fileURLWithPath:))
            ?? sessionsDirectory.appendingPathComponent(id)
        let events = readEvents(from: sessionDirectory)
        guard !events.isEmpty else { return nil }

        var messages = Self.messages(from: events)
        if let limit, limit > 0 {
            messages = Array(messages.suffix(limit))
        }

        return UnifiedConversation(
            id: id,
            source: .copilotCLI,
            projectPath: projectPath(in: sessionDirectory),
            createdAt: Self.createdAt(from: events),
            model: Self.model(from: events),
            messages: messages
        )
    }

    private func summary(for sessionDirectory: URL) throws -> SessionSummary {
        let events = readEvents(from: sessionDirectory)
        guard !events.isEmpty else {
            throw SessionReaderError.invalidMetadata(
                "Missing or unreadable events.jsonl in \(sessionDirectory.path)"
            )
        }

        let messages = Self.messages(from: events)
        let userMessages = messages.filter { $0.role == .user }.map(\.content)
        let eventsFile = sessionDirectory.appendingPathComponent(CopilotStorageComponent.eventsFile.rawValue)

        return SessionSummary(
            id: sessionDirectory.lastPathComponent,
            source: .copilotCLI,
            projectPath: projectPath(in: sessionDirectory),
            createdAt: Self.createdAt(from: events),
            lastMessageAt: messages.last?.timestamp,
            model: Self.model(from: events),
            messageCount: messages.count,
            lastUserMessage: MessageFilter.lastMeaningful(userMessages),
            byteSize: FileSystemHelper.fileSize(eventsFile, fileSystem: fileSystem),
            storagePath: sessionDirectory.path,
            initialPrompt: MessageFilter.firstMeaningful(userMessages)
        )
    }

    private func readEvents(from sessionDirectory: URL) -> [CopilotEvent] {
        let eventsFile = sessionDirectory.appendingPathComponent(CopilotStorageComponent.eventsFile.rawValue)
        guard let data = fileSystem.contents(atPath: eventsFile.path) else { return [] }
        return JSONLParser.decodeLines(String(decoding: data, as: UTF8.self), as: CopilotEvent.self)
    }

    /// Prevents an ID from changing the session-store directory when it becomes a path component.
    private static func isSessionIDPathComponent(_ id: String) -> Bool {
        guard !id.isEmpty, id != ".", id != ".." else { return false }
        return id.rangeOfCharacter(from: CharacterSet(charactersIn: "/\\:")) == nil
    }

    private func projectPath(in sessionDirectory: URL) -> String? {
        let workspaceFile = sessionDirectory.appendingPathComponent(CopilotStorageComponent.workspaceFile.rawValue)
        guard let data = fileSystem.contents(atPath: workspaceFile.path) else { return nil }
        let contents = String(decoding: data, as: UTF8.self)
        return CopilotWorkspaceKey.allCases
            .compactMap { value(for: $0, in: contents) }
            .first
    }

    private func value(for key: CopilotWorkspaceKey, in workspace: String) -> String? {
        for line in workspace.split(whereSeparator: \.isNewline) {
            let components = line.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
            guard components.count == 2,
                  String(components[0]).trimmingCharacters(in: .whitespaces) == key.rawValue
            else {
                continue
            }

            let rawValue = String(components[1]).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !rawValue.isEmpty, rawValue != "null", rawValue != "~" else { return nil }
            return Self.unquoteYAMLScalar(rawValue)
        }
        return nil
    }

    private static func unquoteYAMLScalar(_ value: String) -> String {
        if value.count >= 2, value.first == "'", value.last == "'" {
            return String(value.dropFirst().dropLast()).replacingOccurrences(of: "''", with: "'")
        }
        if value.count >= 2, value.first == "\"", value.last == "\"" {
            return String(value.dropFirst().dropLast())
                .replacingOccurrences(of: "\\\"", with: "\"")
                .replacingOccurrences(of: "\\\\", with: "\\")
        }
        return value
    }

    private func isDirectory(at url: URL) -> Bool {
        var isDirectory = ObjCBool(false)
        return fileSystem.fileExists(atPath: url.path, isDirectory: &isDirectory) && isDirectory.boolValue
    }

    private static func messages(from events: [CopilotEvent]) -> [UnifiedMessage] {
        events.compactMap { event in
            guard let type = event.eventType, let content = event.data?.content,
                  !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            else {
                return nil
            }

            let role: MessageRole
            switch type {
            case .userMessage: role = .user
            case .assistantMessage: role = .assistant
            case .modelChange: return nil
            }

            return UnifiedMessage(
                role: role,
                content: content,
                timestamp: event.timestamp.flatMap(DateUtils.parseISO8601)
            )
        }
    }

    private static func createdAt(from events: [CopilotEvent]) -> Date {
        events.lazy
            .compactMap { $0.timestamp.flatMap(DateUtils.parseISO8601) }
            .first ?? .distantPast
    }

    private static func model(from events: [CopilotEvent]) -> String? {
        events.reversed().compactMap { event in
            guard event.eventType == .assistantMessage || event.eventType == .modelChange else { return nil }
            return event.data?.model ?? event.data?.newModel
        }.first { !$0.isEmpty }
    }
}
