import Foundation

/// Shared file-reading utilities for JSONL-backed session readers.
public struct JSONLFileReader: Sendable {
    private let fileSystem: any FileSystemProtocol

    public init(fileSystem: any FileSystemProtocol) {
        self.fileSystem = fileSystem
    }

    /// Reads and decodes the entire JSONL file.
    public func readAllEntries<Entry: Decodable>(from file: URL, as type: Entry.Type) throws -> [Entry] {
        guard let data = fileSystem.contents(atPath: file.path) else {
            throw SessionReaderError.cannotReadFile(file.path)
        }
        return decodeEntries(from: data, as: type)
    }

    /// Reads the first part of a JSONL file and decodes up to `maxLines` entries.
    public func readHeadEntries<Entry: Decodable>(
        from file: URL,
        as type: Entry.Type,
        maxBytes: Int,
        maxLines: Int? = nil
    ) throws -> [Entry] {
        let data = try FileSystemHelper.readHead(fileSystem: fileSystem, file: file, maxBytes: maxBytes)
        let entries = decodeEntries(from: data, as: type)
        guard let maxLines else {
            return entries
        }
        return Array(entries.prefix(maxLines))
    }

    /// Reads the tail of a JSONL file and decodes all complete entries found there.
    public func readTailEntries<Entry: Decodable>(
        from file: URL,
        as type: Entry.Type,
        maxBytes: Int
    ) throws -> [Entry] {
        let data = try FileSystemHelper.readTail(fileSystem: fileSystem, file: file, maxBytes: maxBytes)
        return decodeTailEntries(from: data, file: file, as: type, maxBytes: maxBytes)
    }

    /// Reads progressively larger chunks from the end of a JSONL file until enough mapped values are found.
    public func readRecentValues<Entry: Decodable, Value>(
        from file: URL,
        as type: Entry.Type,
        initialMaxBytes: Int,
        limit: Int,
        transform: (Entry) -> Value?
    ) throws -> [Value] {
        var maxBytes = initialMaxBytes
        let totalSize = FileSystemHelper.fileSize(file, fileSystem: fileSystem)

        while true {
            let data = try FileSystemHelper.readTail(fileSystem: fileSystem, file: file, maxBytes: maxBytes)
            let entries = decodeTailEntries(from: data, file: file, as: type, maxBytes: maxBytes)
            let values = entries.compactMap(transform)

            let reachedStart = if let totalSize {
                Int64(maxBytes) >= totalSize
            } else {
                data.count < maxBytes
            }

            if values.count >= limit || reachedStart {
                return Array(values.suffix(limit))
            }

            maxBytes *= 2
        }
    }

    /// Exposes decoded tail entries when callers need custom filtering after decoding.
    public func readRecentEntries<Entry: Decodable>(
        from file: URL,
        as type: Entry.Type,
        initialMaxBytes: Int,
        limit: Int
    ) throws -> [Entry] {
        try readRecentValues(from: file, as: type, initialMaxBytes: initialMaxBytes, limit: limit) { $0 }
    }

    private func decodeEntries<Entry: Decodable>(from data: Data, as type: Entry.Type) -> [Entry] {
        JSONLParser.decodeLines(String(decoding: data, as: UTF8.self), as: type)
    }

    private func decodeTailEntries<Entry: Decodable>(
        from data: Data,
        file: URL,
        as type: Entry.Type,
        maxBytes: Int
    ) -> [Entry] {
        var lines = String(decoding: data, as: UTF8.self).components(separatedBy: .newlines)

        // Tail reads may start mid-line. Drop the first fragment unless we reached the beginning.
        if let totalSize = FileSystemHelper.fileSize(file, fileSystem: fileSystem), totalSize > Int64(maxBytes), !lines.isEmpty {
            lines.removeFirst()
        }

        return lines.compactMap { JSONLParser.decodeLine($0, as: type) }
    }
}
