import Foundation

/// Enumerates top-level Claude Code JSONL entry kinds.
public enum ClaudeCodeEntryType: String, Codable, Sendable {
    case user
    case assistant
    case progress
    case system
    case fileHistorySnapshot = "file-history-snapshot"
    /// Human-readable label used by `claude --resume "<slug>"` when the JSONL stem is a UUID.
    case customTitle = "custom-title"
    case agentName = "agent-name"
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
/// - Note: `sessionId` may appear as `sessionId` or `session_id` in JSON (CLI resume string).
/// - Note: `customTitle` / `agentName` hold the resume slug when the on-disk filename is a UUID.
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
    public let customTitle: String?
    public let agentName: String?

    enum CodingKeys: String, CodingKey {
        case type
        case sessionId
        case session_id
        case timestamp
        case uuid
        case parentUuid
        case version
        case cwd
        case gitBranch
        case model
        case message
        case isSidechain
        case customTitle
        case agentName
    }

    public init(
        type: String, sessionId: String? = nil, timestamp: String? = nil,
        uuid: String? = nil, parentUuid: String? = nil, version: String? = nil,
        cwd: String? = nil, gitBranch: String? = nil, model: String? = nil,
        message: ClaudeCodeMessage? = nil, isSidechain: Bool? = nil,
        customTitle: String? = nil, agentName: String? = nil
    ) {
        self.type = type; self.sessionId = sessionId; self.timestamp = timestamp
        self.uuid = uuid; self.parentUuid = parentUuid; self.version = version
        self.cwd = cwd; self.gitBranch = gitBranch; self.model = model
        self.message = message; self.isSidechain = isSidechain
        self.customTitle = customTitle; self.agentName = agentName
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        type = try c.decode(String.self, forKey: .type)
        if let sid = try c.decodeIfPresent(String.self, forKey: .sessionId) {
            sessionId = sid
        } else {
            sessionId = try c.decodeIfPresent(String.self, forKey: .session_id)
        }
        timestamp = try c.decodeIfPresent(String.self, forKey: .timestamp)
        uuid = try c.decodeIfPresent(String.self, forKey: .uuid)
        parentUuid = try c.decodeIfPresent(String.self, forKey: .parentUuid)
        version = try c.decodeIfPresent(String.self, forKey: .version)
        cwd = try c.decodeIfPresent(String.self, forKey: .cwd)
        gitBranch = try c.decodeIfPresent(String.self, forKey: .gitBranch)
        model = try c.decodeIfPresent(String.self, forKey: .model)
        message = try c.decodeIfPresent(ClaudeCodeMessage.self, forKey: .message)
        isSidechain = try c.decodeIfPresent(Bool.self, forKey: .isSidechain)
        customTitle = try c.decodeIfPresent(String.self, forKey: .customTitle)
        agentName = try c.decodeIfPresent(String.self, forKey: .agentName)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(type, forKey: .type)
        try c.encodeIfPresent(sessionId, forKey: .sessionId)
        try c.encodeIfPresent(timestamp, forKey: .timestamp)
        try c.encodeIfPresent(uuid, forKey: .uuid)
        try c.encodeIfPresent(parentUuid, forKey: .parentUuid)
        try c.encodeIfPresent(version, forKey: .version)
        try c.encodeIfPresent(cwd, forKey: .cwd)
        try c.encodeIfPresent(gitBranch, forKey: .gitBranch)
        try c.encodeIfPresent(model, forKey: .model)
        try c.encodeIfPresent(message, forKey: .message)
        try c.encodeIfPresent(isSidechain, forKey: .isSidechain)
        try c.encodeIfPresent(customTitle, forKey: .customTitle)
        try c.encodeIfPresent(agentName, forKey: .agentName)
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
