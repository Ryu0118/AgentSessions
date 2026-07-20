@testable import AgentSessions
import Foundation
import Testing

struct KimiCodeSessionReaderTests {
    @Test("KimiWireLine decodes a turn.prompt event")
    func decodeTurnPrompt() throws {
        let line = #"{"type":"turn.prompt","input":[{"type":"text","text":"Hello"}],"origin":{"kind":"user"},"time":1784518241132}"#
        let entry = try #require(JSONLParser.decodeLine(line, as: KimiWireLine.self))
        #expect(entry.type == KimiWireType.turnPrompt.rawValue)
        #expect(entry.origin?.kind == KimiOriginKind.user.rawValue)
        #expect(entry.input?.first?.text == "Hello")
        #expect(entry.time == 1784518241132)
    }

    @Test("KimiWireLine decodes an assistant content.part text loop event")
    func decodeContentPart() throws {
        let line = #"{"type":"context.append_loop_event","event":{"type":"content.part","uuid":"u1","turnId":"0","step":1,"stepUuid":"s1","part":{"type":"text","text":"Answer"}},"time":9}"#
        let entry = try #require(JSONLParser.decodeLine(line, as: KimiWireLine.self))
        #expect(entry.type == KimiWireType.appendLoopEvent.rawValue)
        #expect(entry.event?.type == KimiLoopEventType.contentPart.rawValue)
        #expect(entry.event?.turnId == "0")
        #expect(entry.event?.part?.type == KimiPartType.text.rawValue)
        #expect(entry.event?.part?.text == "Answer")
    }

    @Test("Wire parsing keeps only real user turns and accumulates assistant text between prompts")
    func parseWireMessages() {
        let lines = JSONLParser.decodeLines(TestFixtures.kimiWireJSONL(), as: KimiWireLine.self)
        let messages = KimiCodeSessionReader.messages(fromWire: lines)

        // 2 user turns + 2 assistant turns = 4; the injection/background_task rows are dropped.
        #expect(messages.count == 4)
        #expect(messages[0].role == .user)
        #expect(messages[0].content == "First question")
        #expect(messages[1].role == .assistant)
        // Grouped across two steps; `think` excluded.
        #expect(messages[1].content == "First answer")
        #expect(messages[2].role == .user)
        #expect(messages[2].content == "Second question")
        #expect(messages[3].role == .assistant)
        #expect(messages[3].content == "Second answer")
        // No user message is ever the injected noise or the task-done notification.
        #expect(!messages.contains { $0.role == .user && $0.content.contains("noise") })
        #expect(!messages.contains { $0.role == .user && $0.content == "task done" })
    }

    @Test("Model is read from the config.update modelAlias line")
    func parseWireModel() {
        let lines = JSONLParser.decodeLines(TestFixtures.kimiWireJSONL(), as: KimiWireLine.self)
        #expect(KimiCodeSessionReader.model(fromWire: lines) == "moonshot-ai/kimi-k2.6")
    }

    @Test("A think-only middle turn does not shift assistant pairing onto later prompts")
    func parseWireTextlessMiddleTurn() {
        let wire = """
        {"type":"turn.prompt","input":[{"type":"text","text":"A"}],"origin":{"kind":"user"},"time":1}
        {"type":"context.append_loop_event","event":{"type":"step.begin","uuid":"s0","turnId":"0","step":1},"time":2}
        {"type":"context.append_loop_event","event":{"type":"content.part","uuid":"p0","turnId":"0","step":1,"stepUuid":"s0","part":{"type":"text","text":"reply A"}},"time":3}
        {"type":"turn.prompt","input":[{"type":"text","text":"B"}],"origin":{"kind":"user"},"time":4}
        {"type":"context.append_loop_event","event":{"type":"step.begin","uuid":"s1","turnId":"1","step":1},"time":5}
        {"type":"context.append_loop_event","event":{"type":"content.part","uuid":"p1","turnId":"1","step":1,"stepUuid":"s1","part":{"type":"think","think":"only thinking"}},"time":6}
        {"type":"turn.prompt","input":[{"type":"text","text":"C"}],"origin":{"kind":"user"},"time":7}
        {"type":"context.append_loop_event","event":{"type":"step.begin","uuid":"s2","turnId":"2","step":1},"time":8}
        {"type":"context.append_loop_event","event":{"type":"content.part","uuid":"p2","turnId":"2","step":1,"stepUuid":"s2","part":{"type":"text","text":"reply C"}},"time":9}
        """
        let messages = KimiCodeSessionReader.messages(fromWire: JSONLParser.decodeLines(wire, as: KimiWireLine.self))
        #expect(messages.map(\.role) == [.user, .assistant, .user, .user, .assistant])
        #expect(messages.map(\.content) == ["A", "reply A", "B", "C", "reply C"])
    }

    @Test("Assistant turns without a matching prompt do not shift later turns")
    func parseWireOrphanAndExtraTurns() {
        let wire = """
        {"type":"context.append_loop_event","event":{"type":"content.part","turnId":"9","part":{"type":"text","text":"prior context"}},"time":1}
        {"type":"turn.prompt","input":[{"type":"text","text":"Q1"}],"origin":{"kind":"user"},"time":2}
        {"type":"context.append_loop_event","event":{"type":"content.part","turnId":"0","part":{"type":"text","text":"A1"}},"time":3}
        {"type":"context.append_loop_event","event":{"type":"content.part","turnId":"bg","part":{"type":"text","text":" and more"}},"time":4}
        {"type":"turn.prompt","input":[{"type":"text","text":"Q2"}],"origin":{"kind":"user"},"time":5}
        {"type":"context.append_loop_event","event":{"type":"content.part","turnId":"1","part":{"type":"text","text":"A2"}},"time":6}
        """
        let messages = KimiCodeSessionReader.messages(fromWire: JSONLParser.decodeLines(wire, as: KimiWireLine.self))
        #expect(messages.map(\.role) == [.assistant, .user, .assistant, .user, .assistant])
        #expect(messages.map(\.content) == ["prior context", "Q1", "A1 and more", "Q2", "A2"])
    }

