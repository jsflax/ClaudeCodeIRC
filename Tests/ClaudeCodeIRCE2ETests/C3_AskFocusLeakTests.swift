// Replaces scripts/smoke/c3-ask-focus-leak.sh — AskQuestion focus leak across
// sequential sub-questions. When Q2 mounts because OTHER peers reached quorum
// on Q1 (rather than the local user voting), Q1's focus state can leak onto
// Q2: discussion focus marker stays on the discussion line, the Q1 sentinel
// remains in the draft, etc.
//
// Setup: 3-pane (alice host + bob/carol peers). Alice asks claude for 2
// sequential single-select questions. Alice tabs into discussion on Q1 + types
// a sentinel; bob & carol vote to advance Q1 → Q2. Capture alice's pane
// 500ms after Q2 mounts and assert it's clean of Q1 state.

import Testing
import Foundation
import NCUITest
import NCUITestProtocol

@Suite("C3 — AskQuestion focus leak across sequential sub-questions", .serialized)
struct C3_AskFocusLeakTests {
    @Test(.timeLimit(.minutes(4)))
    func askFocusDoesNotLeakAcrossQuestions() async throws {
        let roomName = NCUIApplication.ccircRoomName(prefix: "c3")
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

        // Alice asks claude for 2 sub-questions in one tool call. Different
        // option counts (4 vs 2) catch the focusedRow-out-of-bounds variant.
        try await alice.triggerAskQuestion(prompt:
            "@claude use AskUserQuestion to ask me 2 questions in one tool call: " +
            "1. 'Pick a color' (single-select; options Red, Green, Blue, Purple). " +
            "2. 'Pick a side' (single-select; options Left, Right). " +
            "Output nothing else, no preamble, no commentary, no follow-up — just the tool call."
        )

        // Q1 mounts on every pane. Wait on the AskQuestion card header
        // ("claude is asking") which only appears when the card renders —
        // not on the prompt text, which is in scrollback as the user's
        // typed message before claude has even processed it.
        for app in [alice, bob, carol] {
            try await app.waitForRenderedText("claude is asking", timeout: 180)
        }

        // Alice tabs into Q1's discussion + types a sentinel.
        let sentinelQ1 = "alice-q1-sentinel-leak"
        _ = try await alice.sendRaw(.sendKey(.code(.tab, modifiers: [])))
        try await Task.sleep(nanoseconds: 400_000_000)
        _ = try await alice.sendRaw(.sendKeys(sentinelQ1))
        try await Task.sleep(nanoseconds: 400_000_000)

        // Bob + carol vote Down+Enter on Q1 (option 1 = Green) to advance.
        try await bob.voteOption(index: 1)
        try await carol.voteOption(index: 1)

        // Wait for Q2 to mount on alice. Match on a Q2-specific option-list
        // row (`] Left` is rendered as a checkbox option only inside the
        // AskQuestionCardView; the bare word "Left" might appear elsewhere,
        // but the `] Left` substring is unique to the Q2 ballot).
        do {
            try await alice.waitForRenderedText("] Left", timeout: 60)
        } catch {
            let raw = try alice.captureANSI()
            try raw.data(using: .utf8)?.write(to: URL(fileURLWithPath: "/tmp/c3-alice-fail.ansi"))
            try await alice.saveScreenshot(to: "/tmp/c3-alice-no-q2.png")
            throw error
        }

        // Settled-frame assertion: after 500ms the .task(id:) async reset
        // must have fired. Capture alice's pane (SGR-stripped, so substring
        // checks aren't broken by inline color resets) and check for leaks.
        try await Task.sleep(nanoseconds: 500_000_000)
        let q2Final = try alice.captureRenderedText()

        // (1) Discussion draft must NOT contain the Q1 sentinel.
        #expect(
            !q2Final.contains(sentinelQ1),
            "Q1 discussion draft '\(sentinelQ1)' leaked onto Q2 frame"
        )

        // (2) Q2 should be visible (sanity check). `] Left` is the rendered
        // first option of Q2's ballot — unique to Q2's card.
        #expect(q2Final.contains("] Left"), "Q2 ballot missing from frame")

        // (3) Focus marker '▸' must be present somewhere.
        #expect(q2Final.contains("▸"), "askFocusedRow leaked OOB — no focus marker visible")

        // (4) Focus marker must NOT be on the discussion line.
        // Discussion: "▸ <alice>" (the alice TextField row).
        // Option list: "▸ [ ] <option>" or "▸ [x] <option>".
        let discussionFocusLeak = q2Final.range(
            of: #"▸\s+<alice>"#,
            options: .regularExpression
        ) != nil
        #expect(
            !discussionFocusLeak,
            "askDiscussionFocused leaked — '▸ <alice>' present on Q2 frame"
        )
    }
}
