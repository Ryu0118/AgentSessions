import Foundation

/// Unified error type for all session readers.
public enum SessionReaderError: Error, LocalizedError {
    case cannotReadFile(String)
    case invalidMetadata(String)

    public var errorDescription: String? {
        switch self {
        case let .cannotReadFile(path):
            return "Cannot read file: \(path)"
        case let .invalidMetadata(detail):
            return "Invalid metadata: \(detail)"
        }
    }
}
