import Foundation

/// Identifies the agent that produced or consumes a session.
public enum AgentSource: String, Codable, CaseIterable, Sendable {
    case claudeCode = "claude-code"
    case codex
    case cursor
}
