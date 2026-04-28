import Foundation

/// Wire format for invite-by-paste over the internet.
///
/// **Format**: `ccirc-join:v1:<roomCode>:<base64url(joinCode)>:<base64url(wssURL)>`
///
/// - `roomCode` — the 6-char human-friendly code, also used in the WS
///   path (`/room/<roomCode>`). Plain text in the wire format so a user
///   can eyeball it.
/// - `joinCode` — the WS Bearer token (the existing `Session.joinCode`).
///   Empty for "open" rooms (no auth). base64url-encoded so it's
///   paste-clean without escaping the `:` separator.
/// - `wssURL` — full `wss://*.trycloudflare.com/room/<code>` URL the
///   peer should connect to. base64url-encoded for the same reason.
///
/// **Why a separate format from the LAN 6-char code.** On LAN, peers
/// discover the room via Bonjour and only need the bearer token —
/// they construct `ws://<hostname>:<port>/room/<code>` from the TXT
/// record. On the internet there is no Bonjour, so the URL has to
/// travel with the invite. A 6-char code embedded in `ccirc-join:v1:`
/// stays readable for users; the URL+key are bulky but only have to
/// survive a copy-paste, not a typed entry.
///
/// **Versioning**: the `v1` token is reserved for future format
/// changes; v1 callers must reject anything else.
public enum JoinCode {
    /// Decoded contents of a `ccirc-join:v1:` paste.
    public struct Decoded: Sendable, Equatable {
        public let roomCode: String
        /// `nil` for open rooms (the bearer slot was empty in the wire
        /// format). Same semantic as `Session.joinCode == nil`.
        public let joinCode: String?
        public let wssURL: URL

        public init(roomCode: String, joinCode: String?, wssURL: URL) {
            self.roomCode = roomCode
            self.joinCode = joinCode
            self.wssURL = wssURL
        }
    }

    public enum DecodeError: Error, Equatable {
        case unsupportedScheme
        case invalidVersion
        case invalidStructure
        case invalidRoomCode
        case invalidJoinCode
        case invalidURL
    }

    public static let scheme = "ccirc-join"
    public static let currentVersion = 1

    /// Format an invite string. Output is paste-safe: no internal
    /// whitespace, only `[A-Za-z0-9-_:]` characters.
    public static func encode(
        roomCode: String,
        joinCode: String?,
        wssURL: URL
    ) -> String {
        let keyPart = joinCode.map { Self.base64URL(Data($0.utf8)) } ?? ""
        let urlPart = Self.base64URL(Data(wssURL.absoluteString.utf8))
        return "\(scheme):v\(currentVersion):\(roomCode):\(keyPart):\(urlPart)"
    }

    /// Parse an invite string. Whitespace is trimmed before parsing —
    /// users often paste with surrounding newlines.
    public static func decode(_ raw: String) throws -> Decoded {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        // `split(maxSplits: 4)` keeps the URL portion intact even if
        // its base64url payload happens to contain... it can't, since
        // base64url omits `:`. Still cheap insurance.
        let parts = trimmed.split(
            separator: ":",
            maxSplits: 4,
            omittingEmptySubsequences: false)
        guard parts.count == 5 else { throw DecodeError.invalidStructure }
        guard parts[0] == scheme else { throw DecodeError.unsupportedScheme }
        guard parts[1] == "v\(currentVersion)" else { throw DecodeError.invalidVersion }

        let roomCode = String(parts[2])
        guard !roomCode.isEmpty else { throw DecodeError.invalidRoomCode }

        let keyPart = String(parts[3])
        let joinCode: String?
        if keyPart.isEmpty {
            joinCode = nil
        } else {
            guard let data = Self.base64URLDecode(keyPart),
                  let str = String(data: data, encoding: .utf8) else {
                throw DecodeError.invalidJoinCode
            }
            joinCode = str
        }

        let urlPart = String(parts[4])
        guard let urlData = Self.base64URLDecode(urlPart),
              let urlStr = String(data: urlData, encoding: .utf8),
              let url = URL(string: urlStr),
              let scheme = url.scheme?.lowercased(),
              scheme == "wss" || scheme == "ws"
        else {
            throw DecodeError.invalidURL
        }

        return Decoded(roomCode: roomCode, joinCode: joinCode, wssURL: url)
    }

    // MARK: - base64url

    /// RFC 4648 §5 base64url *without* padding. Picked over plain
    /// base64 because the `+`/`/` characters confuse URL parsers and
    /// `=` padding is awkward in a paste.
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
