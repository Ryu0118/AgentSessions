@testable import AgentSessions
import Foundation

/// In-memory file system mock conforming to FileSystemProtocol.
/// Stores files as Data keyed by path, directories as [URL] keyed by path.
final class MockFileManager: FileSystemProtocol, @unchecked Sendable {
    var homeDirectoryForCurrentUser: URL = FileManager.default.homeDirectoryForCurrentUser
    var files: [String: Data] = [:]
    var directories: [String: [URL]] = [:]
    var fileAttributes: [String: [FileAttributeKey: Any]] = [:]

    func contentsOfDirectory(atPath path: String) throws -> [String] {
        guard let entries = directories[path] else { throw mockError("No dir: \(path)") }
        return entries.map(\.lastPathComponent)
    }

    func contentsOfDirectory(
        at url: URL,
        includingPropertiesForKeys _: [URLResourceKey]?,
        options _: FileManager.DirectoryEnumerationOptions
    ) throws -> [URL] {
        guard let entries = directories[url.path] else { throw mockError("No dir: \(url.path)") }
        return entries
    }

    func createDirectory(at url: URL, withIntermediateDirectories _: Bool, attributes _: [FileAttributeKey: Any]?) throws {
        directories[url.path] = directories[url.path] ?? []
    }

    @discardableResult
    func createFile(atPath path: String, contents data: Data?, attributes _: [FileAttributeKey: Any]?) -> Bool {
        files[path] = data ?? Data()
        return true
    }

    func contents(atPath path: String) -> Data? { files[path] }
    func fileExists(atPath path: String) -> Bool { files[path] != nil || directories[path] != nil }
    func fileExists(atPath path: String, isDirectory: UnsafeMutablePointer<ObjCBool>?) -> Bool {
        if directories[path] != nil { isDirectory?.pointee = true; return true }
        if files[path] != nil { isDirectory?.pointee = false; return true }
        return false
    }

    func attributesOfItem(atPath path: String) throws -> [FileAttributeKey: Any] {
        if let attrs = fileAttributes[path] {
            return attrs
        }
        if let data = files[path] {
            return [.size: data.count]
        }
        throw mockError("No attributes: \(path)")
    }

    private func mockError(_ msg: String) -> NSError {
        NSError(domain: "MockFS", code: 1, userInfo: [NSLocalizedDescriptionKey: msg])
    }
}

/// In-memory SQLite stub that lets tests control full and recent blob queries independently.
final class MockSQLiteReader: SQLiteReader, @unchecked Sendable {
    var queryResults: [[String: Any]] = []
    var blobResults: [(id: String, data: Data)] = []
    var recentBlobResults: [(id: String, data: Data)]?
    var lastRecentBlobLimit: Int?

    func query(dbPath _: String, sql _: String) throws -> [[String: Any]] { queryResults }
    func queryBlobs(dbPath _: String) throws -> [(id: String, data: Data)] { blobResults }
    func queryRecentBlobs(dbPath _: String, limit: Int) throws -> [(id: String, data: Data)] {
        lastRecentBlobLimit = limit
        return recentBlobResults ?? Array(blobResults.suffix(limit))
    }
}

/// Shared fixtures used across reader and decoder tests.
enum TestFixtures {
    static let sampleDate = Date(timeIntervalSince1970: 1_710_000_000) // 2024-03-09

    /// Escapes a string so it can be embedded inside inline JSON test fixtures.
    static func escapedJSONString(_ text: String) -> String {
        text
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
    }

    /// Produces a normalized conversation with stable timestamps and a default project path.
    static func makeConversation(
        id: String = "test-session",
        source: AgentSource = .claudeCode,
        projectPath: String? = "/test/project",
        messages: [UnifiedMessage]? = nil
    ) -> UnifiedConversation {
        UnifiedConversation(
            id: id,
            source: source,
            projectPath: projectPath,
            createdAt: sampleDate,
            model: "test-model",
            messages: messages ?? [
                UnifiedMessage(role: .user, content: "Hello", timestamp: sampleDate),
                UnifiedMessage(role: .assistant, content: "Hi there!", timestamp: sampleDate),
            ]
        )
    }

