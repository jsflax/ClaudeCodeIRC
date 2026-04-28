import Foundation
import Testing
import ClaudeCodeIRCCore

@Suite struct GroupIDTests {
    @Test func computeIsDeterministic() {
        let secret = Data([0x01, 0x02, 0x03, 0x04])
        #expect(GroupID.compute(secret: secret) == GroupID.compute(secret: secret))
    }

    @Test func computeIsCollisionFreeAcrossDifferentSecrets() {
        let a = GroupID.compute(secret: Data([0x01]))
        let b = GroupID.compute(secret: Data([0x02]))
        #expect(a != b)
    }

    /// SHA-256 hash is 32 bytes → base64url without padding is 43 chars.
    @Test func computeIsBase64URLOfFixedLength() {
        let hash = GroupID.compute(secret: Data([0xFF]))
        #expect(hash.count == 43)
        // Must not contain padding-encoding characters that break URL/KV keys.
        #expect(!hash.contains("+"))
        #expect(!hash.contains("/"))
        #expect(!hash.contains("="))
    }

    /// Known-answer test against an externally-verified SHA-256 of the
    /// empty string. Catches accidental algorithm swaps.
    @Test func emptySecretMatchesKnownSHA256() {
        // SHA-256("") = e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855
        // base64url (no pad) of that 32-byte digest:
        //   47DEQpj8HBSa-_TImW-5JCeuQeRkm5NMpJWZG3hSuFU
        let hash = GroupID.compute(secret: Data())
        #expect(hash == "47DEQpj8HBSa-_TImW-5JCeuQeRkm5NMpJWZG3hSuFU")
    }

    @Test func newSecretIs32Bytes() {
        let s = GroupID.newSecret()
        #expect(s.count == 32)
    }

    @Test func newSecretsAreDistinct() {
        let a = GroupID.newSecret()
        let b = GroupID.newSecret()
        #expect(a != b)  // 256-bit space; collision odds infinitesimal
    }

    @Test func publicBucketIsStable() {
        // Spelled out so a casual rename of `publicBucket` requires
        // updating both the constant and this test, surfacing the
        // wire-format implication (Worker queries against the literal).
        #expect(GroupID.publicBucket == "public")
    }
}
