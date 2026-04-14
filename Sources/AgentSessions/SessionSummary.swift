import Foundation

/// Describes a session without loading its full message history.
public struct SessionSummary: Sendable {
    public let id: String
    public let source: AgentSource
    public let projectPath: String?
    public let createdAt: Date
    /// Timestamp of the last message in the session. Used for sorting by recent activity.
    public let lastMessageAt: Date?
    public let model: String?
    public let messageCount: Int
    public let lastUserMessage: String?
    public let byteSize: Int64?
    /// True when this is a claude-mem observer session (monitoring another session).
    public let isObserverSession: Bool
    /// Optional path to the agent's backing storage for direct loading when ID lookup fails.
    public let storagePath: String?
    /// The first user message in the session. Useful for matching sessions by their opening prompt.
    public let initialPrompt: String?

    public init(
        id: String,
        source: AgentSource,
        projectPath: String?,
        createdAt: Date,
        lastMessageAt: Date? = nil,
        model: String?,
        messageCount: Int,
        lastUserMessage: String?,
        byteSize: Int64? = nil,
        isObserverSession: Bool = false,
        storagePath: String? = nil,
        initialPrompt: String? = nil
    ) {
        self.id = id
        self.source = source
        self.projectPath = projectPath
        self.createdAt = createdAt
        self.lastMessageAt = lastMessageAt
        self.model = model
        self.messageCount = messageCount
        self.lastUserMessage = lastUserMessage
        self.byteSize = byteSize
        self.isObserverSession = isObserverSession
        self.storagePath = storagePath
        self.initialPrompt = initialPrompt
    }
}

public extension Int64 {
    /// Returns a human-readable byte count such as `512 B` or `1.2 MB`.
    func formattedByteCount() -> String {
        let units = ["B", "KB", "MB", "GB", "TB"]
        var value = Double(self)
        var unitIndex = 0

        while value >= 1024, unitIndex < units.count - 1 {
            value /= 1024
            unitIndex += 1
        }

        let number: String
        if unitIndex == 0 || value >= 10 {
            number = "\(Int(value.rounded()))"
        } else {
            number = String(format: "%.1f", value)
        }

        return "\(number) \(units[unitIndex])"
    }
}
