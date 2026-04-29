import Combine
import Foundation
import Lattice

/// Mirror of `ApprovalVoteCoordinator` for `AskQuestion` rows.
/// Watches `AskVote` and `AskQuestion` writes plus `Member.isAway`
/// flips, runs `AskTally.evaluate` on every pending question, and
/// commits `status = .answered` + `chosenLabels` once the tally
/// reports `complete = true`.
///
/// Observing `AskQuestion` writes (not just `AskVote`) is required:
/// users can append free-text options at runtime, which doesn't
/// produce a vote write but does change the option set. The
/// coordinator must re-evaluate so the new label can collect
/// counts; without this hook, a free-text submission would never
/// trigger completion until somebody else's vote came in.
///
/// Runs on every client. Tally is deterministic given identical
/// sync'd state, and the `if status == .pending` guard at the
/// write site keeps concurrent runs from stomping each other.
@MainActor
public final class AskVoteCoordinator {
    private let lattice: Lattice
    private var voteObserver: AnyCancellable?
    private var questionObserver: AnyCancellable?
    private var memberObserver: AnyCancellable?

    public init(lattice: Lattice) {
        self.lattice = lattice
        Log.line("ask-coord", "starting (multi-client question tally)")
        voteObserver = lattice.observe(AskVote.self) { @Sendable [weak self] change in
            switch change {
            case .insert, .update: break
            default: return
            }
            Task { @MainActor [weak self] in self?.reevaluatePending() }
        }
        questionObserver = lattice.observe(AskQuestion.self) { @Sendable [weak self] change in
            // New free-text option appended → option set changed →
            // re-tally. Inserts (newly-opened question) trigger an
            // initial evaluation too, so trivial single-pane self-
            // answers fire without waiting for a separate vote.
            switch change {
            case .insert, .update: break
            default: return
            }
            Task { @MainActor [weak self] in self?.reevaluatePending() }
        }
        memberObserver = lattice.observe(Member.self) { @Sendable [weak self] change in
            switch change {
            case .insert, .update: break
            default: return
            }
            Task { @MainActor [weak self] in self?.reevaluatePending() }
        }
        // Catch-up scan for any state that landed before observers
        // attached (e.g. peer joining a room with an open question).
        reevaluatePending()
    }

    private func reevaluatePending() {
        // Quorum denominator: non-AFK, recently-heartbeated members.
        // `RoomInstance` writes `lastSeenAt = Date()` every
        // `heartbeatInterval` seconds; a stale row means the member's
        // process is gone (killed, crashed, network dropped) and must
        // not block quorum. `.count` resolves via SQL aggregate.
        let staleCutoff = Date(timeIntervalSinceNow: -RoomInstance.presenceThreshold)
        let presentQuorum = lattice.objects(Member.self)
            .where { !$0.isAway && $0.lastSeenAt > staleCutoff }
            .count

        // First pass: count completions across all pending rows so
        // we can early-exit when nothing has flipped. Avoids opening
        // a transaction on every single AskVote write when the room
        // is mid-quorum and nothing's actually answered yet.
        let pending = lattice.objects(AskQuestion.self)
            .where { $0.status == .pending }
        let anyComplete = pending.contains { q in
            var ballots: [AskTally.Ballot] = []
            for vote in q.votes {
                ballots.append(.init(labels: vote.chosenLabels, castAt: vote.castAt))
            }
            return AskTally.evaluate(
                ballots: ballots,
                presentQuorum: presentQuorum,
                multiSelect: q.multiSelect).complete
        }
        guard anyComplete else { return }

        // Second pass — re-tally and write atomically. Use the
        // explicit begin/commit form rather than `transaction { }`
        // so the for-loop body stays in the main-actor-isolated
        // function context (the closure form runs under a sending
        // closure type that Swift 6 won't let us pass non-Sendable
        // model refs into). Transactions aren't an isolation
        // boundary; this is just an atomic-write batch.
        lattice.beginTransaction()
        for q in lattice.objects(AskQuestion.self).where({ $0.status == .pending }) {
            var ballots: [AskTally.Ballot] = []
            for vote in q.votes {
                ballots.append(.init(labels: vote.chosenLabels, castAt: vote.castAt))
            }
            let result = AskTally.evaluate(
                ballots: ballots,
                presentQuorum: presentQuorum,
                multiSelect: q.multiSelect)
            guard result.complete else { continue }
            let header = q.header
            let chosen = result.chosenLabels
            Log.line("ask-coord",
                     "question \(header) → answered chosen=\(chosen)")
            q.status = .answered
            q.chosenLabels = result.chosenLabels
            q.answeredAt = Date()
        }
        lattice.commitTransaction()
    }
}
