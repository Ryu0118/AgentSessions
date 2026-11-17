@testable import AgentSessions
import Foundation
import Testing

/// Returns canned plain bytes regardless of input, so tests never need the `zstd` binary.
private struct StubDecompressor: ZstdDecompressing {
    let result: Result<Data, SessionReaderError>

    func decompress(_ data: Data) throws -> Data {
        try result.get()
    }
}

struct DeepSeekHarnessSessionReaderTests {
    private struct Fixture {
        let fileSystem = MockFileManager()
        let home = URL(fileURLWithPath: "/Users/tester")
        let sessionID = "session-aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"
        let projectPath = "/mock/dshproject"
        let sessionFile: URL
        let decompressor: StubDecompressor

        /// - Parameter decompressorFailure: when set, the stub decompressor fails with this error.
        init(decompressorFailure: SessionReaderError? = nil) throws {
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
            decompressor = StubDecompressor(
                result: decompressorFailure.map { .failure($0) } ?? .success(Data(jsonl.utf8))
            )
            // Placeholder bytes: the stub decompressor ignores them.
            let compressed = Data("zstd-placeholder".utf8)
            fileSystem.files[sessionFile.path] = compressed
            fileSystem.fileAttributes[sessionFile.path] = [.size: compressed.count]
        }

        func reader() -> DeepSeekHarnessSessionReader {
            DeepSeekHarnessSessionReader(
                fileSystem: fileSystem,
                baseDir: nil,
                decompressor: decompressor
            )
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

    @Test("missing zstd surfaces an actionable decompressorUnavailable error")
    func missingDecompressor() async throws {
        let fixture = try Fixture(decompressorFailure: .decompressorUnavailable(tool: "zstd"))
        do {
            _ = try await fixture.reader().loadSession(id: fixture.sessionID)
            Issue.record("expected decompressorUnavailable")
        } catch let error as SessionReaderError {
            guard case .decompressorUnavailable(let tool) = error else {
                Issue.record("wrong case: \(error)")
                return
            }
            #expect(tool == "zstd")
            let message = try #require(error.errorDescription)
            #expect(message.contains("brew install zstd"))
            #expect(message.contains("apt-get install zstd"))
            #expect(message.contains("dnf install zstd"))
            #expect(message.contains("not a corrupt session file"))
            #expect(message.contains("Listing sessions still works"))
        }
    }

    @Test("decompression failure includes exit status and stderr")
    func decompressionFailureMessage() async throws {
        let failure = SessionReaderError.decompressionFailed(
            tool: "zstd",
            detail: "exit status 1, stderr: unknown header"
        )
        let fixture = try Fixture(decompressorFailure: failure)
        do {
            _ = try await fixture.reader().loadSession(id: fixture.sessionID)
            Issue.record("expected decompressionFailed")
        } catch let error as SessionReaderError {
            guard case .decompressionFailed = error else {
                Issue.record("wrong case: \(error)")
                return
            }
            let message = try #require(error.errorDescription)
            #expect(message.contains("exit status 1"))
            #expect(message.contains("unknown header"))
        }
    }

    @Test("listing never invokes the decompressor")
    func listDoesNotDecompress() async throws {
        let fixture = try Fixture(decompressorFailure: .decompressorUnavailable(tool: "zstd"))
        let summaries = try await fixture.reader().listSessions()
        #expect(summaries.count == 1)
    }
}
