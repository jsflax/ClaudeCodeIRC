import Foundation
import Lattice

/// Pure tally helper — given the votes cast against a pending approval
/// request and the list of members currently present, compute the
/// outcome. Democratic rule (strict majority):
///
///   approved if yes > no AND (yes + no) > presentQuorum / 2
///   denied   if no ≥ yes AND (yes + no) > presentQuorum / 2
///   pending  otherwise
///
/// "More than half" collapses naturally:
/// - n = 1 → 1 vote (host alone OK)
/// - n = 2 → 2 votes (unanimous)
/// - n = 3 → 2 votes (majority)
/// - n = 4 → 3 votes (majority — no 2-2 tie passes)
/// - n = 5 → 3 votes
///
/// `presentQuorum` excludes AFK members — so a single non-AFK host
/// can still approve a request alone when no one else is around.
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
        // Strict majority: more than half must vote. For n=1,2 this
        // collapses to "all of them" (no host-alone-decides-for-room
        // bug); for n≥3 it's a normal majority. Even-n ties
        // (e.g. 2 yes / 2 no in a 4-person room) stay `.pending`
        // until the tiebreaker arrives instead of auto-passing.
        let threshold = presentQuorum / 2 + 1
        guard cast >= threshold else {
            return Result(yesCount: yes, noCount: no, presentQuorum: presentQuorum, outcome: .pending)
        }
        let outcome: ApprovalStatus = yes > no ? .approved : .denied
        return Result(yesCount: yes, noCount: no, presentQuorum: presentQuorum, outcome: outcome)
    }
}
