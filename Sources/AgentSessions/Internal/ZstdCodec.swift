import Foundation

/// Thin wrapper around the system `zstd` CLI for DeepSeek Harness session logs.
enum ZstdCodec {
    static func decompress(_ data: Data) throws -> Data {
        try run(arguments: ["-d", "-c"], input: data)
    }

    static func compress(_ data: Data) throws -> Data {
        try run(arguments: ["-c"], input: data)
    }

    private static func run(arguments: [String], input: Data) throws -> Data {
        guard let zstdPath = resolveZstdPath() else {
            throw SessionReaderError.cannotReadFile("zstd binary not found on PATH")
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: zstdPath)
        process.arguments = arguments

        let stdin = Pipe()
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = stderr

        try process.run()
        stdin.fileHandleForWriting.write(input)
        try stdin.fileHandleForWriting.close()
        process.waitUntilExit()

        let output = stdout.fileHandleForReading.readDataToEndOfFile()
        if process.terminationStatus != 0 {
            let err = String(data: stderr.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            throw SessionReaderError.cannotReadFile("zstd failed: \(err)")
        }
        return output
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
