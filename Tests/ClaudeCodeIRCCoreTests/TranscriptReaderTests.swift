import Foundation
import Testing
@testable import ClaudeCodeIRCCore

/// Coverage for `TranscriptReader.parseAssistant` and the higher-level
/// `latestAssistant(at:)` against fixture jsonl bytes. Asserts the
/// parser pulls model id + cumulative usage off the assistant entry
/// shape Claude Code itself writes to disk; backstops `StatusLineDriver`
/// so a refactor of the entry shape gets caught.
@Suite struct TranscriptReaderTests {

    private func line(model: String, input: Int, cacheCreate: Int, cacheRead: Int, output: Int) -> String {
        // Mirror the actual Claude Code transcript shape — fields like
        // parentUuid / timestamp are present but ignored by the parser.
        let dict: [String: Any] = [
            "type": "assistant",
            "parentUuid": UUID().uuidString,
            "timestamp": "2026-04-29T17:00:00Z",
            "version": "1.0.0",
            "message": [
                "model": model,
                "usage": [
                    "input_tokens": input,
                    "cache_creation_input_tokens": cacheCreate,
                    "cache_read_input_tokens": cacheRead,
                    "output_tokens": output,
                ],
            ],
        ]
        let data = try! JSONSerialization.data(withJSONObject: dict)
        return String(data: data, encoding: .utf8)!
    }

    @Test func parsesAssistantLine() throws {
        let raw = line(model: "claude-opus-4-7", input: 100, cacheCreate: 200, cacheRead: 300, output: 50)
        let snap = try #require(TranscriptReader.parseAssistant(Data(raw.utf8)))
        #expect(snap.modelId == "claude-opus-4-7")
        #expect(snap.usage.inputTokens == 100)
        #expect(snap.usage.cacheCreationInputTokens == 200)
        #expect(snap.usage.cacheReadInputTokens == 300)
        #expect(snap.usage.outputTokens == 50)
        #expect(snap.usage.totalTokens == 650)
    }

    @Test func skipsNonAssistantTypes() {
        let userLine = """
            {"type":"user","message":{"role":"user","content":"hi"}}
            """
        #expect(TranscriptReader.parseAssistant(Data(userLine.utf8)) == nil)
    }

    @Test func skipsMalformedJson() {
        #expect(TranscriptReader.parseAssistant(Data("{not json".utf8)) == nil)
    }

    @Test func missingUsageFieldDefaultsZero() throws {
        // Some transcript variants omit usage subfields when they're
        // zero — ensure the parser tolerates that rather than
        // returning nil for the whole line.
        let dict: [String: Any] = [
            "type": "assistant",
            "message": [
                "model": "claude-haiku-4-5",
                "usage": ["input_tokens": 5],
            ],
        ]
        let data = try JSONSerialization.data(withJSONObject: dict)
        let snap = try #require(TranscriptReader.parseAssistant(data))
        #expect(snap.usage.inputTokens == 5)
        #expect(snap.usage.outputTokens == 0)
        #expect(snap.usage.totalTokens == 5)
    }

    @Test func latestAssistantReturnsLastLine() throws {
        let dir = FileManager.default.temporaryDirectory
            .appending(path: "ccirc-transcript-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appending(path: "session.jsonl")

        let body = [
            line(model: "claude-haiku-4-5", input: 1, cacheCreate: 0, cacheRead: 0, output: 1),
            line(model: "claude-opus-4-7",  input: 10, cacheCreate: 20, cacheRead: 30, output: 5),
        ].joined(separator: "\n") + "\n"
        try body.write(to: file, atomically: true, encoding: .utf8)

        let snap = try #require(TranscriptReader.latestAssistant(at: file))
        // The walk is back-to-front; the second line wins.
        #expect(snap.modelId == "claude-opus-4-7")
        #expect(snap.usage.totalTokens == 65)
    }

    @Test func latestAssistantNilWhenFileMissing() {
        let missing = FileManager.default.temporaryDirectory
            .appending(path: "ccirc-no-such-file-\(UUID().uuidString).jsonl")
        #expect(TranscriptReader.latestAssistant(at: missing) == nil)
    }

    @Test func latestAssistantSkipsTrailingPartialLine() throws {
        // Mirrors the streaming-write case: file ends mid-line because
        // claude code is still writing. We should fall back to the
        // last fully-parseable assistant entry.
        let dir = FileManager.default.temporaryDirectory
            .appending(path: "ccirc-transcript-partial-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appending(path: "session.jsonl")

        let body = line(model: "claude-opus-4-7", input: 1, cacheCreate: 0, cacheRead: 0, output: 1)
            + "\n{\"type\":\"assistant\",\"message\":{\"mod"  // truncated, no trailing newline
        try body.write(to: file, atomically: true, encoding: .utf8)

        let snap = try #require(TranscriptReader.latestAssistant(at: file))
        #expect(snap.modelId == "claude-opus-4-7")
    }
}
