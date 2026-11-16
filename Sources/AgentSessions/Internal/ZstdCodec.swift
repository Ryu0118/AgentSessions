import Foundation

/// Thin wrapper around the system `zstd` CLI for DeepSeek Harness session logs.
///
/// Uses temp files instead of pipes so large payloads cannot deadlock on a full stdout buffer
/// while `waitUntilExit` runs before the pipe is drained.
enum ZstdCodec {
    static func decompress(_ data: Data) throws -> Data {
        try run(mode: .decompress, input: data)
    }

    static func compress(_ data: Data) throws -> Data {
        try run(mode: .compress, input: data)
    }

    private enum Mode {
        case compress
        case decompress
    }

    private static func run(mode: Mode, input: Data) throws -> Data {
        guard let zstdPath = resolveZstdPath() else {
            throw SessionReaderError.cannotReadFile("zstd binary not found on PATH")
        }

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("agentsessions-zstd-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let inputURL = directory.appendingPathComponent("input")
        let outputURL = directory.appendingPathComponent("output")
        try input.write(to: inputURL)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: zstdPath)
        switch mode {
        case .compress:
            process.arguments = ["-q", "-f", inputURL.path, "-o", outputURL.path]
        case .decompress:
            process.arguments = ["-q", "-d", "-f", inputURL.path, "-o", outputURL.path]
        }
        process.standardOutput = Pipe()
        process.standardError = Pipe()

        try process.run()
        process.waitUntilExit()
        if process.terminationStatus != 0 {
            let err = String(
                data: (process.standardError as? Pipe)?.fileHandleForReading.readDataToEndOfFile() ?? Data(),
                encoding: .utf8
            ) ?? ""
            throw SessionReaderError.cannotReadFile("zstd failed: \(err)")
        }
        return try Data(contentsOf: outputURL)
    }

    private static func resolveZstdPath() -> String? {
        let candidates = [
            "/opt/homebrew/bin/zstd",
            "/usr/local/bin/zstd",
            "/usr/bin/zstd",
        ]
        if let found = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) {
            return found
        }
        let which = Process()
        which.executableURL = URL(fileURLWithPath: "/usr/bin/which")
        which.arguments = ["zstd"]
        let pipe = Pipe()
        which.standardOutput = pipe
        which.standardError = Pipe()
        do {
            try which.run()
            which.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let path = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if let path, !path.isEmpty, FileManager.default.isExecutableFile(atPath: path) {
                return path
            }
        } catch {
            return nil
        }
        return nil
    }
}
