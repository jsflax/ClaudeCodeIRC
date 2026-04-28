import CryptoKit
import Foundation

/// Computes `groupId = base64url(sha256(secret))` — the bucket key used
/// by the directory Worker (`POST /publish`'s `groupId` field, and
/// `GET /list?group=<hashHex>`).
///
/// The Worker is zero-knowledge by design: it never sees the raw
/// secret, only the hash. An attacker who guesses random hashes and
/// queries `/list` against them gets nothing — the 2^256 hash space
/// makes brute-force enumeration infeasible.
///
/// The encoding is RFC 4648 §5 base64url **without** padding, so the
/// resulting string is paste-safe for URL query parameters and KV
/// keys (no `+` / `/` / `=`).
public enum GroupID {
    /// Compute the hash from the raw secret bytes.
    public static func compute(secret: Data) -> String {
        let digest = SHA256.hash(data: secret)
        return base64URL(Data(digest))
    }

    /// Convenience — compute from a UTF-8 string (e.g. a user-typed
    /// passphrase). Most call sites should use the `Data` overload
    /// because the secret arrives as raw bytes from a base64url-decoded
    /// invite payload.
    public static func compute(secretUTF8: String) -> String {
        compute(secret: Data(secretUTF8.utf8))
    }

    /// Generate a fresh 32-byte (256-bit) group secret. Caller embeds
    /// it in a group invite code; pasted by another member, the same
    /// hash falls out.
    public static func newSecret() -> Data {
        var bytes = [UInt8](repeating: 0, count: 32)
        let status = bytes.withUnsafeMutableBytes { buf in
            SecRandomCopyBytes(kSecRandomDefault, 32, buf.baseAddress!)
        }
        precondition(status == errSecSuccess, "SecRandomCopyBytes failed")
        return Data(bytes)
    }

    /// The well-known bucket every `.public` room publishes into. Not
    /// derived from any secret — anyone querying the directory without
    /// a group invite gets results from this bucket. Kept as a
    /// constant rather than a magic literal so call sites are greppable.
    public static let publicBucket = "public"

    // MARK: - base64url

    private static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
