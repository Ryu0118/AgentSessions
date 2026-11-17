import Foundation

/// Finds the system `zstd` executable.
///
/// Scans `PATH` first, then well-known install locations. GUI apps and sandboxed launches often
/// have a minimal `PATH` that lacks Homebrew, so the fixed candidates are needed as a fallback.
enum ZstdExecutableLocator {
    static let toolName = "zstd"

    private static let fixedCandidates = [
        "/opt/homebrew/bin/zstd",
        "/usr/local/bin/zstd",
        "/usr/bin/zstd",
    ]

    static func locate() -> String? {
        let pathDirectories = (ProcessInfo.processInfo.environment["PATH"] ?? "")
            .split(separator: ":")
            .map(String.init)
        let candidates = pathDirectories.map { "\($0)/\(toolName)" } + fixedCandidates
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }
}