    @Test("loadSession resolves via the index and normalizes the conversation")
    func loadSessionViaIndex() async throws {
        let fs = MockFileManager()
        let home = URL(fileURLWithPath: "/Users/tester")
        fs.homeDirectoryForCurrentUser = home
        let id = TestFixtures.installKimiSession(into: fs, home: home)

        let reader = KimiCodeSessionReader(fileSystem: fs)
        let convo = try #require(try await reader.loadSession(id: id))

        #expect(convo.id == id)
        #expect(convo.source == .kimiCode)
        #expect(convo.projectPath == "/mock/project")
        #expect(convo.model == "moonshot-ai/kimi-k2.6")
        #expect(convo.messages.count == 4)
        #expect(convo.messages.first?.content == "First question")
    }

    @Test("listSessions summarizes each indexed session")
    func listSessionsFromIndex() async throws {
        let fs = MockFileManager()
        let home = URL(fileURLWithPath: "/Users/tester")
        fs.homeDirectoryForCurrentUser = home
        let id = TestFixtures.installKimiSession(into: fs, home: home)

        let reader = KimiCodeSessionReader(fileSystem: fs)
        let summaries = try await reader.listSessions()

        #expect(summaries.count == 1)
        let summary = try #require(summaries.first)
        #expect(summary.id == id)
        #expect(summary.source == .kimiCode)
        #expect(summary.projectPath == "/mock/project")
        #expect(summary.messageCount == 4)
        #expect(summary.initialPrompt == "First question")
        #expect(summary.lastUserMessage == "Second question")
    }

    @Test("Missing index yields no sessions and nil load")
    func emptyStoreIsGraceful() async throws {
        let fs = MockFileManager()
        fs.homeDirectoryForCurrentUser = URL(fileURLWithPath: "/Users/tester")
        let reader = KimiCodeSessionReader(fileSystem: fs)
        #expect(try await reader.listSessions().isEmpty)
        #expect(try await reader.loadSession(id: "session_absent") == nil)
    }

    @Test("loadSession applies limit to the most recent messages")
    func loadSessionLimit() async throws {
        let fs = MockFileManager(); let home = URL(fileURLWithPath: "/Users/tester"); fs.homeDirectoryForCurrentUser = home
        let id = TestFixtures.installKimiSession(into: fs, home: home)
        let convo = try #require(try await KimiCodeSessionReader(fileSystem: fs).loadSession(id: id, limit: 2))
        #expect(convo.messages.count == 2)
        #expect(convo.messages.first?.content == "Second question")
    }

    @Test("loadSession resolves via explicit storagePath and reports createdAt from state.json")
    func loadSessionViaStoragePath() async throws {
        let fs = MockFileManager(); let home = URL(fileURLWithPath: "/Users/tester"); fs.homeDirectoryForCurrentUser = home
        let id = TestFixtures.installKimiSession(into: fs, home: home)
        let reader = KimiCodeSessionReader(fileSystem: fs)
        let storagePath = try #require(try await reader.listSessions().first?.storagePath)
        let convo = try #require(try await reader.loadSession(id: id, storagePath: storagePath))
        #expect(convo.messages.count == 4)
        #expect(convo.projectPath == "/mock/project")
        #expect(convo.createdAt == DateUtils.parseISO8601("2024-03-09T00:00:00.000Z"))
    }

    @Test("loadSession falls back to the index workDir when state.json is absent")
    func loadSessionProjectPathFallback() async throws {
        let fs = MockFileManager(); let home = URL(fileURLWithPath: "/Users/tester"); fs.homeDirectoryForCurrentUser = home
        let id = TestFixtures.installKimiSession(into: fs, home: home, includeState: false)
        let convo = try #require(try await KimiCodeSessionReader(fileSystem: fs).loadSession(id: id))
        #expect(convo.projectPath == "/mock/project")   // from the index entry's workDir, since state.json is absent
        #expect(convo.messages.count == 4)              // wire still parses
    }

    @Test("Summary prompt fields skip system-injected noise prompts")
    func summarySkipsNoisePrompts() async throws {
        let wire = """
        {"type":"turn.prompt","input":[{"type":"text","text":"<user_query>injected</user_query>"}],"origin":{"kind":"user"},"time":1}
        {"type":"turn.prompt","input":[{"type":"text","text":"Real question"}],"origin":{"kind":"user"},"time":2}
        """
        let fs = MockFileManager(); let home = URL(fileURLWithPath: "/Users/tester"); fs.homeDirectoryForCurrentUser = home
        TestFixtures.installKimiSession(into: fs, home: home, wire: wire)
        let summary = try #require(try await KimiCodeSessionReader(fileSystem: fs).listSessions().first)
        #expect(summary.initialPrompt == "Real question")
        #expect(summary.lastUserMessage == "Real question")
    }

    @Test("SessionReaderFactory includes a kimi-code reader")
    func factoryIncludesKimiCode() {
        let readers = SessionReaderFactory.make(fileSystem: MockFileManager(), sqlite: MockSQLiteReader())
        #expect(readers.contains { $0.source == .kimiCode })
    }
}
