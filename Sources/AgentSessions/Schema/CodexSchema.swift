import Foundation

/// Enumerates top-level Codex JSONL entry kinds.
public enum CodexEntryType: String, Codable, Sendable {
    case sessionMeta = "session_meta"
    case eventMsg = "event_msg"
    case responseItem = "response_item"
    case turnContext = "turn_context"
}

/// Enumerates payload kinds that appear in Codex entries.
public enum CodexPayloadType: String, Codable, Sendable {
    case userMessage = "user_message"
    case agentMessage = "agent_message"
    case message
    case taskStarted = "task_started"
    case tokenCount = "token_count"
    case taskComplete = "task_complete"
    case turnAborted = "turn_aborted"
    case reasoning
    case functionCall = "function_call"
    case functionCallOutput = "function_call_output"
    case webSearchCall = "web_search_call"
    case customToolCall = "custom_tool_call"
    case customToolCallOutput = "custom_tool_call_output"
}

/// Enumerates speaker roles that appear in Codex payloads.
public enum CodexPayloadRole: String, Codable, Sendable {
    case user
    case assistant
    case developer
    case system
    case tool
}

/// Enumerates payload phases used for Codex response items.
public enum CodexPayloadPhase: String, Codable, Sendable {
    case finalAnswer = "final_answer"
}

/// Top-level entry in a Codex JSONL session file.
/// First line is session metadata, subsequent lines are events/responses.
public struct CodexEntry: Codable, Sendable {
    public let id: String?
    public let timestamp: String?
    public let type: String?
    public let payload: CodexPayload?
    public let item: CodexLegacyItem?
    public let items: [CodexLegacyItem]?

    public init(
        id: String? = nil, timestamp: String? = nil, type: String? = nil,
        payload: CodexPayload? = nil, item: CodexLegacyItem? = nil, items: [CodexLegacyItem]? = nil
    ) {
        self.id = id; self.timestamp = timestamp; self.type = type
        self.payload = payload; self.item = item; self.items = items
    }

    public var entryType: CodexEntryType? {
        type.flatMap(CodexEntryType.init(rawValue:))
    }
}

/// Payload for `event_msg`, `response_item`, `session_meta`, and `turn_context` entries.
public struct CodexPayload: Codable, Sendable {
    public let type: String?
    public let id: String?
    public let timestamp: String?
    public let cwd: String?
    public let originator: String?
    public let cli_version: String?
    public let source: String?
    public let model_provider: String?
    public let message: String?
    public let role: String?
    public let content: [ContentBlock]?
    public let input_tokens: Int?
    public let output_tokens: Int?
    public let last_agent_message: String?
    public let phase: String?

    public init(
        type: String? = nil, id: String? = nil, timestamp: String? = nil, cwd: String? = nil,
        originator: String? = nil, cli_version: String? = nil, source: String? = nil,
        model_provider: String? = nil,
        message: String? = nil, role: String? = nil, content: [ContentBlock]? = nil,
        input_tokens: Int? = nil, output_tokens: Int? = nil, last_agent_message: String? = nil,
        phase: String? = nil
    ) {
        self.type = type; self.id = id; self.timestamp = timestamp; self.cwd = cwd
        self.originator = originator; self.cli_version = cli_version; self.source = source
        self.model_provider = model_provider
        self.message = message; self.role = role; self.content = content
        self.input_tokens = input_tokens; self.output_tokens = output_tokens
        self.last_agent_message = last_agent_message
        self.phase = phase
    }

    private enum CodingKeys: String, CodingKey {
        case type, id, timestamp, cwd, originator, cli_version, source, model_provider
        case message, role, content, input_tokens, output_tokens, last_agent_message, phase
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        type = try? container.decodeIfPresent(String.self, forKey: .type)
        id = try? container.decodeIfPresent(String.self, forKey: .id)
        timestamp = try? container.decodeIfPresent(String.self, forKey: .timestamp)
        cwd = try? container.decodeIfPresent(String.self, forKey: .cwd)
        originator = try? container.decodeIfPresent(String.self, forKey: .originator)
        cli_version = try? container.decodeIfPresent(String.self, forKey: .cli_version)
        // In real sessions, `source` can be object or string. We only persist string when possible.
        source = try? container.decodeIfPresent(String.self, forKey: .source)
        model_provider = try? container.decodeIfPresent(String.self, forKey: .model_provider)
        message = try? container.decodeIfPresent(String.self, forKey: .message)
        role = try? container.decodeIfPresent(String.self, forKey: .role)
        content = try? container.decodeIfPresent([ContentBlock].self, forKey: .content)
        input_tokens = try? container.decodeIfPresent(Int.self, forKey: .input_tokens)
        output_tokens = try? container.decodeIfPresent(Int.self, forKey: .output_tokens)
        last_agent_message = try? container.decodeIfPresent(String.self, forKey: .last_agent_message)
        phase = try? container.decodeIfPresent(String.self, forKey: .phase)
    }

    public var payloadType: CodexPayloadType? {
        type.flatMap(CodexPayloadType.init(rawValue:))
    }

    public var payloadRole: CodexPayloadRole? {
        role.flatMap(CodexPayloadRole.init(rawValue:))
    }

    public var payloadPhase: CodexPayloadPhase? {
        phase.flatMap(CodexPayloadPhase.init(rawValue:))
    }
}

/// Legacy Codex format: items array containing response objects.
public struct CodexLegacyItem: Codable, Sendable {
    public let type: String?
    public let role: String?
    public let content: [ContentBlock]?

    public init(type: String? = nil, role: String? = nil, content: [ContentBlock]? = nil) {
        self.type = type; self.role = role; self.content = content
    }
}
