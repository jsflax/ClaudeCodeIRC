import Testing
import Foundation
import NCUITest
import NCUITestProtocol

/// Verifies the host-side permission-mode cycler (Shift-Tab in the
/// active room). Cycle order, defined in `PermissionMode.next()`:
///
///   default → accept-edits → plan → auto → default
///
/// `bypassPermissions` is deliberately excluded from the cycle.
///
/// The test walks the full cycle to catch regressions where:
/// 1. The Shift-Tab keybinding stops firing (e.g. focus routing
///    consumes the event before WorkspaceView's `.onKeyPress(KEY_BTAB)`).
/// 2. A given enum case's `next()` arm is broken or `bypassPermissions`
///    leaks into the cycle.
/// 3. `Session.permissionMode` writes don't reach the status-bar
///    rendering path (the @Observable→render pipeline that motivated
///    the C8 sidebar-refresh test in this same suite).
///
/// Stays at the visible-UI level — no real Claude invocation, no
/// network. The cycler operates on `Session.permissionMode` directly,
/// which is what `ApprovalMcpShim.handleExitPlanMode` writes when the
/// "yes-auto" plan-vote path resolves; so this test also covers the
/// post-plan path the user reported ("after claude exited plan mode,
/// i could cycle the different claude modes").
@Suite("ClaudeCodeIRC e2e — permission mode cycle", .serialized)
struct PermissionModeCycleTests {
    @Test("Shift-Tab cycles host permission mode through default → accept-edits → plan → auto → default")
    func shiftTabCyclesAllModes() async throws {
        let alice = NCUIApplication.ccirc(label: "alice-mode-cycle")
        try await alice.launch()
        defer { alice.terminate() }

        try await alice.waitForLobby()
        try await alice.hostSession(nick: "alice", roomName: "modetest", visibility: .lan)

        // Default mode: no mode marker rendered (modePrefix returns "" and
        // the suffix branch is gated on `mode != .default`). Just sanity-
        // check there's no `accept-edits`/`plan`/`auto` token yet.
        let pre = try alice.captureRenderedText()
        #expect(!pre.contains("accept-edits"),
            "default mode should not show accept-edits in status bar")
        #expect(!pre.contains("⏸ plan"),
            "default mode should not show plan glyph")
        #expect(!pre.contains("⏵⏵ auto"),
            "default mode should not show auto glyph")

        // Cycle: default → accept-edits.
        _ = try await alice.sendRaw(.sendKey(.code(.tab, modifiers: .shift)))
        try await alice.waitForRenderedText("⏵⏵ accept-edits", timeout: 3)

        // Cycle: accept-edits → plan. Plan uses the pause glyph; match
        // on the full prefix to avoid false positives from the word
        // "plan" appearing in any other UI strings.
        _ = try await alice.sendRaw(.sendKey(.code(.tab, modifiers: .shift)))
        try await alice.waitForRenderedText("⏸ plan", timeout: 3)

        // Cycle: plan → auto. This is the transition Claude's
        // `ExitPlanMode` (yes-auto path) writes via
        // `setSessionMode(.auto, …)`. Verifying it via Shift-Tab here
        // exercises the same render path the user observed.
        _ = try await alice.sendRaw(.sendKey(.code(.tab, modifiers: .shift)))
        try await alice.waitForRenderedText("⏵⏵ auto", timeout: 3)

        // Cycle: auto → default. The mode marker disappears entirely.
        _ = try await alice.sendRaw(.sendKey(.code(.tab, modifiers: .shift)))

        // Wait for the marker to vanish — poll the rendered text for
        // the absence of the auto glyph. waitForRenderedText only
        // checks presence; for absence we poll captureRenderedText.
        let deadline = Date().addingTimeInterval(3)
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
            "after fourth Shift-Tab, status bar should drop the mode marker (back to default)")
    }
}
