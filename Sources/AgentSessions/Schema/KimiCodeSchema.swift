import Foundation

enum KimiWireType: String {
    case metadata
    case configUpdate = "config.update"
    case turnPrompt = "turn.prompt"
    case appendMessage = "context.append_message"
    case appendLoopEvent = "context.append_loop_event"
}

enum KimiOriginKind: String {
    case user
    case injection
    case backgroundTask = "background_task"
    case skillActivation = "skill_activation"
}

enum KimiLoopEventType: String {
    case stepBegin = "step.begin"
    case contentPart = "content.part"
}

enum KimiPartType: String {
    case text
    case think
}

/// One wire.jsonl line; unknown types decode with all fields nil and are ignored.
struct KimiWireLine: Decodable {
    let type: String
    let time: Int?
    let created_at: Int?
    let modelAlias: String?
    let input: [KimiTextPart]?
    let origin: KimiOrigin?
    let event: KimiLoopEvent?
}

struct KimiTextPart: Decodable {
    let type: String
    let text: String?
}

struct KimiOrigin: Decodable {
    let kind: String?
}

struct KimiLoopEvent: Decodable {
    let type: String
    let turnId: String?
    let step: Int?
    let stepUuid: String?
    let uuid: String?
    let part: KimiPart?
}

struct KimiPart: Decodable {
    let type: String
    let text: String?
    let think: String?
}

struct KimiState: Decodable {
    let createdAt: String?
    let updatedAt: String?
    let title: String?
    let workDir: String?
}

struct KimiIndexEntry: Decodable {
    let sessionId: String
    let sessionDir: String
    let workDir: String?
}
