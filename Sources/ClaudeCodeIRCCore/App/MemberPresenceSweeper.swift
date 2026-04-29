import Foundation
import Lattice

/// Host-only background actor. Periodically scans the room's `Member`
/// rows and flips `isAway = true` on any whose `lastSeenAt` is older
/// than `staleThreshold` — i.e. members whose `MemberHeartbeat` has
/// stopped pinging (process killed, crashed, lost network).
///
/// AFK already excludes a member from the quorum denominator
/// (`ApprovalVoteCoordinator` / `AskVoteCoordinator`), so the sweep
/// is what lets quorum recover from ungraceful exits without an
/// explicit `/leave`. Stale members stay in the userlist as `(afk)`
/// rather than being deleted — a network blip should not erase the
/// row, and reconnect (`RoomInstance.peer(...)`) clears `isAway`
/// on the same row.
///
/// Host-only because the host owns the canonical write. Last-writer-
/// wins makes peer-side runs idempotent if we ever wanted to mirror,
/// but it would just double the audit-log churn.
public actor MemberPresenceSweeper {
    private let lattice: Lattice
    private let selfMemberGlobalId: UUID
    private let interval: TimeInterval
    private let staleThreshold: TimeInterval
    private var task: Task<Void, Never>?

    public init(
        latticeReference: LatticeThreadSafeReference,
        selfMemberGlobalId: UUID,
        interval: TimeInterval,
        staleThreshold: TimeInterval
    ) throws {
        guard let resolved = latticeReference.resolve() else {
            throw SweeperError.latticeResolveFailed
        }
        self.lattice = resolved
        self.selfMemberGlobalId = selfMemberGlobalId
        self.interval = interval
        self.staleThreshold = staleThreshold
    }

    public func start() {
        guard task == nil else { return }
        let nanos = UInt64(interval * 1_000_000_000)
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
        let cutoff = Date(timeIntervalSinceNow: -staleThreshold)
        let selfId = selfMemberGlobalId
        let stale = lattice.objects(Member.self)
            .where { !$0.isAway && $0.lastSeenAt < cutoff }
        for m in stale where m.globalId != selfId {
            m.isAway = true
            m.awayReason = nil
        }
    }

    public enum SweeperError: Error {
        case latticeResolveFailed
    }
}
