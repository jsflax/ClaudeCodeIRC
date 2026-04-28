import Foundation
import Testing
import ClaudeCodeIRCCore

@Suite struct JoinCodeTests {
    @Test func roundTripsWithJoinCode() throws {
        let url = URL(string: "wss://abc-quick-tunnel-1234.trycloudflare.com/room/sky42x")!
        let encoded = JoinCode.encode(
            roomCode: "sky42x",
            joinCode: "h7p9q3",
            wssURL: url)
        let decoded = try JoinCode.decode(encoded)
        #expect(decoded.roomCode == "sky42x")
        #expect(decoded.joinCode == "h7p9q3")
        #expect(decoded.wssURL == url)
    }

    @Test func roundTripsOpenRoomNoJoinCode() throws {
        let url = URL(string: "wss://example.trycloudflare.com/room/openrm")!
        let encoded = JoinCode.encode(
            roomCode: "openrm",
            joinCode: nil,
            wssURL: url)
        let decoded = try JoinCode.decode(encoded)
        #expect(decoded.joinCode == nil)
        #expect(decoded.roomCode == "openrm")
        #expect(decoded.wssURL == url)
    }

    @Test func decodeTrimsWhitespace() throws {
        let url = URL(string: "wss://example.trycloudflare.com/room/abc")!
        let encoded = JoinCode.encode(
            roomCode: "abc",
            joinCode: "x",
            wssURL: url)
        let padded = "  \n\(encoded)\n  "
        let decoded = try JoinCode.decode(padded)
        #expect(decoded.roomCode == "abc")
    }

    @Test func encodingIsPasteSafe() throws {
        // Verify the output contains only paste-friendly characters —
        // no spaces, no `+`, `/`, or `=` (those are base64 chars that
        // get mangled in URL contexts and email plaintext).
        let url = URL(string: "wss://x.trycloudflare.com/room/r")!
        let encoded = JoinCode.encode(
            roomCode: "r",
            joinCode: "key-with-/+=",
            wssURL: url)
        #expect(!encoded.contains(" "))
        #expect(!encoded.contains("\n"))
        #expect(!encoded.contains("+"))
        #expect(!encoded.contains("/"))
        #expect(!encoded.contains("="))
        // Round-trips back to the original despite the special chars.
        let decoded = try JoinCode.decode(encoded)
        #expect(decoded.joinCode == "key-with-/+=")
    }

    @Test func rejectsUnknownScheme() {
        let bad = "ccirc-foo:v1:r:::"
        #expect(throws: JoinCode.DecodeError.unsupportedScheme) {
            try JoinCode.decode(bad)
        }
    }

    @Test func rejectsUnknownVersion() {
        let bad = "ccirc-join:v99:r:k:u"
        #expect(throws: JoinCode.DecodeError.invalidVersion) {
            try JoinCode.decode(bad)
        }
    }

    @Test func rejectsTooFewSegments() {
        // 4 segments instead of 5
        let bad = "ccirc-join:v1:r:key"
        #expect(throws: JoinCode.DecodeError.invalidStructure) {
            try JoinCode.decode(bad)
        }
    }

    @Test func rejectsEmptyRoomCode() {
        // Valid base64url for an empty `wss://x` URL would be tricky;
        // construct via encode then mutate the roomCode to empty.
        let url = URL(string: "wss://x/room/r")!
        let encoded = JoinCode.encode(roomCode: "r", joinCode: nil, wssURL: url)
        // Replace the third `:`-separated segment with empty.
        var parts = encoded.split(separator: ":", maxSplits: 4, omittingEmptySubsequences: false)
        parts[2] = ""
        let bad = parts.joined(separator: ":")
        #expect(throws: JoinCode.DecodeError.invalidRoomCode) {
            try JoinCode.decode(bad)
        }
    }

    @Test func rejectsInvalidURLScheme() throws {
        // Encode a non-ws URL and verify decode rejects it. URL itself
        // is well-formed; just the wrong protocol.
        let httpURL = URL(string: "https://example.com/room/r")!
        let encoded = JoinCode.encode(roomCode: "r", joinCode: nil, wssURL: httpURL)
        #expect(throws: JoinCode.DecodeError.invalidURL) {
            try JoinCode.decode(encoded)
        }
    }

    @Test func rejectsInvalidBase64InKey() {
        // Hand-craft a malformed base64url payload in the key slot.
        let bad = "ccirc-join:v1:r:!!!:dXJs"
        #expect(throws: JoinCode.DecodeError.invalidJoinCode) {
            try JoinCode.decode(bad)
        }
    }

    @Test func rejectsInvalidBase64InURL() {
        let bad = "ccirc-join:v1:r:a2V5:!!!"
        #expect(throws: JoinCode.DecodeError.invalidURL) {
            try JoinCode.decode(bad)
        }
    }
}
