@testable import AgentSessions
import Foundation
import Testing

struct CopilotCLISessionReaderTests {
    private struct Fixture {
        let fileSystem = MockFileManager()
        let sessionID = "copilot-session-1"
        let home = URL(fileURLWithPath: "/Users/tester")

        var sessionStateDirectory: URL {
            home.appendingPathComponent(".copilot/session-state")
        }

        var sessionDirectory: URL {
            sessionStateDirectory.appendingPathComponent(sessionID)
        }

        var eventsFile: URL {
            sessionDirectory.appendingPathComponent("events.jsonl")
        }

        init() {
            fileSystem.homeDirectoryForCurrentUser = home
            fileSystem.directories[sessionStateDirectory.path] = [sessionDirectory]
            fileSystem.directories[sessionDirectory.path] = []
            fileSystem.files[eventsFile.path] = Data(Self.eventsJSONL.utf8)
            fileSystem.files[sessionDirectory.appendingPathComponent("workspace.yaml").path] = Data(
                "id: copilot-session-1\ncwd: /mock/copilot-project\ngit_root: /mock/copilot-project\n".utf8
            )
        }

        static let eventsJSONL = """
        {"type":"session.start","timestamp":"2025-01-02T03:04:05.000Z","data":{"sessionId":"copilot-session-1","copilotVersion":"1.0.0"}}
        {"type":"user.message","timestamp":"2025-01-02T03:05:00.000Z","data":{"content":"First request"}}
        {"type":"model.messages_snapshot","timestamp":"2025-01-02T03:05:01.000Z","data":{"messages":[{"role":"assistant","content":"snapshot duplicate"}]}}
        {"type":"assistant.message","timestamp":"2025-01-02T03:05:10.000Z","data":{"content":"Inspecting the project.","phase":"commentary","model":"gpt-5.6-terra"}}
        {"type":"assistant.message","timestamp":"2025-01-02T03:05:11.000Z","data":{"content":"","model":"gpt-5.6-terra","toolRequests":[{"toolCallId":"tool-1"}]}}
        {"type":"tool.execution_start","timestamp":"2025-01-02T03:05:12.000Z","data":{"toolCallId":"tool-1","toolName":"shell"}}
        {"type":"tool.execution_complete","timestamp":"2025-01-02T03:05:13.000Z","data":{"toolCallId":"tool-1","result":"not a chat message"}}
        {"type":"assistant.message","timestamp":"2025-01-02T03:05:20.000Z","data":{"content":"The result.","phase":"final_answer","model":"gpt-5.6-terra"}}
        {"type":"user.message","timestamp":"2025-01-02T03:06:00.000Z","data":{"content":"Follow-up request"}}
        {"type":"assistant.message","timestamp":"2025-01-02T03:06:10.000Z","data":{"content":"Second result.","phase":"final_answer","model":"gpt-5.6-terra"}}
        {"type":"session.usage_checkpoint","timestamp":"2025-01-02T03:06:11.000Z","data":{"totalPremiumRequests":3}}
        """

        func reader() throws -> any SessionReader {
            try #require(
                SessionReaderFactory.make(fileSystem: fileSystem)
                    .first { $0.source.rawValue == "copilot-cli" }
            )
        }
    }

    @Test("factory includes a Copilot CLI reader")
    func factoryIncludesCopilotCLI() throws {
        let fixture = Fixture()
        let reader = try fixture.reader()

        #expect(reader.source.rawValue == "copilot-cli")
    }

    @Test("lists Copilot sessions with workspace and conversation summary metadata")
    func listSessions() async throws {
        let fixture = Fixture()
        let reader = try fixture.reader()
        let summaries = try await reader.listSessions()

        let summary = try #require(summaries.first)
        #expect(summaries.count == 1)
        #expect(summary.id == "copilot-session-1")
        #expect(summary.source.rawValue == "copilot-cli")
        #expect(summary.projectPath == "/mock/copilot-project")
        #expect(summary.createdAt == DateUtils.parseISO8601("2025-01-02T03:04:05.000Z"))
        #expect(summary.messageCount == 5)
        #expect(summary.lastUserMessage == "Follow-up request")
        #expect(summary.initialPrompt == "First request")
        #expect(summary.storagePath == fixture.sessionDirectory.path)
        #expect(summary.model == "gpt-5.6-terra")
    }

    @Test("loads ordered chat messages and ignores snapshots, tool events, and empty tool-call messages")
    func loadSession() async throws {
        let fixture = Fixture()
        let reader = try fixture.reader()
        let conversation = try #require(try await reader.loadSession(id: fixture.sessionID))

        #expect(conversation.id == "copilot-session-1")
        #expect(conversation.source.rawValue == "copilot-cli")
        #expect(conversation.projectPath == "/mock/copilot-project")
        #expect(conversation.createdAt == DateUtils.parseISO8601("2025-01-02T03:04:05.000Z"))
        #expect(conversation.model == "gpt-5.6-terra")
        #expect(conversation.messages.map(\.role) == [.user, .assistant, .assistant, .user, .assistant])
        #expect(conversation.messages.map(\.content) == [
            "First request",
            "Inspecting the project.",
            "The result.",
            "Follow-up request",
            "Second result.",
        ])
        #expect(conversation.messages[1].timestamp == DateUtils.parseISO8601("2025-01-02T03:05:10.000Z"))
    }

    @Test("loads a Copilot session by storage path and applies a message limit")
    func loadSessionByStoragePathWithLimit() async throws {
        let fixture = Fixture()
        let reader = try fixture.reader()
        let conversation = try #require(try await reader.loadSession(
            id: fixture.sessionID,
            storagePath: fixture.sessionDirectory.path,
            limit: 2
        ))

        #expect(conversation.messages.map(\.content) == ["Follow-up request", "Second result."])
    }

    @Test(
        "rejects Copilot session IDs that are not safe path components",
        arguments: ["../outside", "..\\outside", "/tmp/outside", "C:outside"]
    )
    func rejectsUnsafeSessionID(_ id: String) async throws {
        let fixture = Fixture()
        let reader = try fixture.reader()
        let escapedDirectory = fixture.sessionStateDirectory.appendingPathComponent(id)
        let escapedEvents = escapedDirectory.appendingPathComponent("events.jsonl")
        fixture.fileSystem.files[escapedEvents.path] = Data(Fixture.eventsJSONL.utf8)

        let conversation = try await reader.loadSession(id: id)

        #expect(conversation == nil)
    }

    @Test("missing Copilot storage returns no sessions and a nil direct load")
    func emptyStoreIsGraceful() async throws {
        let fileSystem = MockFileManager()
        fileSystem.homeDirectoryForCurrentUser = URL(fileURLWithPath: "/Users/tester")
        let reader = try #require(
            SessionReaderFactory.make(fileSystem: fileSystem).first { $0.source.rawValue == "copilot-cli" }
        )

        #expect(try await reader.listSessions().isEmpty)
        #expect(try await reader.loadSession(id: "absent") == nil)
    }
}
