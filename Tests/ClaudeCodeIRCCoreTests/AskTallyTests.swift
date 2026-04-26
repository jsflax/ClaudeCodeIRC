import Foundation
import Testing
import ClaudeCodeIRCCore

/// Pure-math tests for `AskTally.evaluate(ballots:presentQuorum:multiSelect:)`.
@Suite struct AskTallyTests {

    private func ballot(_ labels: [String], _ secondsAfter: TimeInterval = 0) -> AskTally.Ballot {
        AskTally.Ballot(labels: labels, castAt: Date(timeIntervalSince1970: 1_000_000 + secondsAfter))
    }

    // MARK: - Single-select

    @Test func singleSelectPendingWithNoBallots() {
        let r = AskTally.evaluate(ballots: [], presentQuorum: 3, multiSelect: false)
        #expect(r.complete == false)
        #expect(r.chosenLabels.isEmpty)
        #expect(r.ballotCount == 0)
    }

    @Test func singleSelectPendingBelowThreshold() {
        // 5 present → threshold = 3. One vote not enough.
        let r = AskTally.evaluate(
            ballots: [ballot(["a"])],
            presentQuorum: 5,
            multiSelect: false)
        #expect(r.complete == false)
        #expect(r.votesByLabel["a"] == 1)
    }

    @Test func singleSelectFirstToThresholdWins() {
        // 3 present → threshold = 2. Label "a" gets 2; "b" gets 1.
        let r = AskTally.evaluate(
            ballots: [
                ballot(["a"], 0),
                ballot(["b"], 1),
                ballot(["a"], 2),
            ],
            presentQuorum: 3,
            multiSelect: false)
        #expect(r.complete == true)
        #expect(r.chosenLabels == ["a"])
    }

    @Test func singleSelectQuorumOneSelfAnswers() {
        // Quorum=1 → threshold=1. One ballot, one label, immediate win.
        let r = AskTally.evaluate(
            ballots: [ballot(["only"])],
            presentQuorum: 1,
            multiSelect: false)
        #expect(r.complete == true)
        #expect(r.chosenLabels == ["only"])
    }

    @Test func singleSelectTieBrokenByCastAt() {
        // 4 present → threshold = 2. "a" hits 2 at t=2, "b" hits 2 at t=3.
        // Earliest threshold-crossing wins → "a".
        let r = AskTally.evaluate(
            ballots: [
                ballot(["a"], 0),
                ballot(["b"], 1),
                ballot(["a"], 2),
                ballot(["b"], 3),
            ],
            presentQuorum: 4,
            multiSelect: false)
        #expect(r.complete == true)
        #expect(r.chosenLabels == ["a"])
    }

    @Test func singleSelectLateTieDoesNotDethrone() {
        // "a" hits threshold first at t=1; "b" catches up at t=2 to
        // tie counts. Tally still picks "a" because it crossed first.
        let r = AskTally.evaluate(
            ballots: [
                ballot(["a"], 0),
                ballot(["a"], 1),
                ballot(["b"], 2),
                ballot(["b"], 3),
            ],
            presentQuorum: 4,
            multiSelect: false)
        #expect(r.complete == true)
        #expect(r.chosenLabels == ["a"])
    }

    @Test func singleSelectZeroQuorumTriviallyComplete() {
        // Degenerate: zero present, no ballots. Pending-stays-pending
        // (no votes → no labels can win).
        let r = AskTally.evaluate(ballots: [], presentQuorum: 0, multiSelect: false)
        #expect(r.complete == false)
    }

    // MARK: - Multi-select

    @Test func multiSelectPendingUntilAllBallotsCommitted() {
        // 3 present, 2 ballots in. Even if "a" already has 2 votes
        // (≥ threshold = 2), tally must wait for the third ballot.
        let r = AskTally.evaluate(
            ballots: [ballot(["a"]), ballot(["a"])],
            presentQuorum: 3,
            multiSelect: true)
        #expect(r.complete == false)
        #expect(r.chosenLabels.isEmpty)
        #expect(r.ballotCount == 2)
    }

    @Test func multiSelectAllBallotsInPicksAllAboveThreshold() {
        // 3 present → threshold = 2. "a": 3, "b": 2, "c": 1.
        // a + b chosen, c not.
        let r = AskTally.evaluate(
            ballots: [
                ballot(["a", "b"]),
                ballot(["a", "b"]),
                ballot(["a", "c"]),
            ],
            presentQuorum: 3,
            multiSelect: true)
        #expect(r.complete == true)
        #expect(Set(r.chosenLabels) == Set(["a", "b"]))
    }

    @Test func multiSelectAllAbstainAnswersWithEmptyResult() {
        // Everyone commits an empty ballot — question resolves with
        // chosenLabels = []. Lets the shim reply
        // "(no options selected)".
        let r = AskTally.evaluate(
            ballots: [ballot([]), ballot([]), ballot([])],
            presentQuorum: 3,
            multiSelect: true)
        #expect(r.complete == true)
        #expect(r.chosenLabels.isEmpty)
    }

    @Test func multiSelectDuplicatesWithinBallotDontDoubleCount() {
        // Defensive: if a ballot lists "a" twice (shouldn't happen,
        // but UI bugs are real), tally still counts it as +1.
        let r = AskTally.evaluate(
            ballots: [ballot(["a", "a"])],
            presentQuorum: 1,
            multiSelect: true)
        #expect(r.complete == true)
        #expect(r.votesByLabel["a"] == 1)
        #expect(r.chosenLabels == ["a"])
    }

    @Test func multiSelectStableSortByCountThenLabel() {
        // 3 present, threshold=2. "b": 3, "a": 2, "c": 2. Order should
        // be ["b", "a", "c"] — count desc, then label asc.
        let r = AskTally.evaluate(
            ballots: [
                ballot(["a", "b", "c"]),
                ballot(["a", "b", "c"]),
                ballot(["b"]),
            ],
            presentQuorum: 3,
            multiSelect: true)
        #expect(r.complete == true)
        #expect(r.chosenLabels == ["b", "a", "c"])
    }
}
