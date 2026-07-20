import Foundation

/// Reads kimi-code sessions from `~/.kimi-code/`.
public struct KimiCodeSessionReader: Sendable {
    public let source: AgentSource = .kimiCode
    let fileSystem: any FileSystemProtocol
    let baseDir: URL
    let sessionsDir: URL
    let indexFile: URL

    public init(fileSystem: any FileSystemProtocol = DefaultFileSystem(), baseDir: URL? = nil) {
        self.fileSystem = fileSystem
        let root = baseDir ?? fileSystem.homeDirectoryForCurrentUser.appendingPathComponent(".kimi-code")
        self.baseDir = root
        sessionsDir = root.appendingPathComponent("sessions")
        indexFile = root.appendingPathComponent("session_index.jsonl")
    }

    /// User turns come only from `turn.prompt`. `context.append_message` lines are skipped wholesale:
    /// real prompts never arrive that way, and `role==user` ones are injection/skill/background noise.
    /// Assistant text streams in order between prompts, not `turnId`-paired, so an unmatched turn can't shift replies.
    static func messages(fromWire lines: [KimiWireLine]) -> [UnifiedMessage] {
        var messages: [UnifiedMessage] = []
        var pendingText = ""
        var pendingTime: Int?

        func flushAssistant() {
            defer { pendingText = ""; pendingTime = nil }
            guard !pendingText.isEmpty else { return }
            messages.append(UnifiedMessage(
                role: .assistant,
                content: pendingText,
                timestamp: pendingTime.map(DateUtils.date(fromEpochMillis:))
            ))
        }

        for line in lines {
            guard let type = KimiWireType(rawValue: line.type) else { continue }
            switch type {
            case .turnPrompt:
                flushAssistant()
                let text = (line.input ?? [])
                    .compactMap(\.text)
                    .joined()
                messages.append(UnifiedMessage(
                    role: .user,
                    content: text,
                    timestamp: line.time.map(DateUtils.date(fromEpochMillis:))
                ))
            case .appendLoopEvent:
                guard let event = line.event,
                      KimiLoopEventType(rawValue: event.type) == .contentPart,
                      let part = event.part,
                      KimiPartType(rawValue: part.type) == .text,
                      let text = part.text else { continue }
                if pendingText.isEmpty { pendingTime = line.time }
                pendingText += text
            case .metadata, .configUpdate, .appendMessage:
                continue
            }
        }
        flushAssistant()
        return messages
    }

    static func model(fromWire lines: [KimiWireLine]) -> String? {
        lines.last { KimiWireType(rawValue: $0.type) == .configUpdate && $0.modelAlias != nil }?.modelAlias
    }
}

extension KimiCodeSessionReader: SessionReader {
    public func listSessions() async throws -> [SessionSummary] {
        await SessionSummaryCollector.collect(indexEntries()) { entry in
            summary(for: entry)
        }
    }

    public func loadSession(id: String, storagePath: String?, limit: Int?) async throws -> UnifiedConversation? {
        let sessionDir: URL
        var indexWorkDir: String?
        if let storagePath {
            sessionDir = URL(fileURLWithPath: storagePath)
        } else if let entry = indexEntries().first(where: { $0.sessionId == id }) {
            sessionDir = URL(fileURLWithPath: entry.sessionDir)
            indexWorkDir = entry.workDir
        } else {
            return nil
        }

        let state = readState(sessionDir: sessionDir)
        let wire = readWire(sessionDir: sessionDir)
        var messages = Self.messages(fromWire: wire)
        if let limit, limit > 0 { messages = Array(messages.suffix(limit)) }

        return UnifiedConversation(
            id: id,
            source: .kimiCode,
            projectPath: state?.workDir ?? indexWorkDir,
            createdAt: createdAt(from: state, wire: wire),
            model: Self.model(fromWire: wire),
            messages: messages
        )
    }

    func indexEntries() -> [KimiIndexEntry] {
        guard let data = fileSystem.contents(atPath: indexFile.path) else { return [] }
        return JSONLParser.decodeLines(String(decoding: data, as: UTF8.self), as: KimiIndexEntry.self)
    }

    private func readWire(sessionDir: URL) -> [KimiWireLine] {
        let wireFile = sessionDir.appendingPathComponent("agents/main/wire.jsonl")
        guard let data = fileSystem.contents(atPath: wireFile.path) else { return [] }
        return JSONLParser.decodeLines(String(decoding: data, as: UTF8.self), as: KimiWireLine.self)
    }

    private func readState(sessionDir: URL) -> KimiState? {
        let stateFile = sessionDir.appendingPathComponent("state.json")
        guard let data = fileSystem.contents(atPath: stateFile.path) else { return nil }
        return try? JSONDecoder().decode(KimiState.self, from: data)
    }

    private func createdAt(from state: KimiState?, wire: [KimiWireLine]) -> Date {
        if let iso = state?.createdAt, let date = DateUtils.parseISO8601(iso) { return date }
        if let ms = wire.first(where: { KimiWireType(rawValue: $0.type) == .metadata })?.created_at {
            return DateUtils.date(fromEpochMillis: ms)
        }
        return Date.distantPast
    }

    private func summary(for entry: KimiIndexEntry) -> SessionSummary {
        let sessionDir = URL(fileURLWithPath: entry.sessionDir)
        let state = readState(sessionDir: sessionDir)
        let wire = readWire(sessionDir: sessionDir)
        let messages = Self.messages(fromWire: wire)
        let userMessages = messages.filter { $0.role == .user }.map(\.content)
        let wireFile = sessionDir.appendingPathComponent("agents/main/wire.jsonl")

        return SessionSummary(
            id: entry.sessionId,
            source: .kimiCode,
            projectPath: state?.workDir ?? entry.workDir,
            createdAt: createdAt(from: state, wire: wire),
            lastMessageAt: messages.last?.timestamp,
            model: Self.model(fromWire: wire),
            messageCount: messages.count,
            lastUserMessage: MessageFilter.lastMeaningful(userMessages),
            byteSize: FileSystemHelper.fileSize(wireFile, fileSystem: fileSystem),
            storagePath: sessionDir.path,
            initialPrompt: MessageFilter.firstMeaningful(userMessages)
        )
    }
}
