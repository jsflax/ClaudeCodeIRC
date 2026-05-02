// Replaces scripts/smoke/c4-stuck-thinking.sh — orphan in-flight cleanup on
// host process crash + reopen. When the host is hard-killed mid-streaming
// Turn or pending Ask, the rows persist on disk in their pre-kill state. On
// reopen, `RoomsModel.terminateOrphanedInFlightRows` flips Turn → .errored,
// AskQuestion → .cancelled, ToolEvent → .errored, ApprovalRequest → .denied
// inside a single transaction.
//
// Solo case (alice only) — the cleanup is host-side; peers don't do anything
// special on rejoin.
//
// Note: bash C4 also asserts on lattice state directly (sqlite3 queries
// against AskQuestion / Turn). This swift port asserts only on the UI
// signal — the rendered `✗ cancelled` footer — because Lattice's Cxx
// read-only path is unreliable against a freshly-killed writer's WAL state.
// The UI assertion is sufficient: if `terminateOrphanedInFlightRows` didn't
// run, the AskQuestion would still be .pending and would render as a live
// ballot, not the cancelled footer.

import Testing
import Foundation
import NCUITest
import NCUITestProtocol

@Suite("C4 — orphan cleanup on host crash + reopen", .serialized)
struct C4_StuckThinkingTests {
    @Test(.timeLimit(.minutes(5)))
    func orphanRowsCleanedOnReopen() async throws {
        let roomName = NCUIApplication.ccircRoomName(prefix: "c4")
        let alice = NCUIApplication.ccirc(label: "alice")

        try await alice.launch()
        defer { alice.terminate() }

        try await alice.hostSession(nick: "alice", roomName: roomName)

        // Trigger an Ask that will sit pending during the kill.
        try await alice.triggerAskQuestion(prompt:
            "@claude use AskUserQuestion to ask 'Pick a color' " +
            "(single-select; options Red, Green, Blue, Purple). Output nothing else."
        )

        // Wait until the Ask card is up — we need both the streaming Turn
        // AND the pending AskQuestion as orphans before the kill.
        try await alice.waitForRenderedText("claude is asking", timeout: 180)

        // Resolve the room code while alice is still running — we'll use it
        // for /reopen after the relaunch.
        guard let roomCode = alice.resolvedRoomCode() else {
            Issue.record("no room lattice resolved before kill")
            return
        }

        // Hard-kill alice (simulates Ctrl+C / crash). terminate() kills the
        // tmux session and reaps the `claude -p` orphan child.
        alice.terminate()
        try await Task.sleep(nanoseconds: 2_000_000_000)

        // Relaunch alice with the SAME data dir (launchEnvironment is
        // preserved across `relaunch()` so CCIRC_DATA_DIR points at the
        // same lattice file). Then /reopen <code> triggers
        // `RoomsModel.terminateOrphanedInFlightRows`.
        try await alice.relaunch()
        try await alice.setNick("alice")  // first-run-overlay safety
        _ = try await alice.sendRaw(.sendKeys("/reopen \(roomCode)\n"))

        // The cancelled footer is the user-visible signal that the orphan
        // cleanup transaction ran. If the cleanup didn't run, the Ask
        // would still be .pending and would render as a live ballot.
        try await alice.waitForRenderedText("✗ cancelled", timeout: 30)

        // The "thinking" indicator from the dead Turn must NOT be rendered.
        // (After cleanup, the Turn is .errored, not .streaming.)
        let snapshot = try alice.captureRenderedText()
        #expect(
            !snapshot.lowercased().contains("thinking"),
            "live thinking indicator visible — orphan Turn wasn't cleaned"
        )
    }
}
