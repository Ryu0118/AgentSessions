import Foundation

/// Decompresses zstd payloads. Abstracted so readers can be tested without the `zstd` binary.
protocol ZstdDecompressing: Sendable {
    func decompress(_ data: Data) throws -> Data
}
