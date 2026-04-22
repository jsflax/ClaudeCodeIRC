import Foundation
import Lattice

/// Handoff record, written when the current host wants (graceful) or needs
/// (detected) to transfer the host role. Peers observe these rows to
/// participate in the handoff protocol.
@Model
public final class HostHandoff {
    public var reason: HandoffReason = .graceful
    public var offeredTo: Member?
    public var createdAt: Date = Date()
    public var status: HandoffStatus = .offered

    /// WS endpoint the new host is serving on. Written when the nominee
    /// accepts and has stood up its own sync server.
    public var newEndpoint: String? = nil
}
