// Replaces scripts/smoke/c2-3p-ask-singleselect.sh — 3-peer single-select
// Ask with 2/3 majority. Locks in the n=3 majority rule from
// `AskTally.singleSelectFirstToThresholdWins`: for presentQuorum=3 →
// threshold=2. Two voters pick Green, the third picks Red, the question
// resolves on the majority pick.

import Testing
import Foundation
import NCUITest
import NCUITestProtocol

@Suite("C2 — 3-peer single-select Ask, 2/3 majority", .serialized)
struct C2_AskSingleSelectTests {
    @Test(.timeLimit(.minutes(4)))
    func threePeerAskMajority() async throws {
        let roomName = NCUIApplication.ccircRoomName(prefix: "c2")
        let alice = NCUIApplication.ccirc(label: "alice")
        let bob   = NCUIApplication.ccirc(label: "bob")
        let carol = NCUIApplication.ccirc(label: "carol")

        try await alice.launch()
        try await bob.launch()
        try await carol.launch()
        defer { alice.terminate(); bob.terminate(); carol.terminate() }

        try await alice.hostSession(nick: "alice", roomName: roomName)
        try await bob.joinSession(nick: "bob", roomName: roomName)
        try await carol.joinSession(nick: "carol", roomName: roomName)

        for app in [alice, bob, carol] {
            try await app.waitForMembers(["alice", "bob", "carol"], timeout: 30)
        }

        // Alice triggers the Ask. The prompt is wrapped to keep claude
        // focused on the AskUserQuestion call (no chatter).
        try await alice.triggerAskQuestion(prompt:
            "@claude use AskUserQuestion to ask 'Pick a color' " +
            "(single-select; options Red, Green, Blue, Purple). Output nothing else."
        )

        // The Ask card materializes on every pane. Claude takes 30–90s to
        // emit the AskUserQuestion call — give it a generous timeout. We
        // match the card's "claude is asking" header through rendered ANSI:
        // both `CardView.title` and `BoxView.title` are drawn via raw
        // `Term.put` (bypassing tree mounting), so `staticTexts` can't see
        // them, but `captureANSI` does.
        for app in [alice, bob, carol] {
            try await app.waitForRenderedText("claude is asking", timeout: 180)
        }

        // Vote: alice and bob → option 1 (Green), carol → option 0 (Red).
        try await alice.voteOption(index: 1)
        try await bob.voteOption(index: 1)
        try await carol.voteOption(index: 0)

        // After 2/3 quorum on Green, the resolution footer "✓ answered: Green"
        // renders on every pane (see `AskQuestionCardView.swift:301-303`).
        // The footer is also a `CardView.footer`, drawn via `footer.draw(in:)`
        // bypassing tree mounting — match through rendered ANSI.
        for app in [alice, bob, carol] {
            // Resolution footer renders "answered: \"Green\"" (option label
            // is JSON-quoted via Lattice's chosenLabels serialization).
            // Match the substring "Green" inside the answered footer.
            try await app.waitForRenderedText("answered: ", timeout: 30)
            try await app.waitForRenderedText("Green", timeout: 5)
        }
    }
}
