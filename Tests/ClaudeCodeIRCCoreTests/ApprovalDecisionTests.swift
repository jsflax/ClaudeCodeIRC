import Foundation
import Testing
import MCP
import ClaudeCodeIRCCore

/// Guards the wire shape claude expects back from our MCP shim.
/// Changing these field names or serialization silently breaks
/// per-tool approval routing, so we lock them in a test.
@Suite struct ApprovalDecisionTests {
    @Test func allowOmitsMessageWhenNil() throws {
        // claude's permission-prompt-tool rejects `{"behavior":"allow","message":null}`
        // as malformed — the schema expects `message` to be absent for
        // allow, present only for deny. We had a regression where
        // JSONEncoder's default nil-as-null tripped this validation and
        // every approval came back as "malformed hook output" to claude.
        let d = ApprovalMcpShim.Decision(behavior: .allow, updatedInput: nil, message: nil)
        let json = d.asJsonString
        #expect(json == #"{"behavior":"allow"}"#)
        let decoded = try JSONSerialization.jsonObject(with: Data(json.utf8))
            as! [String: Any]
        #expect(decoded["behavior"] as? String == "allow")
        #expect(decoded["message"] == nil)
    }

    @Test func allowEchoesUpdatedInput() throws {
        // Regression: claude-p's permission-prompt-tool runtime
        // *requires* `updatedInput` as a record on `allow` responses —
        // omitting it produces "invalid_union / expected record"
        // tool_result errors that the model then describes as
        // "malformed hook response." Echo the original tool input.
        let input: Value = .object([
            "command": .string("touch /tmp/x"),
            "description": .string("probe"),
        ])
        let d = ApprovalMcpShim.Decision(
            behavior: .allow, updatedInput: input, message: nil)
        let json = d.asJsonString
        let decoded = try JSONSerialization.jsonObject(with: Data(json.utf8))
            as! [String: Any]
        #expect(decoded["behavior"] as? String == "allow")
        let updated = decoded["updatedInput"] as? [String: Any]
        #expect(updated?["command"] as? String == "touch /tmp/x")
        #expect(updated?["description"] as? String == "probe")
        #expect(decoded["message"] == nil)
    }

    @Test func denyIncludesReason() throws {
        let d = ApprovalMcpShim.Decision(behavior: .deny, updatedInput: nil, message: "user denied")
        let json = d.asJsonString
        let decoded = try JSONSerialization.jsonObject(with: Data(json.utf8))
            as! [String: Any]
        #expect(decoded["behavior"] as? String == "deny")
        #expect(decoded["message"] as? String == "user denied")
    }

    @Test func keysAreStableOrder() {
        // `sortedKeys` in the encoder gives deterministic output, which
        // makes the wire format easier to reason about / log.
        let a = ApprovalMcpShim.Decision(behavior: .allow, updatedInput: nil, message: "ok").asJsonString
        let b = ApprovalMcpShim.Decision(behavior: .allow, updatedInput: nil, message: "ok").asJsonString
        #expect(a == b)
        #expect(a.range(of: "\"behavior\"")!.lowerBound
            < a.range(of: "\"message\"")!.lowerBound)
    }
}
