import Foundation

/// Default implementation backed by the system `zstd` CLI.
///
/// Uses files instead of pipes for input, output and stderr, so large payloads cannot
/// deadlock on a full pipe buffer while the process is still running.
struct SystemZstdDecompressor: ZstdDecompressing {
    func decompress(_ data: Data) throws -> Data {
        guard let zstdPath = ZstdExecutableLocator.locate() else {
            throw SessionReaderError.decompressorUnavailable(tool: ZstdExecutableLocator.toolName)
        }
        return try Self.withTemporaryDirectory { directory in
            let inputURL = directory.appendingPathComponent("input")
            let outputURL = directory.appendingPathComponent("output")
            let stderrURL = directory.appendingPathComponent("stderr")
            try data.write(to: inputURL)
            try Self.runZstd(at: zstdPath, input: inputURL, output: outputURL, stderr: stderrURL)
            return try Data(contentsOf: outputURL)
        }
    }

    /// Creates a private (0o700) scratch directory and removes it after `body` returns.
    private static func withTemporaryDirectory<T>(_ body: (URL) throws -> T) throws -> T {
        let fileManager = FileManager.default
        let directory = fileManager.temporaryDirectory
            .appendingPathComponent("agentsessions-zstd-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        defer { try? fileManager.removeItem(at: directory) }
        return try body(directory)
    }

    private static func runZstd(at path: String, input: URL, output: URL, stderr: URL) throws {
        let toolName = ZstdExecutableLocator.toolName
        guard FileManager.default.createFile(
            atPath: stderr.path,
            contents: nil,
            attributes: [.posixPermissions: 0o600]
        ) else {
            throw SessionReaderError.cannotReadFile(stderr.path)
        }
        let stderrHandle = try FileHandle(forWritingTo: stderr)
        defer { try? stderrHandle.close() }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = ["-q", "-d", "-f", input.path, "-o", output.path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = stderrHandle

        do {
            try process.run()
        } catch {
            throw SessionReaderError.decompressionFailed(
                tool: toolName,
                detail: "could not launch \(path): \(error.localizedDescription)"
            )
        }
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            throw SessionReaderError.decompressionFailed(
                tool: toolName,
                detail: describeFailure(of: process, stderr: stderr)
            )
        }
    }

    private static func describeFailure(of process: Process, stderr: URL) -> String {
        let status = process.terminationReason == .uncaughtSignal
            ? "terminated by signal \(process.terminationStatus)"
            : "exit status \(process.terminationStatus)"
        let message = (try? String(contentsOf: stderr, encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return message.isEmpty ? "\(status), no stderr output" : "\(status), stderr: \(message)"
    }
}
