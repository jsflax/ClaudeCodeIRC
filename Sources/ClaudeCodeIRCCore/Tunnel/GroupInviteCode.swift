import Foundation

/// Wire format for sharing a group secret out-of-band.
///
/// **Format**: `ccirc-group:v1:<base64url(name)>:<base64url(secret)>`
///
/// - `name` — local label ("Canary"). Encoded so users can put any
///   characters in it without breaking the `:` separator scheme.
/// - `secret` — 32 random bytes (typically) — the shared group key.
///   `base64url(sha256(secret))` is the directory bucket id, which the
///   Worker sees; the secret itself never leaves the local devices of
///   group members.
///
/// **Why a separate format from `ccirc-join:`.** Group invites
/// admit the holder to a *visibility scope* (the directory bucket),
/// not a specific room. Membership is conferred once and reused
/// across many room invites. The two formats are intentionally
/// distinct so a user pasting one into the other slot gets a clear
/// `unsupportedScheme` error rather than a confusing partial parse.
public enum GroupInviteCode {
    public struct Decoded: Sendable, Equatable {
        public let name: String
        public let secret: Data

        public init(name: String, secret: Data) {
            self.name = name
            self.secret = secret
        }
    }

    public enum DecodeError: Error, Equatable {
        case unsupportedScheme
        case invalidVersion
        case invalidStructure
        case invalidName
        case invalidSecret
    }

    public static let scheme = "ccirc-group"
    public static let currentVersion = 1

    public static func encode(name: String, secret: Data) -> String {
        let namePart = base64URL(Data(name.utf8))
        let secretPart = base64URL(secret)
        return "\(scheme):v\(currentVersion):\(namePart):\(secretPart)"
    }

    public static func decode(_ raw: String) throws -> Decoded {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = trimmed.split(
            separator: ":",
            maxSplits: 3,
            omittingEmptySubsequences: false)
        guard parts.count == 4 else { throw DecodeError.invalidStructure }
        guard parts[0] == scheme else { throw DecodeError.unsupportedScheme }
        guard parts[1] == "v\(currentVersion)" else { throw DecodeError.invalidVersion }

        guard let nameData = base64URLDecode(String(parts[2])),
              let name = String(data: nameData, encoding: .utf8),
              !name.isEmpty
        else { throw DecodeError.invalidName }

        guard let secret = base64URLDecode(String(parts[3])),
              !secret.isEmpty
        else { throw DecodeError.invalidSecret }

        return Decoded(name: name, secret: secret)
    }

    // MARK: - base64url

    static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    static func base64URLDecode(_ string: String) -> Data? {
        var padded = string
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        while padded.count % 4 != 0 { padded += "=" }
        return Data(base64Encoded: padded)
    }
}
