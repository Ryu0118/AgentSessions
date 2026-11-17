@testable import AgentSessions
import Foundation
import Testing

struct ZstdExecutableLocatorTests {
    @Test("prefers a zstd found on PATH over fixed install locations")
    func prefersPathEntry() {
        let fileSystem = MockFileManager()
        fileSystem.executablePaths = ["/custom/bin/zstd", "/opt/homebrew/bin/zstd"]

        let located = ZstdExecutableLocator.locate(
            in: fileSystem,
            environment: ["PATH": "/usr/bin:/custom/bin"]
        )

        #expect(located == "/custom/bin/zstd")
    }

    @Test("falls back to fixed install locations when PATH has no zstd")
    func fallsBackToFixedCandidates() {
        let fileSystem = MockFileManager()
        fileSystem.executablePaths = ["/usr/local/bin/zstd"]

        let located = ZstdExecutableLocator.locate(in: fileSystem, environment: ["PATH": "/usr/bin"])

        #expect(located == "/usr/local/bin/zstd")
    }

    @Test("returns nil when zstd is nowhere to be found")
    func returnsNilWhenMissing() {
        let fileSystem = MockFileManager()

        let located = ZstdExecutableLocator.locate(in: fileSystem, environment: [:])

        #expect(located == nil)
    }

    @Test("a non-executable file with the zstd name is ignored")
    func ignoresNonExecutable() {
        let fileSystem = MockFileManager()
        fileSystem.files["/usr/bin/zstd"] = Data()

        let located = ZstdExecutableLocator.locate(in: fileSystem, environment: ["PATH": "/usr/bin"])

        #expect(located == nil)
    }
}
