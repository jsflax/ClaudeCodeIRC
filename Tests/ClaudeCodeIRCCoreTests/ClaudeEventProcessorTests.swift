import Foundation
import Testing
import Lattice
import ClaudeCodeIRCCore

/// Integration test for `ClaudeEventProcessor`: feeds a scripted
/// event stream through the processor and asserts that the expected
/// Turn / AssistantChunk / ToolEvent rows land in an in-memory
/// Lattice. No subprocess, no pipes, no timers.
@Suite struct ClaudeEventProcessorTests {
    private func makeProcessor() throws -> (Lattice, Session, ClaudeEventProcessor) {
        let tmp = FileManager.default.temporaryDirectory
            .appending(path: "ClaudeCodeIRC-processor-\(UUID().uuidString).lattice")
        let lattice = try Lattice(
            for: RoomStore.schema,
            configuration: .init(fileURL: tmp))
        let session = Session()
        session.code = "test-room"
        session.cwd = "/tmp"
        lattice.add(session)
        return (lattice, session, ClaudeEventProcessor(lattice: lattice, session: session))
    }

    private func decode(_ json: String) throws -> StreamJsonEvent {
        try JSONDecoder().decode(StreamJsonEvent.self, from: Data(json.utf8))
    }

    @Test func openTurnInsertsStreamingTurnLinkedToSession() throws {
        let (lattice, session, proc) = try makeProcessor()
        var p = proc
        p.openTurn(promptMessage: nil)
        #expect(lattice.objects(Turn.self).count == 1)
        let turn = lattice.objects(Turn.self).first!
        #expect(turn.status == .streaming)
        #expect(turn.session?.code == session.code)
    }

