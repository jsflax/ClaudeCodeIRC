import Foundation

/// Wire types for the public room directory. Mirrors the Worker at
/// `worker/src/index.ts`. Bumping `Self.protocolVersion` here without
/// bumping the Worker's `body.version` rejection branch will break
/// `POST /publish` — keep them in sync.
public enum DirectoryAPI {
    /// Protocol-level version — distinct from `publishVersion`, which
    /// is the host-side monotonic counter used for last-writer-wins.
    public static let protocolVersion = 1

    /// `POST /publish` body. Hosts heartbeat this every ~30s while a
    /// non-private room is live.
    public struct PublishRequest: Codable, Sendable {
        public let version: Int
        public let roomId: String
        public let name: String
        public let hostHandle: String
        public let wssURL: String
        public let groupId: String
        public let publishVersion: Int

        public init(
            roomId: String,
            name: String,
            hostHandle: String,
            wssURL: String,
            groupId: String,
            publishVersion: Int
        ) {
            self.version = DirectoryAPI.protocolVersion
            self.roomId = roomId
            self.name = name
            self.hostHandle = hostHandle
            self.wssURL = wssURL
            self.groupId = groupId
            self.publishVersion = publishVersion
        }
    }

    /// `POST /publish` 200 OK response.
    public struct PublishResponse: Codable, Sendable {
        public let ok: Bool
        public let ttlRemaining: Int
        public let knownVersions: [Int]
    }

    /// `DELETE /publish/<roomId>` body.
    public struct DeleteRequest: Codable, Sendable {
        public let groupId: String
        public init(groupId: String) { self.groupId = groupId }
    }

    /// `GET /list?group=<groupId>` response.
    public struct ListResponse: Codable, Sendable {
        public let version: Int
        public let rooms: [ListedRoom]
    }

    /// One room as returned by `/list`. The `wssURL` here is what the
    /// peer dials; `joinCode` is NOT exposed by the directory — it
    /// arrives via Lattice sync once the peer has connected (and the
    /// room is unjoinable without it for non-open rooms).
    public struct ListedRoom: Codable, Hashable, Sendable, Identifiable {
        public let roomId: String
        public let name: String
        public let hostHandle: String
        public let wssURL: String
        public let lastSeenAge: Int

        public var id: String { roomId }
    }
}
