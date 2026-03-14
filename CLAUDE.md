# AgentSessions

Swift library to read and parse conversation sessions from AI coding agents (Claude Code, Codex, Cursor).

## Commands

- Build: `swift build`
- Test: `swift test`

## Architecture

3-layer structure: Public API → Reader implementations → Internal infrastructure.

- Root files — Public API types (`SessionReader` protocol, `UnifiedConversation`, `SessionSummary`, `AgentSource`, `SessionReaderFactory`)
- `Schema/` — Agent-specific JSONL/DB entry schemas (internal implementation detail)
- `Reader/` — Agent-specific `SessionReader` implementations
- `Decoder/` — Agent-specific content decoders (`ClaudeCodeContentDecoder`, `CursorAgentContentDecoder`)
- `Internal/` — File system abstraction, SQLite, JSONL parsing infrastructure

## Code Style

- Swift 6.0 strict concurrency (`Sendable` required)
- Public API types use `public` access level
- Internal helpers may use default (internal) access
- Protocol-based abstraction: all readers conform to `SessionReader`
- Dependency injection via `FileSystemProtocol` and `SQLiteReader` for testability
- String identifiers must go through enum `rawValue`. No direct string comparison
- `DateFormatter` / `ISO8601DateFormatter` must be centralized in `DateUtils`. No local definitions
- No logging dependency — this is a library, callers handle their own logging

## Session Storage Locations

- Claude Code: `~/.claude/projects/<encoded-path>/<session-id>.jsonl`
- Codex: `~/.codex/sessions/<year>/<month>/<day>/rollout-<date>-<uuid>.jsonl`
- Cursor (store.db): `~/.cursor/chats/<md5-hash>/<session-id>/store.db`
- Cursor (transcripts): `~/.cursor/projects/<encoded-workspace>/agent-transcripts/<session-id>.jsonl`

## Testing

- Tests live in `Tests/AgentSessionsTests/`
- I/O is mocked via `FileSystemProtocol` + `MockFileManager`
- SQLite is mocked via `MockSQLiteReader`
- Use real session data structures as reference when adding tests

## Gotchas

- Cursor `store.db` uses protobuf + SHA-256 blob DAG. `meta` table values are hex-encoded JSON
- This library is read-only. Session writing/migration is out of scope
