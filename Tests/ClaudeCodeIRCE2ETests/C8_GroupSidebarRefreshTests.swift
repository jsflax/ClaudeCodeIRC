import Testing
import Foundation
import NCUITest
import NCUITestProtocol

/// Regression test for the bug that produced this fix series: when a
/// user runs `/newgroup <name>` from the lobby (no active room), the
/// sidebar's groups section did not auto-update with a `── <name> (0) ──`
/// divider, leading the user to assume the command had failed and
/// retry via `/addgroup`. Two `LocalGroup` rows then ended up in
/// `prefs.lattice` and the sidebar showed two same-named sections
/// (which is how the bug surfaced).
///
/// Asserts the user-visible contract: after `/newgroup`, the
/// rendered terminal output contains a sidebar divider for the
/// new group.
@Suite("ClaudeCodeIRC e2e — group sidebar refresh", .serialized)
struct GroupSidebarRefreshTests {
    @Test("newgroup adds a sidebar section without restart (lobby)")
    func newGroupAppearsInSidebarFromLobby() async throws {
        let alice = NCUIApplication.ccirc(label: "alice-newgroup-lobby")
        try await alice.launch()
        defer { alice.terminate() }

        try await alice.waitForLobby()
        try await alice.setNick("alice")

        // Pre-condition: no `canary` divider yet. (The empty groups
        // state shows "(none — /addgroup …)" lines, not a divider with
        // the canary name.)
        let pre = try alice.captureRenderedText()
        #expect(!pre.contains("canary"),
            "lobby should not contain 'canary' before /newgroup")

        _ = try await alice.sendRaw(.sendKeys("/newgroup canary\n"))

        // The sidebar's `GroupsSidebarSection` renders one section per
        // `LocalGroup` row in `prefs.lattice`. The header text is
        // `── <name> (<count>) ──`; with no directory listings the
        // count is `0`. We poll the rendered terminal for that
        // substring — view-tree queries don't catch BoxView/Text
        // rules drawn through `Term.put`, but `captureRenderedText`
        // does.
        try await alice.waitForRenderedText("canary (0)", timeout: 5)
    }

    /// Same regression test, but executed while a room is active. In
    /// the lobby case `handleNewGroup` flips `pendingNewGroupInvite`
    /// (a `@State`), implicitly forcing a body re-eval that picks up
    /// the new `LocalGroup` row. The active-room case has no such
    /// `@State` flip — the only side effects are a `prefsLattice.add`
    /// and a `ChatMessage` write to the room's lattice. If
    /// NCursesUI's @Observable→render path is broken, this test
    /// fails where the lobby one passes.
    @Test("newgroup adds a sidebar section without restart (active room)")
    func newGroupAppearsInSidebarFromActiveRoom() async throws {
        let alice = NCUIApplication.ccirc(label: "alice-newgroup-room")
        try await alice.launch()
        defer { alice.terminate() }

        try await alice.waitForLobby()
        try await alice.hostSession(nick: "alice", roomName: "room1", visibility: .lan)

        // Sanity: in a hosted room now, no `canary` divider yet.
        let pre = try alice.captureRenderedText()
        #expect(!pre.contains("canary"),
            "active room should not contain 'canary' before /newgroup")

        _ = try await alice.sendRaw(.sendKeys("/newgroup canary\n"))

        // Same expectation as the lobby case: the new group's section
        // must surface in the sidebar within a render tick.
        try await alice.waitForRenderedText("canary (0)", timeout: 5)
    }
}
