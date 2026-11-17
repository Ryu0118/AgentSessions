import Foundation

/// Default implementation backed by the system `zstd` CLI.
///
/// File bookkeeping goes through `FileSystemProtocol` so it can be mocked. The `zstd` process
/// itself must read and write real files, so it cannot be mocked here; it is the integration
/// boundary and is covered by the reader tests through `ZstdDecompressing` stubs instead.
/// Files are used instead of pipes for input, output and stderr, so large payloads cannot
/// deadlock on a full pipe buffer while the process is still running.
struct SystemZstdDecompressor: ZstdDecompressing {
    private let fileSystem: any FileSystemProtocol

    init(fileSystem: any FileSystemProtocol = DefaultFileSystem()) {
        self.fileSystem = fileSystem
    }

    func decompress(_ data: Data) throws -> Data {
        guard let zstdPath = ZstdExecutableLocator.locate(in: fileSystem) else {
            throw SessionReaderError.decompressorUnavailable(tool: ZstdExecutableLocator.toolName)
        }
        return try withTemporaryDirectory { directory in
            let inputPath = directory.appendingPathComponent("input").path
            let outputPath = directory.appendingPathComponent("output").path
            let stderrPath = directory.appendingPathComponent("stderr").path
            try writeFile(atPath: inputPath, contents: data)
            try runZstd(at: zstdPath, inputPath: inputPath, outputPath: outputPath, stderrPath: stderrPath)
            guard let output = fileSystem.contents(atPath: outputPath) else {
                throw SessionReaderError.cannotReadFile(outputPath)
            }
            return output
        }
    }

    /// Creates a private (0o700) scratch directory and removes it after `body` returns.
    private func withTemporaryDirectory<T>(_ body: (URL) throws -> T) throws -> T {
        let directory = fileSystem.temporaryDirectory
            .appendingPathComponent("agentsessions-zstd-\(UUID().uuidString)", isDirectory: true)
        try fileSystem.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        defer { try? fileSystem.removeItem(at: directory) }
        return try body(directory)
    }

    private func writeFile(atPath path: String, contents: Data, permissions: Int = 0o600) throws {
        guard fileSystem.createFile(atPath: path, contents: contents, attributes: [.posixPermissions: permissions]) else {
            throw SessionReaderError.cannotReadFile(path)
        }
    }

    private func runZstd(at zstdPath: String, inputPath: String, outputPath: String, stderrPath: String) throws {
        let toolName = ZstdExecutableLocator.toolName
        try writeFile(atPath: stderrPath, contents: Data())
        // The process needs a real file handle for stderr. The path was created above through the
        // file system abstraction, so this is the only direct I/O and it is limited to the child process.
        let stderrHandle = try FileHandle(forWritingTo: URL(fileURLWithPath: stderrPath))
        defer { try? stderrHandle.close() }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: zstdPath)
        process.arguments = ["-q", "-d", "-f", inputPath, "-o", outputPath]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = stderrHandle

        do {
            try process.run()
        } catch {
            throw SessionReaderError.decompressionFailed(
                tool: toolName,
                detail: "could not launch \(zstdPath): \(error.localizedDescription)"
            )
        }
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            throw SessionReaderError.decompressionFailed(
                tool: toolName,
                detail: describeFailure(of: process, stderrPath: stderrPath)
            )
        }
    }

    private func describeFailure(of process: Process, stderrPath: String) -> String {
        let status = process.terminationReason == .uncaughtSignal
            ? "terminated by signal \(process.terminationStatus)"
            : "exit status \(process.terminationStatus)"
        let stderr = fileSystem.contents(atPath: stderrPath)
            .flatMap { String(data: $0, encoding: .utf8) }?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return stderr.isEmpty ? "\(status), no stderr output" : "\(status), stderr: \(stderr)"
    }
}
