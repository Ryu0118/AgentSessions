@testable import AgentSessions
import Foundation
import Testing

struct DeepSeekHarnessSessionReaderTests {
    private struct Fixture {
        let fileSystem = MockFileManager()
        let home = URL(fileURLWithPath: "/Users/tester")
        let sessionID = "session-aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"
        let projectPath = "/mock/dshproject"
        let sessionFile: URL

        init() throws {
            fileSystem.homeDirectoryForCurrentUser = home
            let encoded = DeepSeekHarnessSessionReader.encodedWorkspaceDirectory(for: projectPath)
            let sessionsRoot = home.appendingPathComponent(".dsh/sessions")
            let workspaceDir = sessionsRoot.appendingPathComponent(encoded)
            let sessionDir = workspaceDir.appendingPathComponent(sessionID)
            sessionFile = sessionDir.appendingPathComponent("session.v4.jsonl.zstd")

            fileSystem.directories[sessionsRoot.path] = [workspaceDir]
            fileSystem.directories[workspaceDir.path] = [sessionDir]
            fileSystem.directories[sessionDir.path] = [sessionFile]

            let jsonl = """
            {"type":"session","version":4,"id":"\(sessionID)","createdAt":1710000000000,"cwd":"\(projectPath)","isSeeded":false,"delegationDepth":0,"agentPreset":"ptc"}
            {"type":"permission/preset","seq":0,"time":1710000000001,"data":{"preset":"workspace-write"}}
            {"type":"user/message","seq":1,"time":1710000001000,"data":{"content":[{"type":"text","text":"First DSH request"}],"source":{"kind":"user"},"role":"user","id":"u1"},"surfaceOp":"append"}
            {"type":"assistant/message","seq":2,"time":1710000002000,"data":{"turn":1,"step":1,"message":{"role":"assistant","content":[{"type":"reasoning","text":"think"},{"type":"text","text":"First DSH reply"}]}}}
            {"type":"user/message","seq":3,"time":1710000003000,"data":{"content":[{"type":"text","text":"Follow-up"}],"role":"user","id":"u2"},"surfaceOp":"append"}
            {"type":"assistant/message","seq":4,"time":1710000004000,"data":{"turn":2,"step":1,"message":{"role":"assistant","content":[{"type":"text","text":"Second reply"}]}}}
            """
            let compressed = try ZstdCodec.compress(Data(jsonl.utf8))
            fileSystem.files[sessionFile.path] = compressed
            fileSystem.fileAttributes[sessionFile.path] = [.size: compressed.count]
        }

        func reader() -> DeepSeekHarnessSessionReader {
            DeepSeekHarnessSessionReader(fileSystem: fileSystem)
        }
    }

    @Test("factory includes a DeepSeek Harness reader")
    func factoryIncludesDeepSeekHarness() {
        let readers = SessionReaderFactory.make(fileSystem: MockFileManager())
        #expect(readers.contains { $0.source == .deepseekHarness })
    }

    @Test("encodes workspace directories like native DSH session folders")
    func encodesWorkspaceDirectory() {
        #expect(
            DeepSeekHarnessSessionReader.encodedWorkspaceDirectory(for: "/Users/mac/project")
                == "--Users-mac-project--"
        )
        #expect(
            DeepSeekHarnessSessionReader.encodedWorkspaceDirectory(for: "/mock/dshproject")
                == "--mock-dshproject--"
        )
    }

    @Test("lists DeepSeek Harness sessions from zstd jsonl")
    func listSessions() async throws {
        let fixture = try Fixture()
        let summaries = try await fixture.reader().listSessions()
        let summary = try #require(summaries.first)

        #expect(summaries.count == 1)
        #expect(summary.id == fixture.sessionID)
        #expect(summary.source == .deepseekHarness)
        #expect(summary.projectPath == fixture.projectPath)
        // List avoids decompressing when projcache is absent; loadSession still reads the log.
        #expect(summary.storagePath == fixture.sessionFile.path)
    }

    @Test("loads text content and skips reasoning blocks")
    func loadSession() async throws {
        let fixture = try Fixture()
        let conversation = try #require(try await fixture.reader().loadSession(id: fixture.sessionID))

        #expect(conversation.id == fixture.sessionID)
        #expect(conversation.source == .deepseekHarness)
        #expect(conversation.projectPath == fixture.projectPath)
        #expect(conversation.messages.map(\.role) == [.user, .assistant, .user, .assistant])
        #expect(conversation.messages.map(\.content) == [
            "First DSH request",
            "First DSH reply",
            "Follow-up",
            "Second reply",
        ])
    }
}
