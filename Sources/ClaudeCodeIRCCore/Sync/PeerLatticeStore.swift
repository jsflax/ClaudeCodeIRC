import Foundation
import Lattice

/// Opens a peer-side `Lattice` for a given room code + WS endpoint.
///
/// `RoomInstance.swap()` uses this to reconnect to a new tunnel URL
/// after the host's `cloudflared` restart. The protocol exists so tests
/// can substitute a path-controlled implementation without mutating
/// `RoomPaths` global state — the initial peer open and the swap-time
/// reopen must resolve to the same on-disk SQLite file, which means
/// both opens have to go through the same source of truth.
///
/// Production wiring uses `DefaultPeerLatticeStore`, which forwards to
/// `RoomStore.openPeer` and inherits its `RoomPaths`-based file layout.
public protocol PeerLatticeStore: Sendable {
    func openPeer(
        code: String,
        endpoint: URL,
        joinCode: String?
    ) throws -> Lattice
}

/// Production `PeerLatticeStore` — wraps the static `RoomStore.openPeer`
/// factory. Stateless; instances are interchangeable.
public struct DefaultPeerLatticeStore: PeerLatticeStore {
    public init() {}

    public func openPeer(
        code: String,
        endpoint: URL,
        joinCode: String?
    ) throws -> Lattice {
        try RoomStore.openPeer(code: code, endpoint: endpoint, joinCode: joinCode)
    }
}
