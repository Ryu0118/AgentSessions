import Foundation

/// Decompresses zstd payloads. Abstracted so readers can be tested without the `zstd` binary.
protocol ZstdDecompressing: Sendable {
    func decompress(_ data: Data) throws -> Data
}

/// Default implementation backed by the system `zstd` CLI.
///
/// Uses temp files instead of pipes so large payloads cannot deadlock on a full pipe buffer.
struct SystemZstdDecompressor: ZstdDecompressing {
    static let toolName = "zstd"
    private static let fixedCandidates = ["/opt/homebrew/bin/zstd", "/usr/local/bin/zstd", "/usr/bin/zstd"]

    func decompress(_ data: Data) throws -> Data {
        guard let zstdPath = Self.resolveZstdPath() else {
            throw SessionReaderError.decompressorUnavailable(tool: Self.toolName)
        }

        let fileManager = FileManager.default
        let directory = fileManager.temporaryDirectory
            .appendingPathComponent("agentsessions-zstd-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        defer { try? fileManager.removeItem(at: directory) }

        let inputURL = directory.appendingPathComponent("input")
        let outputURL = directory.appendingPathComponent("output")
        let errorURL = directory.appendingPathComponent("stderr")
        try data.write(to: inputURL)
        guard fileManager.createFile(atPath: errorURL.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
            throw SessionReaderError.cannotReadFile(errorURL.path)
        }
        let errorHandle = try FileHandle(forWritingTo: errorURL)
        defer { try? errorHandle.close() }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: zstdPath)
        process.arguments = ["-q", "-d", "-f", inputURL.path, "-o", outputURL.path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = errorHandle

        do {
            try process.run()
        } catch {
            throw SessionReaderError.decompressionFailed(
                tool: Self.toolName,
                detail: "could not launch \(zstdPath): \(error.localizedDescription)"
            )
        }
        process.waitUntilExit()

        if process.terminationStatus != 0 {
            let stderr = (try? String(contentsOf: errorURL, encoding: .utf8))?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let reason = process.terminationReason == .uncaughtSignal
                ? "terminated by signal \(process.terminationStatus)"
                : "exit status \(process.terminationStatus)"
            let suffix = stderr.isEmpty ? "no stderr output" : "stderr: \(stderr)"
            throw SessionReaderError.decompressionFailed(tool: Self.toolName, detail: "\(reason), \(suffix)")
        }
        return try Data(contentsOf: outputURL)
    }

    /// Scans `PATH` first, then well-known install locations.
    private static func resolveZstdPath() -> String? {
        let pathDirs = (ProcessInfo.processInfo.environment["PATH"] ?? "")
            .split(separator: ":")
            .map { "\($0)/\(toolName)" }
        return (pathDirs + fixedCandidates).first { FileManager.default.isExecutableFile(atPath: $0) }
    }
}
