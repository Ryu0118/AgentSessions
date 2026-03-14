import Foundation

/// Enumerates top-level Claude Code JSONL entry kinds.
public enum ClaudeCodeEntryType: String, Codable, Sendable {
    case user
    case assistant
    case progress
    case system
    case fileHistorySnapshot = "file-history-snapshot"
}

/// Enumerates message roles used inside Claude Code message payloads.
public enum ClaudeCodeMessageRole: String, Codable, Sendable {
    case user
    case assistant
    case system
    case tool
}

/// Top-level entry in a Claude Code JSONL session file.
/// Each line is one of: user message, assistant message, progress, system, file-history-snapshot, etc.
/// - Note: `isSidechain` is true for claude-mem observer sessions (monitoring another session).
public struct ClaudeCodeEntry: Codable, Sendable {
    public let type: String
    public let sessionId: String?
    public let timestamp: String?
    public let uuid: String?
    public let parentUuid: String?
    public let version: String?
    public let cwd: String?
    public let gitBranch: String?
    public let model: String?
    public let message: ClaudeCodeMessage?
    public let isSidechain: Bool?

    public init(
        type: String, sessionId: String? = nil, timestamp: String? = nil,
        uuid: String? = nil, parentUuid: String? = nil, version: String? = nil,
        cwd: String? = nil, gitBranch: String? = nil, model: String? = nil,
        message: ClaudeCodeMessage? = nil, isSidechain: Bool? = nil
    ) {
        self.type = type; self.sessionId = sessionId; self.timestamp = timestamp
        self.uuid = uuid; self.parentUuid = parentUuid; self.version = version
        self.cwd = cwd; self.gitBranch = gitBranch; self.model = model
        self.message = message; self.isSidechain = isSidechain
    }

    public var entryType: ClaudeCodeEntryType? {
        ClaudeCodeEntryType(rawValue: type)
    }
}

/// The `message` field inside a Claude Code JSONL entry.
public struct ClaudeCodeMessage: Codable, Sendable {
    public let role: String?
    public let content: TextOrBlocks?
    public let model: String?
    public let stop_reason: String?
    public let stop_sequence: String?

    public init(
        role: String? = nil, content: TextOrBlocks? = nil,
        model: String? = nil, stop_reason: String? = nil, stop_sequence: String? = nil
    ) {
        self.role = role; self.content = content; self.model = model
        self.stop_reason = stop_reason; self.stop_sequence = stop_sequence
    }

    public var messageRole: ClaudeCodeMessageRole? {
        role.flatMap(ClaudeCodeMessageRole.init(rawValue:))
    }
}
