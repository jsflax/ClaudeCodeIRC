import Foundation
import Lattice

/// Pure tally helper — given the votes cast against a pending approval
/// request and the list of members currently present, compute the
/// outcome. Democratic rule:
///
///   approved if yes > no AND (yes + no) ≥ ceil(presentQuorum / 2)
///   denied   if no ≥ yes AND (yes + no) ≥ ceil(presentQuorum / 2)
///   pending  otherwise
///
/// `presentQuorum` excludes AFK members — so a single non-AFK host
/// can approve a request with one `Y` even if other members are idle.
///
/// The tally is driven by `ApprovalVoteCoordinator` (host side only)
/// which observes `ApprovalVote` inserts + `Member.isAway` flips and
/// writes the terminal `request.status` once the outcome flips from
/// `.pending`. Peers only observe; they never write status.
public enum ApprovalTally {
    public struct Result: Equatable, Sendable {
        public let yesCount: Int
        public let noCount: Int
        public let presentQuorum: Int
        public let outcome: ApprovalStatus

        public init(yesCount: Int, noCount: Int, presentQuorum: Int, outcome: ApprovalStatus) {
            self.yesCount = yesCount
            self.noCount = noCount
            self.presentQuorum = presentQuorum
            self.outcome = outcome
        }
    }

    /// Pure evaluation — no Lattice reads, easy to test. Callers that
    /// need to tally live rows read `yes` / `no` / `presentQuorum`
    /// from their Lattice with `.where` predicates and hand them here.
    public static func evaluate(
        yes: Int,
        no: Int,
        presentQuorum: Int
    ) -> Result {
        precondition(yes >= 0 && no >= 0 && presentQuorum >= 0)
        let cast = yes + no
        let threshold = (presentQuorum + 1) / 2 // ceil(n / 2)
        guard cast >= threshold else {
            return Result(yesCount: yes, noCount: no, presentQuorum: presentQuorum, outcome: .pending)
        }
        let outcome: ApprovalStatus = yes > no ? .approved : .denied
        return Result(yesCount: yes, noCount: no, presentQuorum: presentQuorum, outcome: outcome)
    }
}
