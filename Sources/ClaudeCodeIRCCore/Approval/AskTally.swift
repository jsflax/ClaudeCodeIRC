import Foundation
import Lattice

/// Pure tally helper for `AskQuestion` votes. The shape is deliberately
/// close to `ApprovalTally` but the rule diverges in two ways:
///
/// 1. **Multiple labels.** Approvals are binary (yes/no); questions
///    fan out to N labels and count each independently.
/// 2. **Termination differs by mode.**
///    - Single-select: as soon as any label crosses
///      `threshold = presentQuorum / 2 + 1` (strict majority — for
///      n ≤ 2 that's unanimous, for n ≥ 3 simple majority), that
///      label wins. Ties at threshold broken by earliest `castAt`
///      among tied labels' threshold-crossing ballots.
///    - Multi-select: completes only when every present voter has
///      committed a ballot (`ballotCount == presentQuorum`). Winners
///      = every label whose count ≥ threshold (possibly empty if
///      everyone abstained). No "first to threshold" early-exit —
///      a label that has 2 votes today could pick up a 3rd before
///      everyone's in.
///
/// `AskVoteCoordinator` observes `AskVote` writes + `Member.isAway`
/// flips, runs `evaluate`, and writes the terminal
/// `question.status = .answered` + `chosenLabels` once `complete`
/// flips true. Idempotent — every client runs one, the
/// `if status == .pending` guard at the write site keeps concurrent
/// runs from stomping each other.
public enum AskTally {
    /// One voter's ballot, reduced to the bits the tally needs.
    /// Order within `labels` doesn't matter; duplicates within a
    /// single ballot are de-duped (a voter can only contribute +1
    /// per label even if they list it twice).
    public struct Ballot: Equatable, Sendable {
        public let labels: [String]
        public let castAt: Date
        public init(labels: [String], castAt: Date) {
            self.labels = labels
            self.castAt = castAt
        }
    }

    public struct Result: Equatable, Sendable {
        public let votesByLabel: [String: Int]
        public let presentQuorum: Int
        public let ballotCount: Int
        /// Empty while pending. For single-select holds at most one
        /// label; for multi-select holds every label ≥ threshold.
        public let chosenLabels: [String]
        public let complete: Bool

        public init(
            votesByLabel: [String: Int],
            presentQuorum: Int,
            ballotCount: Int,
            chosenLabels: [String],
            complete: Bool
        ) {
            self.votesByLabel = votesByLabel
            self.presentQuorum = presentQuorum
            self.ballotCount = ballotCount
            self.chosenLabels = chosenLabels
            self.complete = complete
        }
    }

    public static func evaluate(
        ballots: [Ballot],
        presentQuorum: Int,
        multiSelect: Bool
    ) -> Result {
        precondition(presentQuorum >= 0)
        // Strict majority — see ApprovalTally for the rationale.
        // For n=1,2 this is unanimous; for n≥3 it's simple majority.
        // Ties stay `.pending`.
        let threshold = presentQuorum / 2 + 1

        // Tally — dedupe within each ballot so listing the same label
        // twice can't double-count.
        var counts: [String: Int] = [:]
        for ballot in ballots {
            for label in Set(ballot.labels) {
                counts[label, default: 0] += 1
            }
        }

        let ballotCount = ballots.count

        if multiSelect {
            // Multi-select: terminate only when every present voter
            // has weighed in. Winners = all labels ≥ threshold,
            // sorted by descending count then label for stable
            // ordering across re-runs.
            guard ballotCount >= presentQuorum, presentQuorum > 0 else {
                return Result(
                    votesByLabel: counts,
                    presentQuorum: presentQuorum,
                    ballotCount: ballotCount,
                    chosenLabels: [],
                    complete: false)
            }
            let winners = counts
                .filter { $0.value >= threshold }
                .sorted { lhs, rhs in
                    if lhs.value != rhs.value { return lhs.value > rhs.value }
                    return lhs.key < rhs.key
                }
                .map(\.key)
            return Result(
                votesByLabel: counts,
                presentQuorum: presentQuorum,
                ballotCount: ballotCount,
                chosenLabels: winners,
                complete: true)
        }

        // Single-select: first label to threshold wins. Threshold
        // tie-break uses the earliest `castAt` among each tied
        // label's threshold-crossing ballots — i.e. the moment that
        // label's `threshold`-th vote landed.
        guard !counts.isEmpty else {
            return Result(
                votesByLabel: counts,
                presentQuorum: presentQuorum,
                ballotCount: ballotCount,
                chosenLabels: [],
                complete: false)
        }

        // For single-select we treat the first label in each ballot
        // as the chosen one (single-select ballots always carry
        // exactly one entry; defensive against malformed inputs).
        let topCount = counts.values.max() ?? 0
        guard topCount >= threshold, presentQuorum > 0 else {
            return Result(
                votesByLabel: counts,
                presentQuorum: presentQuorum,
                ballotCount: ballotCount,
                chosenLabels: [],
                complete: false)
        }

        let topLabels = counts.filter { $0.value == topCount }.map(\.key)
        if topLabels.count == 1 {
            return Result(
                votesByLabel: counts,
                presentQuorum: presentQuorum,
                ballotCount: ballotCount,
                chosenLabels: topLabels,
                complete: true)
        }

        // Tie at the top — break on the moment each tied label
        // accumulated its `threshold`-th vote. Iterate ballots in
        // chronological order and record when each label hits
        // threshold; whoever got there first wins.
        var runningCount: [String: Int] = [:]
        var thresholdAt: [String: Date] = [:]
        let sorted = ballots.sorted { $0.castAt < $1.castAt }
        let topSet = Set(topLabels)
        for ballot in sorted {
            for label in Set(ballot.labels) where topSet.contains(label) {
                runningCount[label, default: 0] += 1
                if runningCount[label] == threshold, thresholdAt[label] == nil {
                    thresholdAt[label] = ballot.castAt
                }
            }
        }
        let earliest = thresholdAt.min { lhs, rhs in
            if lhs.value != rhs.value { return lhs.value < rhs.value }
            return lhs.key < rhs.key // last-resort lexical
        }
        let winner = earliest?.key ?? topLabels.sorted().first!
        return Result(
            votesByLabel: counts,
            presentQuorum: presentQuorum,
            ballotCount: ballotCount,
            chosenLabels: [winner],
            complete: true)
    }
}
