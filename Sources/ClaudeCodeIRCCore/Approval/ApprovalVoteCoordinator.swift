import Combine
import Foundation
import Lattice

/// Watches `ApprovalVote` inserts and `Member.isAway` flips, re-runs
/// `ApprovalTally.evaluate` on every pending `ApprovalRequest`, and
/// writes the terminal `request.status` when the outcome flips out
/// of `.pending`.
///
/// Runs on every client (host + peers). The tally is deterministic
/// given identical sync'd state, and `request.status` writes are
/// idempotent under Lattice's last-writer-wins semantics, so there's
/// no harmful race when two clients arrive at the same outcome
/// independently. Running on every client means a peer sees the
/// status flip the moment its local lattice has the quorum-reaching
/// vote, rather than waiting for the host's write to sync back.
///
/// `@MainActor` because the Lattice instance we observe is pinned to
/// the main actor by the app's threading contract; writes we perform
/// must happen on the same isolation.
@MainActor
public final class ApprovalVoteCoordinator {
    private let lattice: Lattice
    private var voteObserver: AnyCancellable?
    private var memberObserver: AnyCancellable?

    public init(lattice: Lattice) {
        self.lattice = lattice
        Log.line("vote-coord", "starting (host-side tally driver)")
        voteObserver = lattice.observe(ApprovalVote.self) { @Sendable [weak self] change in
            // Only re-evaluate on insert/update. Delete is not a
            // driver event — a vote being removed was our own doing
            // (tally-committed) and re-evaluating would loop.
            guard case .insert = change else { return }
            Task { @MainActor [weak self] in self?.reevaluatePending() }
        }
        memberObserver = lattice.observe(Member.self) { @Sendable [weak self] change in
            // Any Member row write might be an isAway flip. Update
            // events do fire here; insert is new-member.
            switch change {
            case .insert, .update: break
            case .delete: return
            @unknown default: return
            }
            Task { @MainActor [weak self] in self?.reevaluatePending() }
        }
        // Run once up front so any votes that arrived before the
        // observer attached are counted (catch-up after reopen).
        reevaluatePending()
    }

    // `AnyCancellable`'s own deinit cancels when the property drops,
    // so no explicit deinit is needed here. An explicit one would
    // have to be MainActor-isolated, which the compiler rejects for
    // the nonisolated default.

    /// Scan every `.pending` `ApprovalRequest` and commit its terminal
    /// status if the tally says so. Filters push down to Lattice via
    /// `.where` so we don't materialise the full tables — a busy
    /// room can have thousands of decided approvals and hundreds of
    /// members, but the scan only touches the few pending rows.
    private func reevaluatePending() {
        // Quorum denominator: non-AFK members. `.count` resolves via
        // SQL aggregate, not a full row materialisation.
        let presentQuorum = lattice.objects(Member.self)
            .where { !$0.isAway }
            .count

        for req in lattice.objects(ApprovalRequest.self).where({ $0.status == .pending }) {
            // Iterate the request's votes relation lazily — count yes
            // / no without building an Array.
            var yes = 0
            var no = 0
            for vote in req.votes {
                switch vote.decision {
                case .approved: yes += 1
                case .denied:   no += 1
                case .pending:  break
                }
            }
            let result = ApprovalTally.evaluate(
                yes: yes, no: no, presentQuorum: presentQuorum)
            guard result.outcome != .pending else { continue }
            Log.line("vote-coord",
                     "request \(req.toolName) → \(result.outcome) (yes=\(yes) no=\(no) quorum=\(presentQuorum))")
            req.status = result.outcome
            req.decidedAt = Date()
            // decidedBy is intentionally left nil — there is no single
            // decider when the result is consensus. The card renderer
            // interprets nil decidedBy as "by quorum". Host-only
            // always-allow (the [A] key) still sets decidedBy = host.
        }
    }
}
