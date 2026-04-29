import Foundation
import Lattice

/// Background actor that pings `Member.lastSeenAt = Date()` every
/// `interval` seconds. Quorum coordinators on every client filter
/// the quorum denominator by `lastSeenAt` recency, so a stopped
/// heartbeat ages the member out of quorum after
/// `RoomInstance.presenceThreshold`. The host's `MemberPresenceSweeper`
/// flips `isAway = true` on the same trigger.
///
/// Off-`MainActor` on purpose — the periodic write should not contend
/// with the UI thread. Resolves its own `Lattice` handle from a
/// `LatticeThreadSafeReference`; same pattern as `RoomSyncServer`.
/// Cross-instance change observation in the C++ layer fires the
/// MainActor-side coordinators / `@LatticeQuery` observers naturally.
///
/// Self-resolves the `Member` row on every tick — a kicked or `/leave`'d
/// member's row may have been deleted between ticks, in which case the
/// tick is a no-op.
public actor MemberHeartbeat {
    private let lattice: Lattice
    private let selfMemberGlobalId: UUID
    private let interval: TimeInterval
    private var task: Task<Void, Never>?

    public init(
        latticeReference: LatticeThreadSafeReference,
        selfMemberGlobalId: UUID,
        interval: TimeInterval
    ) throws {
        guard let resolved = latticeReference.resolve() else {
            throw HeartbeatError.latticeResolveFailed
        }
        self.lattice = resolved
        self.selfMemberGlobalId = selfMemberGlobalId
        self.interval = interval
    }

    public func start() {
        guard task == nil else { return }
        let nanos = UInt64(interval * 1_000_000_000)
        // Inherits the actor's executor — `tick()` runs without an
        // extra hop, and `Task.sleep` is just a suspension point that
        // releases the actor for other work.
        task = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: nanos)
                if Task.isCancelled { return }
                await self?.tick()
            }
        }
    }

    public func stop() {
        task?.cancel()
        task = nil
    }

    private func tick() {
        guard let me = lattice.object(Member.self, globalId: selfMemberGlobalId) else {
            return
        }
        me.lastSeenAt = Date()
    }

    public enum HeartbeatError: Error {
        case latticeResolveFailed
    }
}
