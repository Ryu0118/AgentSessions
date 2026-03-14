import Foundation

/// Centralized factory for session readers used across runners.
public enum SessionReaderFactory {
    public static func make(
        fileSystem: any FileSystemProtocol = DefaultFileSystem(),
        sqlite: any SQLiteReader = DefaultSQLiteReader()
    ) -> [SessionReader] {
        [
            ClaudeCodeSessionReader(fileSystem: fileSystem),
            CodexSessionReader(fileSystem: fileSystem),
            CursorSessionReader(fileSystem: fileSystem, sqlite: sqlite),
        ]
    }
}
