# AgentSessions

A Swift library to read and parse conversation sessions from AI coding agents.

## Supported Agents

- Claude Code
- Codex
- Cursor

## Usage

```swift
import AgentSessions

// List all sessions across all agents
let readers = SessionReaderFactory.make()
for reader in readers {
    let summaries = try await reader.listSessions()
    for summary in summaries {
        print("\(summary.source.rawValue): \(summary.id) — \(summary.lastUserMessage ?? "")")
    }
}

// Load a specific session
let conversation = try await readers[0].loadSession(id: "session-id")
for message in conversation?.messages ?? [] {
    print("[\(message.role.rawValue)] \(message.decodedContent(for: conversation!.source))")
}
```

## Installation

### Swift Package Manager

```swift
dependencies: [
    .package(url: "https://github.com/Ryu0118/AgentSessions.git", from: "0.1.0"),
]
```

```swift
.target(
    name: "YourTarget",
    dependencies: [
        .product(name: "AgentSessions", package: "AgentSessions"),
    ]
)
```

## Requirements

- Swift 6.0+
- macOS 15+

## License

MIT