    // Claude Code JSONL lines
    static func claudeCodeJSONL(timestamp: String = "2024-03-09T00:00:00.000Z") -> String {
        """
        {"type":"user","message":{"role":"user","content":"Hello world"},"timestamp":"\(timestamp)","version":"1"}
        {"type":"progress","data":"thinking..."}
        {"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"Hi! How can I help?"}]},"model":"claude-3","timestamp":"\(timestamp)"}
        {"type":"file-history-snapshot","data":{}}
        {"type":"user","message":{"role":"user","content":"Thanks"},"timestamp":"\(timestamp)"}
        {"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"You're welcome!"},{"type":"tool_use","name":"bash"}]},"model":"claude-3","timestamp":"\(timestamp)"}
        """
    }

    /// JSONL where the on-disk filename is a UUID but `sessionId` in the file is the CLI resume string (slug).
    static func claudeCodeJSONLWithResumeSlug(
        fileUUID: String = "550e8400-e29b-41d4-a716-446655440000",
        resumeSlug: String = "memorinia-mcp-apps-rollout",
        timestamp: String = "2024-03-09T00:00:00.000Z"
    ) -> String {
        """
        {"type":"progress","sessionId":"\(resumeSlug)","timestamp":"\(timestamp)"}
        {"type":"user","message":{"role":"user","content":"Hello world"},"timestamp":"\(timestamp)","version":"1"}
        {"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"Hi! How can I help?"}]},"model":"claude-3","timestamp":"\(timestamp)"}
        """
    }

    // Codex JSONL lines
    static func codexJSONL(sessionId: String = "codex-session-1", timestamp: String = "2024-03-09T00:00:00.000Z") -> String {
        """
        {"type":"session_meta","timestamp":"\(timestamp)","payload":{"id":"\(sessionId)","timestamp":"\(timestamp)","cwd":"/mock/project","cli_version":"0.0.0"}}
        {"type":"event_msg","payload":{"type":"user_message","message":"Build a function"},"timestamp":"\(timestamp)"}
        {"type":"response_item","payload":{"type":"message","role":"assistant","content":[{"type":"output_text","text":"Sure, here is the function."}]},"timestamp":"\(timestamp)"}
        {"type":"event_msg","payload":{"type":"user_message","message":"Add tests"},"timestamp":"\(timestamp)"}
        {"type":"response_item","payload":{"type":"message","role":"assistant","content":[{"type":"output_text","text":"Done! Tests added."}]},"timestamp":"\(timestamp)"}
        """
    }

    /// Codex JSONL where user turns are recorded as `response_item(role=user)` with `input_text`
    /// blocks — the real rollout shape, which has no `event_msg(user_message)` counterpart.
    static func codexJSONLResponseItemUsers(
        sessionId: String = "codex-response-user",
        timestamp: String = "2024-03-09T00:00:00.000Z"
    ) -> String {
        """
        {"type":"session_meta","timestamp":"\(timestamp)","payload":{"id":"\(sessionId)","timestamp":"\(timestamp)","cwd":"/mock/project","cli_version":"0.0.0"}}
        {"type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"Build a function"}]},"timestamp":"\(timestamp)"}
        {"type":"response_item","payload":{"type":"message","role":"assistant","content":[{"type":"output_text","text":"Sure, here is the function."}]},"timestamp":"\(timestamp)"}
        {"type":"response_item","payload":{"type":"message","role":"developer","content":[{"type":"input_text","text":"injected context"}]},"timestamp":"\(timestamp)"}
        {"type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"Add tests"}]},"timestamp":"\(timestamp)"}
        """
    }

