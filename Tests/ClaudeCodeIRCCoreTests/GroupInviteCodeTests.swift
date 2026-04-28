import Foundation
import Testing
import ClaudeCodeIRCCore

@Suite struct GroupInviteCodeTests {
    @Test func roundTrips() throws {
        let secret = Data((0..<32).map { _ in UInt8.random(in: 0...255) })
        let encoded = GroupInviteCode.encode(name: "Canary", secret: secret)
        let decoded = try GroupInviteCode.decode(encoded)
        #expect(decoded.name == "Canary")
        #expect(decoded.secret == secret)
    }

    @Test func roundTripsWithSpecialCharsInName() throws {
        // The name slot is base64url-encoded so users can pick any
        // label. Verifies a name with `:` (which would otherwise
        // break the separator scheme) round-trips.
        let secret = Data([0x01, 0x02, 0x03])
        let encoded = GroupInviteCode.encode(
            name: "Canary: Backend / Infra",
            secret: secret)
        let decoded = try GroupInviteCode.decode(encoded)
        #expect(decoded.name == "Canary: Backend / Infra")
    }

    @Test func encodingIsPasteSafe() {
        let encoded = GroupInviteCode.encode(
            name: "Org",
            secret: Data([0xFF, 0x00, 0xAB]))
        #expect(!encoded.contains(" "))
        #expect(!encoded.contains("\n"))
        #expect(!encoded.contains("+"))
        #expect(!encoded.contains("/"))
        #expect(!encoded.contains("="))
    }

    @Test func decodeTrimsWhitespace() throws {
        let encoded = GroupInviteCode.encode(name: "X", secret: Data([0x01]))
        let padded = "  \n\(encoded)\n  "
        let decoded = try GroupInviteCode.decode(padded)
        #expect(decoded.name == "X")
    }

    @Test func rejectsUnknownScheme() {
        let bad = "ccirc-foo:v1:bmFtZQ:c2VjcmV0"
        #expect(throws: GroupInviteCode.DecodeError.unsupportedScheme) {
            try GroupInviteCode.decode(bad)
        }
    }

    @Test func rejectsUnknownVersion() {
        let bad = "ccirc-group:v99:bmFtZQ:c2VjcmV0"
        #expect(throws: GroupInviteCode.DecodeError.invalidVersion) {
            try GroupInviteCode.decode(bad)
        }
    }

    @Test func rejectsTooFewSegments() {
        let bad = "ccirc-group:v1:bmFtZQ"
        #expect(throws: GroupInviteCode.DecodeError.invalidStructure) {
            try GroupInviteCode.decode(bad)
        }
    }

    @Test func rejectsEmptyName() {
        let bad = "ccirc-group:v1::c2VjcmV0"
        #expect(throws: GroupInviteCode.DecodeError.invalidName) {
            try GroupInviteCode.decode(bad)
        }
    }

    @Test func rejectsEmptySecret() {
        let bad = "ccirc-group:v1:bmFtZQ:"
        #expect(throws: GroupInviteCode.DecodeError.invalidSecret) {
            try GroupInviteCode.decode(bad)
        }
    }

    @Test func rejectsInvalidBase64InName() {
        let bad = "ccirc-group:v1:!!!:c2VjcmV0"
        #expect(throws: GroupInviteCode.DecodeError.invalidName) {
            try GroupInviteCode.decode(bad)
        }
    }

    @Test func rejectsInvalidBase64InSecret() {
        let bad = "ccirc-group:v1:bmFtZQ:!!!"
        #expect(throws: GroupInviteCode.DecodeError.invalidSecret) {
            try GroupInviteCode.decode(bad)
        }
    }
}
