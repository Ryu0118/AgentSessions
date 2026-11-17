import Foundation

/// Unified error type for all session readers.
public enum SessionReaderError: Error, LocalizedError {
    case cannotReadFile(String)
    case invalidMetadata(String)
    /// An external tool required to decode a session file is not installed (the file itself is not corrupt).
    case decompressorUnavailable(tool: String)
    /// An external decompressor ran but failed. `detail` carries exit status/signal and trimmed stderr.
    case decompressionFailed(tool: String, detail: String)

    public var errorDescription: String? {
        switch self {
        case let .cannotReadFile(path):
            return "Cannot read file: \(path)"
        case let .invalidMetadata(detail):
            return "Invalid metadata: \(detail)"
        case let .decompressorUnavailable(tool):
            return """
            Required external tool '\(tool)' was not found on PATH or in standard install locations. \
            This is a missing tool dependency, not a corrupt session file. \
            Install it and retry: macOS: `brew install \(tool)`; \
            Debian/Ubuntu: `apt-get install \(tool)`; Fedora/RHEL: `dnf install \(tool)`. \
            The session itself is fine, and listing sessions still works without '\(tool)'; \
            only loading this session's content requires it.
            """
        case let .decompressionFailed(tool, detail):
            return "External tool '\(tool)' failed to decompress the session file: \(detail). "
                + "If this is unexpected, the session file may be corrupt or truncated."
        }
    }
}
