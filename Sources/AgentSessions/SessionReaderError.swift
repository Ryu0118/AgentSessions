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
            return "'\(tool)' is not installed, so this session cannot be loaded. "
                + "This is a missing dependency, not a corrupt session file. "
                + "Install it and retry: brew install \(tool) (macOS), "
                + "apt-get install \(tool) (Debian/Ubuntu), dnf install \(tool) (Fedora/RHEL). "
                + "Listing sessions still works without it."
        case let .decompressionFailed(tool, detail):
            return "'\(tool)' failed to decompress the session file (\(detail)). "
                + "The file may be corrupt or truncated."
        }
    }
}
