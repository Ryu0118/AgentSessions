@testable import AgentSessions
import Foundation
import Testing

@Suite("Verifies JSONL line decoding for valid and invalid inputs.")
struct JSONLParserTests {
    struct SimpleEntry: Codable, Sendable {
        let type: String
        let message: String
    }

    struct TestCase: CustomTestStringConvertible, Sendable {
        let description: String
        let input: String
        let isValid: Bool

        var testDescription: String { description }

        static let allCases: [TestCase] = [
            TestCase(description: "valid JSON line", input: #"{"type":"user","message":"hello"}"#, isValid: true),
            TestCase(description: "blank line", input: "", isValid: false),
            TestCase(description: "whitespace only", input: "   ", isValid: false),
            TestCase(description: "invalid JSON", input: "not json at all", isValid: false),
            TestCase(description: "missing required field", input: #"{"type":"user"}"#, isValid: false),
        ]
    }

    @Test("decodes JSONL lines", arguments: TestCase.allCases)
    func decodeLine(_ testCase: TestCase) throws {
        let result = JSONLParser.decodeLine(testCase.input, as: SimpleEntry.self)
        if testCase.isValid {
            let entry = try #require(result)
            #expect(entry.type == "user")
            #expect(entry.message == "hello")
        } else {
            #expect(result == nil)
        }
    }
}

@Suite("Verifies ISO 8601 parsing with and without fractional seconds.")
struct DateUtilsTests {
    struct TestCase: CustomTestStringConvertible, Sendable {
        let description: String
        let input: String
        let isValid: Bool

        var testDescription: String { description }

        static let allCases: [TestCase] = [
            TestCase(description: "fractional seconds", input: "2024-03-09T12:30:00.123Z", isValid: true),
            TestCase(description: "no fractional seconds", input: "2024-03-09T12:30:00Z", isValid: true),
            TestCase(description: "garbage input", input: "not-a-date", isValid: false),
            TestCase(description: "empty string", input: "", isValid: false),
        ]
    }

    @Test("parses ISO 8601 dates", arguments: TestCase.allCases)
    func parseISO8601(_ testCase: TestCase) throws {
        let result = DateUtils.parseISO8601(testCase.input)
        if testCase.isValid {
            _ = try #require(result)
        } else {
            #expect(result == nil)
        }
    }
}

@Suite("Verifies middle truncation behavior for displayed project paths.")
struct PathTruncatedTests {
    @Test("short path returned as-is")
    func shortPath() {
        let path = "/Users/example/proj"
        #expect(path.pathTruncated(to: 30) == path)
    }

    @Test("long path keeps trailing component")
    func longPathKeepsTrailing() {
        let path = "/Users/example/workspace/projects/ctxmv"
        let result = path.pathTruncated(to: 25)
        #expect(result.hasSuffix("/ctxmv"))
        #expect(result.hasPrefix("/Users/example/"))
        #expect(result.contains("..."))
        #expect(result.count <= 25)
    }

    @Test("very tight limit falls back to ellipsis + trailing")
    func tightLimit() {
        let path = "/Users/example/workspace/projects/ctxmv"
        let result = path.pathTruncated(to: 15)
        #expect(result.hasSuffix("/ctxmv"))
        #expect(result.contains("..."))
        #expect(result.count <= 15)
    }

    @Test("two-component path uses regular truncation")
    func twoComponents() {
        let path = "/VeryLongDirectoryName/file"
        let result = path.pathTruncated(to: 10)
        #expect(result.count <= 10)
        #expect(result.hasSuffix("..."))
    }

    @Test("exact fit not truncated")
    func exactFit() {
        let path = "/Users/example/project"
        #expect(path.pathTruncated(to: path.count) == path)
    }
}

@Suite("Verifies human-readable byte count formatting.")
struct ByteCountTests {
    struct TestCase: CustomTestStringConvertible, Sendable {
        let description: String
        let input: Int64
        let expected: String

        var testDescription: String { description }

        static let allCases: [TestCase] = [
            TestCase(description: "bytes", input: 512, expected: "512 B"),
            TestCase(description: "kilobytes", input: 1536, expected: "1.5 KB"),
            TestCase(description: "megabytes", input: 1_048_576, expected: "1.0 MB"),
            TestCase(description: "large megabytes", input: 10_485_760, expected: "10 MB"),
            TestCase(description: "zero", input: 0, expected: "0 B"),
        ]
    }

    @Test("formats byte counts", arguments: TestCase.allCases)
    func format(_ testCase: TestCase) {
        #expect(testCase.input.formattedByteCount() == testCase.expected)
    }
}
