import Foundation
import Testing
import ClaudeCodeIRCCore

/// Pure-math tests for `ApprovalTally.evaluate(yes:no:presentQuorum:)`.
/// Democratic rule (strict majority — `n / 2 + 1` must vote):
///   approved if yes > no AND (yes + no) > presentQuorum / 2
///   denied   if no ≥ yes AND (yes + no) > presentQuorum / 2
///   pending  otherwise
///
/// "More than half" collapses to:
/// - n = 1 → 1 vote (host alone OK)
/// - n = 2 → 2 votes (unanimous)
/// - n = 3 → 2 votes (majority)
/// - n = 4 → 3 votes (majority — no 2-2 tie passes)
/// - n = 5 → 3 votes
@Suite struct ApprovalTallyTests {

    // MARK: - Pending (below threshold)

    @Test func pendingWithNoVotes() {
        let r = ApprovalTally.evaluate(yes: 0, no: 0, presentQuorum: 5)
        #expect(r.outcome == .pending)
    }

    @Test func pendingBelowThreshold() {
        // 4 present → threshold = 4/2 + 1 = 3. One vote isn't enough.
        let r = ApprovalTally.evaluate(yes: 1, no: 0, presentQuorum: 4)
        #expect(r.outcome == .pending)
    }

    @Test func twoPresentOneYesStaysPending() {
        // 2 present → threshold = 2/2 + 1 = 2 (unanimous). One Y is
        // not enough — host can't decide alone for a 2-person room.
        let r = ApprovalTally.evaluate(yes: 1, no: 0, presentQuorum: 2)
        #expect(r.outcome == .pending)
    }

    @Test func fourPresentTwoYesNoVotesStaysPending() {
        // 4 present → threshold 3. Only 2 votes cast → pending.
        let r = ApprovalTally.evaluate(yes: 2, no: 0, presentQuorum: 4)
        #expect(r.outcome == .pending)
    }

    @Test func evenQuorumTieStaysPending() {
        // 4 present → threshold 3. With 2 yes + 2 no the threshold is
        // met, but yes > no is false AND no ≥ yes is true with cast
        // (4) > 2 → denied. Make sure the *threshold* path still
        // works: 2 yes + 1 no = 3 cast, threshold 3 → decide; yes > no
        // → approved.
        #expect(ApprovalTally.evaluate(yes: 2, no: 1, presentQuorum: 4).outcome == .approved)
        #expect(ApprovalTally.evaluate(yes: 2, no: 2, presentQuorum: 4).outcome == .denied)
    }

    // MARK: - Approved

    @Test func singleHostApprovesWithOneYes() {
        // Quorum=1 (host alone). Threshold = 1/2 + 1 = 1. One Y is
        // enough — the only voter spoke.
        let r = ApprovalTally.evaluate(yes: 1, no: 0, presentQuorum: 1)
        #expect(r.outcome == .approved)
        #expect(r.yesCount == 1)
        #expect(r.noCount == 0)
    }

    @Test func twoPresentUnanimousYesApproves() {
        // Threshold 2 = both must vote. 2 yes / 0 no → approved.
        let r = ApprovalTally.evaluate(yes: 2, no: 0, presentQuorum: 2)
        #expect(r.outcome == .approved)
    }

    @Test func fourPresentMajorityYesApproves() {
        // Threshold = 4/2 + 1 = 3. 3 yes + 0 no passes.
        let r = ApprovalTally.evaluate(yes: 3, no: 0, presentQuorum: 4)
        #expect(r.outcome == .approved)
    }

    @Test func oddQuorumRequiresMajorityCast() {
        // 5 present → threshold = 5/2 + 1 = 3.
        #expect(ApprovalTally.evaluate(yes: 2, no: 0, presentQuorum: 5).outcome == .pending)
        #expect(ApprovalTally.evaluate(yes: 3, no: 0, presentQuorum: 5).outcome == .approved)
    }

    // MARK: - Denied

    @Test func twoPresentTieDenies() {
        // 1 yes + 1 no = 2 cast, threshold 2 → decide. yes > no false
        // → no ≥ yes true → denied.
        let r = ApprovalTally.evaluate(yes: 1, no: 1, presentQuorum: 2)
        #expect(r.outcome == .denied)
    }

    @Test func majorityNoDenies() {
        // 3 present → threshold 2. 1 yes + 2 no = 3 cast, decide.
        let r = ApprovalTally.evaluate(yes: 1, no: 2, presentQuorum: 3)
        #expect(r.outcome == .denied)
    }

    // MARK: - Zero quorum edge case

    @Test func zeroQuorumDegenerateBehaviour() {
        // No non-AFK members. Threshold = 0/2 + 1 = 1. Any single
        // cast vote crosses threshold; pure tally then applies
        // yes > no.
        let none = ApprovalTally.evaluate(yes: 0, no: 0, presentQuorum: 0)
        #expect(none.outcome == .pending)
        let aye = ApprovalTally.evaluate(yes: 1, no: 0, presentQuorum: 0)
        #expect(aye.outcome == .approved)
    }

    // MARK: - Result payload

    @Test func resultReflectsInputs() {
        // 5 present → threshold 3. 3 yes + 1 no = 4 cast, yes > no
        // → approved.
        let r = ApprovalTally.evaluate(yes: 3, no: 1, presentQuorum: 5)
        #expect(r.yesCount == 3)
        #expect(r.noCount == 1)
        #expect(r.presentQuorum == 5)
        #expect(r.outcome == .approved)
    }
}