    /// Codex JSONL where first user message is system noise; second is real.
    static func codexJSONLWithNoiseFirst(sessionId: String = "noise-session", timestamp: String = "2024-03-09T00:00:00.000Z") -> String {
        """
        {"type":"session_meta","timestamp":"\(timestamp)","payload":{"id":"\(sessionId)","timestamp":"\(timestamp)","cwd":"/mock/project","cli_version":"0.0.0"}}
        {"type":"event_msg","payload":{"type":"user_message","message":"[Local command output — do not respond unless explicitly asked]"},"timestamp":"\(timestamp)"}
        {"type":"response_item","payload":{"type":"message","role":"assistant","content":[{"type":"output_text","text":"Output"}]},"timestamp":"\(timestamp)"}
        {"type":"event_msg","payload":{"type":"user_message","message":"Fix the bug"},"timestamp":"\(timestamp)"}
        {"type":"response_item","payload":{"type":"message","role":"assistant","content":[{"type":"output_text","text":"Fixed."}]},"timestamp":"\(timestamp)"}
        """
    }

    /// Codex JSONL where session_meta appears after the first line.
    static func codexJSONLWithDelayedSessionMeta(
        sessionId: String = "delayed-session",
        timestamp: String = "2024-03-09T00:00:00.000Z"
    ) -> String {
        """
        {"type":"event_msg","payload":{"type":"user_message","message":"Bootstrapping context"},"timestamp":"\(timestamp)"}
        {"type":"session_meta","timestamp":"\(timestamp)","payload":{"id":"\(sessionId)","timestamp":"\(timestamp)","cwd":"/mock/project","cli_version":"0.0.0"}}
        {"type":"event_msg","payload":{"type":"user_message","message":"Build a function"},"timestamp":"\(timestamp)"}
        {"type":"response_item","payload":{"type":"message","role":"assistant","content":[{"type":"output_text","text":"Sure, here is the function."}]},"timestamp":"\(timestamp)"}
        """
    }

    /// Transcript fixtures wrap user messages in `<user_query>` so they match Cursor's real transcript format.
    static func cursorTranscriptJSONL(timestamp: String = "2024-03-09T00:00:00.000Z") -> String {
        let wrappedUserQuery = escapedJSONString(CursorAgentTag.userQuery.wrap("Hello from transcript"))
        return """
        {"role":"user","timestamp":"\(timestamp)","message":{"content":[{"type":"text","text":"\(wrappedUserQuery)"}]}}
        {"role":"assistant","timestamp":"\(timestamp)","message":{"content":[{"type":"text","text":"Hi from transcript"}]}}
        """
    }

    /// Builds a transcript containing tool paths/commands so project-path resolvers can infer the workspace.
    static func cursorTranscriptJSONLWithProjectHints(
        projectPath: String,
        filePath: String,
        preludePath: String? = nil,
        timestamp: String = "2024-03-09T00:00:00.000Z"
    ) -> String {
        let wrappedUserQuery = escapedJSONString(CursorAgentTag.userQuery.wrap("Hello from transcript"))
        let prelude: String? = if let preludePath {
            #"{"role":"assistant","timestamp":"\#(timestamp)","message":{"content":[{"type":"text","text":"Loading helper instructions"},{"type":"tool_use","name":"ReadFile","input":{"path":"\#(preludePath)"}}]}}"#
        } else {
            nil
        }

        let lines = [
            prelude,
            #"{"role":"user","timestamp":"\#(timestamp)","message":{"content":[{"type":"text","text":"\#(wrappedUserQuery)"}]}}"#,
            #"{"role":"assistant","timestamp":"\#(timestamp)","message":{"content":[{"type":"text","text":"Inspecting project files"},{"type":"tool_use","name":"ReadFile","input":{"path":"\#(filePath)"}},{"type":"tool_use","name":"Shell","input":{"command":"pnpm test","working_directory":"\#(projectPath)"}}]}}"#,
            #"{"role":"assistant","timestamp":"\#(timestamp)","message":{"content":[{"type":"text","text":"Hi from transcript"}]}}"#,
        ].compactMap { $0 }

        return lines.joined(separator: "\n")
    }

