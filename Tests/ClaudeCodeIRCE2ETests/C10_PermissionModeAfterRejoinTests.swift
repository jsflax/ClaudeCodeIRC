// Reproduces the user-reported bug: after Claude exits plan mode (the
// plan card resolves with "Yes — auto mode"), Shift-Tab can no longer
// cycle the permission mode — the status bar gets stuck.
//
// Flow under test:
//   1. alice hosts a fresh room. Mode starts at .default (no marker).
//   2. Shift-Tab twice cycles default → accept-edits → plan. The status
//      bar settles on "⏸ plan".
//   3. alice asks @claude to do something. In plan mode claude can't
//      Edit/Write/Bash, so it must call ExitPlanMode to request
//      permission. The plan card materialises.
//   4. alice votes index 0 ("Yes — auto mode"). The shim's
//      `setSessionMode(.auto)` runs and writes the new mode through
//      the host lattice — status bar advances to "⏵⏵ auto".
//   5. alice presses Shift-Tab. `auto.next() == .default`, so the
//      status bar SHOULD drop the marker entirely.
//
// Pre-fix, step 5 timed out: the shim's `setSessionMode` wrapped its
// single property write in `beginTransaction()/commitTransaction()`
// while the cycler used a bare write — and the cycler held a stale
// `room.session` Swift wrapper. Subsequent bare writes through the
// stale wrapper didn't propagate.

import Testing
import Foundation
import NCUITest
import NCUITestProtocol

@Suite("C10 — permission mode cycler after ExitPlanMode", .serialized)
struct PermissionModeAfterExitPlanTests {
    @Test(.timeLimit(.minutes(4)))
    func shiftTabCyclesAfterExitPlanMode() async throws {
        let roomName = NCUIApplication.ccircRoomName(prefix: "c10")
        let alice = NCUIApplication.ccirc(label: "alice-c10")

        try await alice.launch()
        defer { alice.terminate() }
        try await alice.waitForLobby()
        try await alice.hostSession(nick: "alice", roomName: roomName)

        // Cycle default → accept-edits → plan to put claude into plan
        // mode for its next turn.
        _ = try await alice.sendRaw(.sendKey(.code(.tab, modifiers: .shift)))
        try await alice.waitForRenderedText("⏵⏵ accept-edits", timeout: 5)
        _ = try await alice.sendRaw(.sendKey(.code(.tab, modifiers: .shift)))
        try await alice.waitForRenderedText("⏸ plan", timeout: 3)

        // Ask claude to do something that requires touching the
        // filesystem. In plan mode claude must call ExitPlanMode first
        // — that's what surfaces the plan card. The trailing
        // instruction nudges claude away from chatter so the card
        // appears quickly.
        try await alice.triggerAskQuestion(prompt:
            "@claude write the single word 'hi' to /tmp/ccirc-c10-probe.txt. " +
            "Use ExitPlanMode first. Output nothing else."
        )

        // Plan card materialises. claude can take 30–90s to emit the
        // ExitPlanMode call — give it the same generous window C2 uses.
        try await alice.waitForRenderedText("Yes — auto mode", timeout: 180)

        // Vote "Yes — auto mode" (index 0). The shim's
        // setSessionMode(.auto) fires.
        try await alice.voteOption(index: 0)

        // Status bar should reflect the new mode.
        try await alice.waitForRenderedText("⏵⏵ auto", timeout: 10)

        // The actual repro: cycle auto → default. Pre-fix, this
        // never lands.
        _ = try await alice.sendRaw(.sendKey(.code(.tab, modifiers: .shift)))

        // Wait for the marker to vanish (default mode renders no
        // marker). Polling for absence — same shape as C9's final
        // assertion.
        let deadline = Date().addingTimeInterval(5)
        var settled = false
        while Date() < deadline {
            let snap = try alice.captureRenderedText()
            if !snap.contains("⏵⏵ auto") && !snap.contains("⏸ plan")
               && !snap.contains("accept-edits") {
                settled = true
                break
            }
            try await Task.sleep(nanoseconds: 150_000_000)
        }
        #expect(settled,
            "after ExitPlanMode → yes-auto → Shift-Tab, the status bar should drop the mode marker (auto.next == default)")
    }
}