    @Test func textDeltasBufferUntilFlush() throws {
        let (lattice, _, proc) = try makeProcessor()
        var p = proc
        p.openTurn(promptMessage: nil)
        try p.handle(decode(#"""
        {"type":"stream_event","event":{"type":"content_block_delta","delta":{"type":"text_delta","text":"Hel"}}}
        """#))
        try p.handle(decode(#"""
        {"type":"stream_event","event":{"type":"content_block_delta","delta":{"type":"text_delta","text":"lo "}}}
        """#))
        // Nothing written yet — driver would schedule a flush timer.
        #expect(lattice.objects(AssistantChunk.self).count == 0)
        #expect(p.pendingText == "Hello ")

        p.flush()
        #expect(lattice.objects(AssistantChunk.self).count == 1)
        #expect(lattice.objects(AssistantChunk.self).first?.text == "Hello ")
        #expect(p.pendingText.isEmpty)
    }

    @Test func contentBlockStopFlushesImplicitly() throws {
        let (lattice, _, proc) = try makeProcessor()
        var p = proc
        p.openTurn(promptMessage: nil)
        try p.handle(decode(#"""
        {"type":"stream_event","event":{"type":"content_block_delta","delta":{"type":"text_delta","text":"one"}}}
        """#))
        try p.handle(decode(#"""
        {"type":"stream_event","event":{"type":"content_block_stop"}}
        """#))
        #expect(lattice.objects(AssistantChunk.self).count == 1)
        #expect(lattice.objects(AssistantChunk.self).first?.text == "one")
    }

    @Test func toolUseThenToolResultRoundTrips() throws {
        let (lattice, _, proc) = try makeProcessor()
        var p = proc
        p.openTurn(promptMessage: nil)

        try p.handle(decode(#"""
        {"type":"assistant","message":{"content":[{"type":"tool_use","id":"tu_1","name":"Bash","input":{"command":"ls"}}]}}
        """#))
        #expect(lattice.objects(ToolEvent.self).count == 1)
        let ev = lattice.objects(ToolEvent.self).first!
        #expect(ev.name == "Bash")
        #expect(ev.status == .running)
        #expect(ev.result == nil)

        try p.handle(decode(#"""
        {"type":"assistant","message":{"content":[{"type":"tool_result","tool_use_id":"tu_1","content":"file1\nfile2","is_error":false}]}}
        """#))
        #expect(ev.status == .ok)
        #expect(ev.endedAt != nil)
        #expect(ev.result != nil)
    }

    @Test func toolResultErrorMarksEventErrored() throws {
        let (lattice, _, proc) = try makeProcessor()
        var p = proc
        p.openTurn(promptMessage: nil)
        try p.handle(decode(#"""
        {"type":"assistant","message":{"content":[{"type":"tool_use","id":"tu_2","name":"Bash","input":{}}]}}
        """#))
        try p.handle(decode(#"""
        {"type":"assistant","message":{"content":[{"type":"tool_result","tool_use_id":"tu_2","content":"boom","is_error":true}]}}
        """#))
        let ev = lattice.objects(ToolEvent.self).first!
        #expect(ev.status == .errored)
    }

    @Test func resultEventClosesTurnWithDone() throws {
        let (lattice, _, proc) = try makeProcessor()
        var p = proc
        p.openTurn(promptMessage: nil)
        try p.handle(decode(#"""
        {"type":"stream_event","event":{"type":"content_block_delta","delta":{"type":"text_delta","text":"hi"}}}
        """#))
        try p.handle(decode(#"""
        {"type":"result","subtype":"success","is_error":false,"duration_ms":42,"result":"hi"}
        """#))
        let turn = lattice.objects(Turn.self).first!
        #expect(turn.status == .done)
        #expect(turn.endedAt != nil)
        // Pending text flushed into a chunk before the turn closed.
        #expect(lattice.objects(AssistantChunk.self).count == 1)
    }

    @Test func resultOnlyFallbackInsertsSingleChunk() throws {
        // Some CLI paths skip per-delta streaming and just hand back
        // a final `result.result` string. The processor backfills an
        // AssistantChunk so the Turn is never empty.
        let (lattice, _, proc) = try makeProcessor()
        var p = proc
        p.openTurn(promptMessage: nil)
        try p.handle(decode(#"""
        {"type":"result","subtype":"success","is_error":false,"result":"final answer"}
        """#))
        #expect(lattice.objects(AssistantChunk.self).count == 1)
        #expect(lattice.objects(AssistantChunk.self).first?.text == "final answer")
    }

    @Test func errorResultFlipsTurnStatusToErrored() throws {
        let (lattice, _, proc) = try makeProcessor()
        var p = proc
        p.openTurn(promptMessage: nil)
        try p.handle(decode(#"""
        {"type":"result","subtype":"error_max_turns","is_error":true}
        """#))
        let turn = lattice.objects(Turn.self).first!
        #expect(turn.status == .errored)
    }

    @Test func closeTurnOnEofMarksStreamingTurnErrored() throws {
        let (lattice, _, proc) = try makeProcessor()
        var p = proc
        p.openTurn(promptMessage: nil)
        p.closeTurnOnEof()
        let turn = lattice.objects(Turn.self).first!
        #expect(turn.status == .errored)
        #expect(turn.endedAt != nil)
    }

    @Test func unknownEventsAreIgnored() throws {
        let (lattice, _, proc) = try makeProcessor()
        var p = proc
        p.openTurn(promptMessage: nil)
        try p.handle(decode(#"{"type":"some_new_v2_event","foo":"bar"}"#))
        p.flush()
        #expect(lattice.objects(AssistantChunk.self).count == 0)
        // Turn still open (unknown events don't close it).
        #expect(p.currentTurn != nil)
    }

    @Test func assistantTextBlockSkippedWhenDeltasAlreadyStreamed() throws {
        // `claude -p` sends both streaming deltas AND a consolidated
        // `assistant` event with the same full text as a single block.
        // The processor must honour only one source to avoid writing
        // the reply twice.
        let (lattice, _, proc) = try makeProcessor()
        var p = proc
        p.openTurn(promptMessage: nil)
        try p.handle(decode(#"""
        {"type":"stream_event","event":{"type":"content_block_delta","delta":{"type":"text_delta","text":"Hi there"}}}
        """#))
        try p.handle(decode(#"""
        {"type":"stream_event","event":{"type":"content_block_stop"}}
        """#))
        // Claude's final assistant event repeats the same text.
        try p.handle(decode(#"""
        {"type":"assistant","message":{"content":[{"type":"text","text":"Hi there"}]}}
        """#))
        p.flush()
        let texts = lattice.objects(AssistantChunk.self).map(\.text)
        #expect(texts == ["Hi there"])
    }

    @Test func multipleChunksGetMonotonicIndexes() throws {
        let (lattice, _, proc) = try makeProcessor()
        var p = proc
        p.openTurn(promptMessage: nil)
        for word in ["one ", "two ", "three"] {
            try p.handle(decode(#"""
            {"type":"stream_event","event":{"type":"content_block_delta","delta":{"type":"text_delta","text":"\#(word)"}}}
            """#))
            p.flush()
        }
        let chunks = lattice.objects(AssistantChunk.self)
            .sorted { $0.chunkIndex < $1.chunkIndex }
        #expect(chunks.count == 3)
        #expect(chunks.map(\.chunkIndex) == [0, 1, 2])
        #expect(chunks.map(\.text) == ["one ", "two ", "three"])
    }
}
