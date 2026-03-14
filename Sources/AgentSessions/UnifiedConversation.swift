import Foundation

/// Describes the speaker for a unified message.
public enum MessageRole: String, Codable, Sendable {
    case user
    case assistant
    case system
    case tool
}

/// A normalized chat message shared across agent-specific schemas.
public struct UnifiedMessage: Codable, Sendable, Equatable {
    public let role: MessageRole
    public let content: String
    public let timestamp: Date?

    public init(role: MessageRole, content: String, timestamp: Date?) {
        self.role = role
        self.content = content
        self.timestamp = timestamp
    }
}

/// A normalized conversation that can be listed, shown, or migrated.
public struct UnifiedConversation: Codable, Sendable {
    public let id: String
    public let source: AgentSource
    public let projectPath: String?
    public let createdAt: Date
    public let model: String?
    public let messages: [UnifiedMessage]
    /// True when this is a claude-mem observer session (monitoring another session).
    public let isObserverSession: Bool

    public init(
        id: String,
        source: AgentSource,
        projectPath: String?,
        createdAt: Date,
        model: String?,
        messages: [UnifiedMessage],
        isObserverSession: Bool = false
    ) {
        self.id = id
        self.source = source
        self.projectPath = projectPath
        self.createdAt = createdAt
        self.model = model
        self.messages = messages
        self.isObserverSession = isObserverSession
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        source = try container.decode(AgentSource.self, forKey: .source)
        projectPath = try container.decodeIfPresent(String.self, forKey: .projectPath)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        model = try container.decodeIfPresent(String.self, forKey: .model)
        messages = try container.decode([UnifiedMessage].self, forKey: .messages)
        isObserverSession = try container.decodeIfPresent(Bool.self, forKey: .isObserverSession) ?? false
    }

    private enum CodingKeys: String, CodingKey {
        case id, source, projectPath, createdAt, model, messages, isObserverSession
    }
}

extension UnifiedMessage {
    /// Returns the content decoded for the originating agent format.
    public func decodedContent(for source: AgentSource) -> String {
        switch source {
        case .claudeCode:
            return ClaudeCodeContentDecoder.decode(content)
        case .cursor:
            return CursorAgentContentDecoder.decode(content)
        case .codex:
            return content
        }
    }
}

extension String {
    /// Returns `self` truncated to `maxLength`, appending `...` when needed.
    public func truncated(to maxLength: Int) -> String {
        guard count > maxLength else { return self }
        return String(prefix(maxLength - 3)) + "..."
    }

    /// Returns a path shortened in the middle while preserving the leading root and final component.
    public func pathTruncated(to maxLength: Int) -> String {
        guard count > maxLength else { return self }
        let parts = split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        guard parts.count > 2 else { return truncated(to: maxLength) }

        let ellipsis = "..."
        let trailing = parts.suffix(1).joined(separator: "/")

        // Try progressively fewer leading components
        for headComponentCount in stride(from: parts.count - 1, through: 1, by: -1) {
            let head = parts.prefix(headComponentCount).joined(separator: "/")
            let candidate = "/" + head + "/" + ellipsis + "/" + trailing
            if candidate.count <= maxLength {
                return candidate
            }
        }

        // Fallback: just ellipsis + trailing
        let minimal = ellipsis + "/" + trailing
        if minimal.count <= maxLength {
            return minimal
        }
        return truncated(to: maxLength)
    }
}