    /// kimi-code wire.jsonl: two real user turns plus injected noise and a multi-part assistant turn.
    /// All `append_message` lines are skipped by the reader, so the `background_task`/`injection`
    /// user-role ones must NOT surface as user messages.
    static func kimiWireJSONL() -> String {
        """
        {"type":"metadata","protocol_version":"1.4","created_at":1784512258248}
        {"type":"config.update","modelAlias":"moonshot-ai/kimi-k2.6","thinkingEffort":"on","time":1784512276984}
        {"type":"turn.prompt","input":[{"type":"text","text":"First question"}],"origin":{"kind":"user"},"time":1784518241132}
        {"type":"context.append_message","message":{"role":"user","content":[{"type":"text","text":"First question"}],"toolCalls":[],"origin":{"kind":"user"}},"time":1784518241132}
        {"type":"context.append_loop_event","event":{"type":"step.begin","uuid":"a1","turnId":"0","step":1},"time":1784518241133}
        {"type":"context.append_loop_event","event":{"type":"content.part","uuid":"a2","turnId":"0","step":1,"stepUuid":"a1","part":{"type":"think","think":"internal"}},"time":1784518241134}
        {"type":"context.append_loop_event","event":{"type":"content.part","uuid":"a3","turnId":"0","step":1,"stepUuid":"a1","part":{"type":"text","text":"First "}},"time":1784518241135}
        {"type":"context.append_loop_event","event":{"type":"step.begin","uuid":"a4","turnId":"0","step":2},"time":1784518241136}
        {"type":"context.append_loop_event","event":{"type":"content.part","uuid":"a5","turnId":"0","step":2,"stepUuid":"a4","part":{"type":"text","text":"answer"}},"time":1784518241137}
        {"type":"context.append_message","message":{"role":"user","content":[{"type":"text","text":"<system-reminder>noise</system-reminder>"}],"toolCalls":[],"origin":{"kind":"injection"}},"time":1784518241138}
        {"type":"context.append_message","message":{"role":"user","content":[{"type":"text","text":"task done"}],"toolCalls":[],"origin":{"kind":"background_task"}},"time":1784518241139}
        {"type":"turn.prompt","input":[{"type":"text","text":"Second question"}],"origin":{"kind":"user"},"time":1784518241140}
        {"type":"context.append_loop_event","event":{"type":"content.part","uuid":"b1","turnId":"1","step":1,"stepUuid":"b0","part":{"type":"text","text":"Second answer"}},"time":1784518241141}
        """
    }

    /// Populates a MockFileManager with one kimi session (index line, state.json, wire.jsonl)
    /// under a fake ~/.kimi-code and returns the session id.
    @discardableResult
    static func installKimiSession(
        into fs: MockFileManager,
        home: URL,
        sessionId: String = "session_11111111-2222-3333-4444-555555555555",
        workspaceDir: String = "wd_project_abcdef012345",
        workDir: String = "/mock/project",
        createdAt: String = "2024-03-09T00:00:00.000Z",
        title: String = "Migrated session",
        includeState: Bool = true,
        wire: String = kimiWireJSONL()
    ) -> String {
        let kimi = home.appendingPathComponent(".kimi-code")
        let sessionsDir = kimi.appendingPathComponent("sessions")
        let sessionDir = sessionsDir
            .appendingPathComponent(workspaceDir)
            .appendingPathComponent(sessionId)
        let mainDir = sessionDir.appendingPathComponent("agents/main")

        // Directory graph the reader walks.
        fs.directories[kimi.path] = [kimi.appendingPathComponent("session_index.jsonl")]
        fs.directories[sessionsDir.path] = [sessionDir.deletingLastPathComponent()]

        // Index (authoritative discovery).
        let indexLine = #"{"sessionId":"\#(sessionId)","sessionDir":"\#(sessionDir.path)","workDir":"\#(workDir)"}"#
        fs.files[kimi.appendingPathComponent("session_index.jsonl").path] = Data(indexLine.utf8)

        // state.json
        if includeState {
            let state = #"{"createdAt":"\#(createdAt)","updatedAt":"\#(createdAt)","title":"\#(title)","workDir":"\#(workDir)"}"#
            fs.files[sessionDir.appendingPathComponent("state.json").path] = Data(state.utf8)
        }

        // wire.jsonl
        fs.files[mainDir.appendingPathComponent("wire.jsonl").path] = Data(wire.utf8)
        return sessionId
    }
}
