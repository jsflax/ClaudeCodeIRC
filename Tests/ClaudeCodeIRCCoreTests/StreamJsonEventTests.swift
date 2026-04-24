import Foundation
import Testing
import ClaudeCodeIRCCore

@Suite struct StreamJsonEventTests {
    private func decode(_ json: String) throws -> StreamJsonEvent {
        try JSONDecoder().decode(StreamJsonEvent.self, from: Data(json.utf8))
    }

    @Test func decodesSystemInit() throws {
        let event = try decode(#"""
        {"type":"system","subtype":"init","model":"claude-sonnet-4-6","session_id":"abc123","tools":["Bash"],"cwd":"/tmp"}
        """#)
        guard case .systemInit(let s) = event else {
            Issue.record("expected .systemInit, got \(event)"); return
        }
        #expect(s.session_id == "abc123")
        #expect(s.model == "claude-sonnet-4-6")
        #expect(s.tools == ["Bash"])
        #expect(s.cwd == "/tmp")
    }

    @Test func decodesAssistantWithTextBlock() throws {
        let event = try decode(#"""
        {"type":"assistant","session_id":"s","message":{"id":"m","role":"assistant","content":[{"type":"text","text":"hello"}]}}
        """#)
        guard case .assistant(let a) = event else {
            Issue.record("expected .assistant"); return
        }
        #expect(a.message?.content?.count == 1)
        #expect(a.message?.content?.first?.type == "text")
        #expect(a.message?.content?.first?.text == "hello")
    }

    @Test func decodesAssistantWithToolUse() throws {
        let event = try decode(#"""
        {"type":"assistant","message":{"content":[{"type":"tool_use","id":"tu_1","name":"Bash","input":{"command":"ls"}}]}}
        """#)
        guard case .assistant(let a) = event else {
            Issue.record("expected .assistant"); return
        }
        let block = a.message?.content?.first
        #expect(block?.type == "tool_use")
        #expect(block?.id == "tu_1")
        #expect(block?.name == "Bash")
        // Input is an object — preserved as ContentValue.
        if case .object(let o) = block?.input, case .string(let cmd) = o["command"] {
            #expect(cmd == "ls")
        } else {
            Issue.record("expected input.command = \"ls\"")
        }
    }

    @Test func decodesStreamEventTextDelta() throws {
        let event = try decode(#"""
        {"type":"stream_event","event":{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"hel"}}}
        """#)
        guard case .streamEvent(let e) = event else {
            Issue.record("expected .streamEvent"); return
        }
        #expect(e.event?.type == "content_block_delta")
        #expect(e.event?.delta?.type == "text_delta")
        #expect(e.event?.delta?.text == "hel")
    }

    @Test func decodesResult() throws {
        let event = try decode(#"""
        {"type":"result","subtype":"success","is_error":false,"duration_ms":420,"num_turns":1,"result":"done"}
        """#)
        guard case .result(let r) = event else {
            Issue.record("expected .result"); return
        }
        #expect(r.subtype == "success")
        #expect(r.is_error == false)
        #expect(r.duration_ms == 420)
        #expect(r.result == "done")
    }

    @Test func unknownTypeFallsBack() throws {
        let event = try decode(#"{"type":"something_new_in_v2","foo":"bar"}"#)
        if case .unknown(let raw) = event {
            #expect(raw.contains("something_new_in_v2"))
        } else {
            Issue.record("expected .unknown")
        }
    }

    @Test func contentValueRoundTripsNestedJson() throws {
        // Build a ContentValue, encode, decode, confirm structural equality.
        let original: StreamJsonEvent.ContentValue = .object([
            "name": .string("Bash"),
            "command": .string("ls -la"),
            "flags": .array([.string("-a"), .string("-l")]),
            "timeout": .number(5000),
            "async": .bool(true),
            "cwd": .null,
        ])
        let enc = JSONEncoder()
        let data = try enc.encode(original)
        let decoded = try JSONDecoder().decode(StreamJsonEvent.ContentValue.self, from: data)

        guard case .object(let o) = decoded,
              case .string(let name) = o["name"],
              case .array(let flags) = o["flags"],
              case .number(let timeout) = o["timeout"],
              case .bool(let isAsync) = o["async"],
              case .null = o["cwd"]
        else {
            Issue.record("unexpected decoded shape: \(decoded)")
            return
        }
        #expect(name == "Bash")
        #expect(flags.count == 2)
        #expect(timeout == 5000)
        #expect(isAsync == true)
    }
}
