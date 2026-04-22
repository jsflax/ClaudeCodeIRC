import Foundation
import Lattice

/// Collects the schema for a ClaudeCodeIRC room and the logic to open a
/// Lattice instance against it.
///
/// The store is deliberately a thin factory — callers (host + peer code paths)
/// configure sync via `Lattice.Configuration.wssEndpoint` / `authorizationToken`
/// after opening, so this wrapper doesn't bake assumptions about topology.
public enum RoomStore {
    /// Every `@Model` type that participates in room sync. Passed to
    /// `Lattice(for:configuration:)` so the schema is registered.
    /// `nonisolated(unsafe)` because `[any Model.Type]` isn't `Sendable`; the
    /// array is an immutable `let` of metatypes, so there's nothing to race on.
    nonisolated(unsafe) public static let schema: [any Model.Type] = [
        Session.self,
        Member.self,
        Turn.self,
        ChatMessage.self,
        AssistantChunk.self,
        ToolEvent.self,
        ApprovalRequest.self,
        HostHandoff.self,
    ]

    /// Open (or create) the host-side authoritative room DB on disk.
    public static func openHost(code: String) throws -> Lattice {
        try RoomPaths.ensureRootDirectoryExists()
        return try Lattice(
            for: schema,
            configuration: .init(fileURL: RoomPaths.storeURL(forCode: code)))
    }

    /// Open an empty peer-side replica that syncs to the given host endpoint.
    /// The first sync will catch up the full history from the host.
    /// `joinCode` is `nil` for open rooms; the peer's Lattice is then
    /// configured without an `authorizationToken`, and the host's server
    /// accepts the upgrade without a bearer check.
    public static func openPeer(
        code: String,
        endpoint: URL,
        joinCode: String?
    ) throws -> Lattice {
        try RoomPaths.ensureRootDirectoryExists()
        return try Lattice(
            for: schema,
            configuration: .init(
                fileURL: RoomPaths.storeURL(forCode: code),
                authorizationToken: joinCode,
                wssEndpoint: endpoint))
    }
}
