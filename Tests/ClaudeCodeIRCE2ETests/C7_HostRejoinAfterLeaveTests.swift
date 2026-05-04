// Regression: host /leave → host /reopen (same room) → messages must
// still flow between host and peer.
//
// Reported scenario: alice hosts a room, bob joins, alice /leaves, alice
// reopens the same room from her Recent sidebar (tab+click / `/reopen`),
// bob is back in the same room — and now neither side sees the other's
// messages. Same on-disk lattice, same room code; only the host's sync
// server + Bonjour publisher cycled.
//
// Upstream caveat: in the live UI the room appears in `Recent` only
// after the app process is restarted (`loadPersistedRooms` runs once at
// init; `/leave` doesn't re-populate `recentLattices`). That's a
// separate bug. To isolate the post-rejoin sync regression, this test
// terminates + relaunches alice between phases so `loadPersistedRooms`
// picks the room up into recents — the same effect the user gets by
// killing and reopening the binary.
//
// What the test does:
//   1. alice hosts roomX, bob joins, both confirm bidirectional
//      visibility with a sanity-check message exchange.
//   2. alice /leaves. Her host server stops; her Member-row delete
//      cascades to bob, whose `ejectIfHostDeleted` observer drops bob
//      into the lobby with a "host left" notice.
//   3. alice terminates and relaunches with the same `CCIRC_DATA_DIR`,
//      so `loadPersistedRooms()` finds the persisted `<code>.lattice`
//      and stashes it in `recentLattices`.
//   4. alice `/reopen <roomName>` → `activateRecent` → `reopenAsHost`
//      brings the same lattice back up under a fresh RoomSyncServer +
//      Bonjour publisher (same roomCode).
//   5. bob `/join`s by name — Bonjour name-prefix match resolves to the
//      newly re-published advertisement for the same roomCode.
//   6. After both have rejoined, alice and bob each send a fresh
//      message and the test asserts the other side sees it. A
//      regression where sync is silently dead post-rejoin fails on
//      these expectMessage calls.

import Testing
import Foundation
import NCUITest
import NCUITestProtocol

@Suite("C7 — host /leave → /reopen same room → messages still flow", .serialized)
struct C7_HostRejoinAfterLeaveTests {
    @Test(.timeLimit(.minutes(3)))
    func messagesFlowAfterHostLeavesAndReopens() async throws {
        let roomName = NCUIApplication.ccircRoomName(prefix: "c7")
        let alice = NCUIApplication.ccirc(label: "alice")
        let bob   = NCUIApplication.ccirc(label: "bob")

        try await alice.launch()
        try await bob.launch()
        defer { alice.terminate(); bob.terminate() }

        // Phase 1: initial host/join + sanity exchange.
        try await alice.hostSession(nick: "alice", roomName: roomName)
        try await bob.joinSession(nick: "bob", roomName: roomName)

        for app in [alice, bob] {
            try await app.waitForMembers(["alice", "bob"], timeout: 30)
        }

        let trace = UUID().uuidString.prefix(6)
        try await alice.sendMessage("c7-pre-leave-alice-\(trace)")
        try await bob.sendMessage("c7-pre-leave-bob-\(trace)")
        try await bob.expectMessage(from: "alice",
                                    contains: "c7-pre-leave-alice-\(trace)")
        try await alice.expectMessage(from: "bob",
                                      contains: "c7-pre-leave-bob-\(trace)")

        // Phase 2: alice /leaves. Host server stops; bob's host-left
        // observer ejects bob to the lobby with a notice.
        try await alice.sendMessage("/leave")
        try await alice.waitForLobby(timeout: 15)
        try await bob.waitForLobby(timeout: 15)

        // Phase 4: alice /reopens the SAME room from her Recent sidebar.
        // No relaunch needed — `RoomsModel.leave(_:)` now repopulates
        // `recentLattices` so the room appears in Recent immediately.
        // `/reopen <name>` → `activateRecent` → `reopenAsHost`. Same
        // on-disk file, same roomCode. The host status bar [alice(%)]
        // is the cleanest "I'm back as host" signal.
        _ = try await alice.sendRaw(.sendKeys("/reopen \(roomName)\n"))
        let aliceHostBar = alice.staticTexts
            .matching(.label(contains: "[alice(%)]"))
            .firstMatch
        _ = try await aliceHostBar.waitForExistence(
            timeout: 20, captureScope: "aliceReopenAsHost")

        // Phase 5: bob rejoins via Bonjour. The re-published service
        // advertises the same roomCode that alice's Recent entry pointed
        // at, so this lands bob in the same room. Bonjour cross-process
        // propagation lags ~1–2s after alice's republish; the stale
        // entry can briefly linger in bob's discovery cache too, so we
        // give the cache time to converge before issuing `/join`.
        try await Task.sleep(for: .seconds(3))
        try await bob.joinSession(nick: "bob", roomName: roomName)

        for app in [alice, bob] {
            try await app.waitForMembers(["alice", "bob"], timeout: 30)
        }

        // Phase 6: post-rejoin message exchange. The bug is that these
        // messages are NOT mutually visible after the leave/reopen cycle.
        try await alice.sendMessage("c7-post-rejoin-alice-\(trace)")
        try await bob.sendMessage("c7-post-rejoin-bob-\(trace)")

        try await bob.expectMessage(from: "alice",
                                    contains: "c7-post-rejoin-alice-\(trace)",
                                    timeout: 15)
        try await alice.expectMessage(from: "bob",
                                      contains: "c7-post-rejoin-bob-\(trace)",
                                      timeout: 15)
    }
}
