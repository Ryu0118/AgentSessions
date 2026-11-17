@testable import AgentSessions
import Foundation
import Testing

struct ZCodeSessionReaderTests {
    private struct Fixture {
        let fileSystem = MockFileManager()
        let sqlite = MockSQLiteReader()
        let home = URL(fileURLWithPath: "/Users/tester")
        let sessionID = "sess_11111111-2222-3333-4444-555555555555"
        let dbPath: String

        init() {
            fileSystem.homeDirectoryForCurrentUser = home
            dbPath = home.appendingPathComponent(".zcode/cli/db/db.sqlite").path
            fileSystem.files[dbPath] = Data()

            let created: Int64 = 1_710_000_000_000
            let updated: Int64 = 1_710_000_100_000
            sqlite.queryResultsByContains = [
                (
                    substring: "FROM session",
                    rows: [[
                        "id": sessionID,
                        "directory": "/mock/zcode-project",
                        "title": "ZCode fixture",
                        "time_created": created,
                        "time_updated": updated,
                        "task_type": "interactive",
                        "time_archived": NSNull(),
                    ]]
                ),
                (
                    substring: "FROM message",
                    rows: [
                        [
                            "id": "msg_user_1",
                            "data": #"{"role":"user","time":{"created":1710000000000},"agent":"zcode-agent","model":{}}"#,
                            "sequence": Int64(0),
                            "time_created": created,
                        ],
                        [
                            "id": "msg_assistant_1",
                            "data": #"{"role":"assistant","time":{"created":1710000100000},"modelId":"GLM-5.3-Flash","providerId":"account:zai","agent":"zcode-agent"}"#,
                            "sequence": Int64(1),
                            "time_created": updated,
                        ],
                    ]
                ),
                (
                    substring: "FROM part",
                    rows: [
                        [
                            "message_id": "msg_user_1",
                            "data": #"{"type":"text","text":"Hello from ZCode"}"#,
                            "sequence": Int64(0),
                        ],
                        [
                            "message_id": "msg_assistant_1",
                            "data": #"{"type":"reasoning","text":"thinking"}"#,
                            "sequence": Int64(0),
                        ],
                        [
                            "message_id": "msg_assistant_1",
                            "data": #"{"type":"text","text":"Hi there"}"#,
                            "sequence": Int64(1),
                        ],
                    ]
                ),
            ]
        }

        func reader() -> ZCodeSessionReader {
            ZCodeSessionReader(fileSystem: fileSystem, sqlite: sqlite, databasePath: dbPath)
        }
    }

    @Test("factory includes a ZCode reader")
    func factoryIncludesZCode() throws {
        let readers = SessionReaderFactory.make(fileSystem: MockFileManager(), sqlite: MockSQLiteReader())
        #expect(readers.contains { $0.source == .zcode })
    }

    @Test("lists interactive ZCode sessions from sqlite")
    func listSessions() async throws {
        let fixture = Fixture()
        let summaries = try await fixture.reader().listSessions()
        let summary = try #require(summaries.first)

        #expect(summaries.count == 1)
        #expect(summary.id == fixture.sessionID)
        #expect(summary.source == .zcode)
        #expect(summary.projectPath == "/mock/zcode-project")
        #expect(summary.messageCount == 2)
        #expect(summary.lastUserMessage == "Hello from ZCode")
        #expect(summary.initialPrompt == "Hello from ZCode")
        #expect(summary.model == "GLM-5.3-Flash")
    }

    @Test("loads text parts and skips reasoning")
    func loadSession() async throws {
        let fixture = Fixture()
        let conversation = try #require(try await fixture.reader().loadSession(id: fixture.sessionID))

        #expect(conversation.source == .zcode)
        #expect(conversation.projectPath == "/mock/zcode-project")
        #expect(conversation.model == "GLM-5.3-Flash")
        #expect(conversation.messages.map(\.role) == [.user, .assistant])
        #expect(conversation.messages.map(\.content) == ["Hello from ZCode", "Hi there"])
    }

    @Test("messages helper joins text parts in sequence order")
    func messagesHelper() {
        let assembled = ZCodeSessionReader.messages(
            messageRows: [[
                "id": "msg_1",
                "data": #"{"role":"assistant","modelId":"m"}"#,
                "sequence": Int64(0),
            ]],
            partRows: [
                ["message_id": "msg_1", "data": #"{"type":"text","text":"B"}"#, "sequence": Int64(1)],
                ["message_id": "msg_1", "data": #"{"type":"text","text":"A"}"#, "sequence": Int64(0)],
            ]
        )
        #expect(assembled.messages.map(\.content) == ["AB"])
        #expect(assembled.model == "m")
    }
}
