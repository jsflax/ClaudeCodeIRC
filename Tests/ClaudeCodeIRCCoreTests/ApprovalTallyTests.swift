import Foundation
import Testing
import ClaudeCodeIRCCore

/// Pure-math tests for `ApprovalTally.evaluate(yes:no:presentQuorum:)`.
/// Democratic rule (plan):
///   approved if yes > no AND (yes + no) ≥ ceil(presentQuorum / 2)
///   denied   if no ≥ yes AND (yes + no) ≥ ceil(presentQuorum / 2)
///   pending  otherwise
@Suite struct ApprovalTallyTests {

    // MARK: - Pending (below threshold)

    @Test func pendingWithNoVotes() {
        let r = ApprovalTally.evaluate(yes: 0, no: 0, presentQuorum: 5)
        #expect(r.outcome == .pending)
    }

    @Test func pendingBelowThreshold() {
        // 4 present → threshold ceil(4/2) = 2. One vote isn't enough.
        let r = ApprovalTally.evaluate(yes: 1, no: 0, presentQuorum: 4)
        #expect(r.outcome == .pending)
    }

    // MARK: - Approved

    @Test func singleHostApprovesWithOneYes() {
        // Quorum=1 (host alone, no other non-AFK). Threshold = ceil(1/2) = 1.
        // One Y is enough.
        let r = ApprovalTally.evaluate(yes: 1, no: 0, presentQuorum: 1)
        #expect(r.outcome == .approved)
        #expect(r.yesCount == 1)
        #expect(r.noCount == 0)
    }

    @Test func twoPresentNeedsOneVoteAndYesWins() {
        // Threshold = ceil(2/2) = 1. One Y vote approves.
        let r = ApprovalTally.evaluate(yes: 1, no: 0, presentQuorum: 2)
        #expect(r.outcome == .approved)
    }

    @Test func fourPresentNeedsTwoAndYesWins() {
        // Threshold = ceil(4/2) = 2. 2 yes vs 0 no passes threshold
        // and yes > no → approved.
        let r = ApprovalTally.evaluate(yes: 2, no: 0, presentQuorum: 4)
        #expect(r.outcome == .approved)
    }

    @Test func oddQuorumRequiresCeilingMajorityCast() {
        // 5 present → threshold ceil(5/2) = 3 votes must be cast.
        // 2 yes + 0 no = 2 cast — below threshold, still pending.
        #expect(ApprovalTally.evaluate(yes: 2, no: 0, presentQuorum: 5).outcome == .pending)
        // 3 yes covers threshold — approved.
        #expect(ApprovalTally.evaluate(yes: 3, no: 0, presentQuorum: 5).outcome == .approved)
    }

    // MARK: - Denied

    @Test func tieGoesToDenied() {
        // yes == no → "no ≥ yes" → denied. Cautious default: if
        // we aren't a majority for YES, the request fails.
        let r = ApprovalTally.evaluate(yes: 1, no: 1, presentQuorum: 2)
        #expect(r.outcome == .denied)
    }

    @Test func majorityNoDenies() {
        let r = ApprovalTally.evaluate(yes: 1, no: 2, presentQuorum: 3)
        #expect(r.outcome == .denied)
    }

    // MARK: - Zero quorum edge case

    @Test func zeroQuorumApprovesTrivially() {
        // Degenerate input (no non-AFK members). Threshold = 0, so
        // any cast state is "quorum reached". A yes wins; with zero
        // votes and zero threshold the outcome is approved by the
        // yes > no rule (0 > 0 false → denied). Documents behaviour.
        let none = ApprovalTally.evaluate(yes: 0, no: 0, presentQuorum: 0)
        #expect(none.outcome == .denied)
        let aye = ApprovalTally.evaluate(yes: 1, no: 0, presentQuorum: 0)
        #expect(aye.outcome == .approved)
    }

    // MARK: - Result payload

    @Test func resultReflectsInputs() {
        let r = ApprovalTally.evaluate(yes: 3, no: 1, presentQuorum: 5)
        #expect(r.yesCount == 3)
        #expect(r.noCount == 1)
        #expect(r.presentQuorum == 5)
        #expect(r.outcome == .approved)
    }
}
