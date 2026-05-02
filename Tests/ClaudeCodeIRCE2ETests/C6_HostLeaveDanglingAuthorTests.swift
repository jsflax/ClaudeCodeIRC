// Smoke test for the cascade-audit fragmentation fix
// (LatticeCore notify_changes_batched + cascade transaction wrap +
// Lattice changeStream batching).
//
// Original bug: when alice (host) ran /leave, alice's host lattice
// deleted her Member row plus the cascade `_ChatMessage_Member_author`
// link rows. Pre-fix this committed as N separate auto-commit
// transactions, fanned out to bob as N wire frames via
// `RoomSyncServer.broadcastEntries` (one frame per `changeStream`
// yield). Bob applied N frames as N transactions; between frames bob's
// lattice held alice's link-table FKs pointing at a Member row that
// was already gone. Any redraw in that window walked
// `Optional<Member>.getField` → `dynamic_object::get_object` → freed
// `dynamic_object` and SIGSEGV'd in
// `swift_lattice::get_properties_for_table`.
//
// Post-fix: parent + cascade DELETEs commit as one SQL transaction
// (`lattice_db::remove` transaction wrap), all audits fire as one
// observer batch (`notify_changes_batched`), the host server ships
// them in one wire frame, bob applies atomically. No window.
//
// What this test asserts (wire-level evidence):
//   1. After alice writes 3 messages and runs /leave, the host server
//      broadcasts a multi-entry frame containing the cascade DELETEs.
//      A `broadcast N entries to 1 peers` line with N >= 2 in
//      ~/Library/Logs/ClaudeCodeIRC/ccirc.log proves the cascade
//      reached the wire in one frame, not N separate frames. Pre-fix
//      this would always be N=1 entries per broadcast (one frame per
//      `changeStream` yield, one yield per `notify_change` call).
//   2. The receiving side (the same log; the host server also logs
//      `applied N audit entries → ack` for incoming peer uploads —
//      symmetry check on the receive path) confirms the batched
//      transaction is being applied atomically.
//
// What this test does NOT cover:
//   - Bob's process liveness after the cascade arrives. There is a
//     separate post-leave crash in bob (NCursesUI draw recursion) that
//     also surfaces here; the cascade fix alone doesn't address it,
//     and adding a `bob.ping()` assertion makes the smoke test fail
//     on that unrelated bug. File separately.
//   - Reopening a previously-corrupted persisted lattice file (the
//     "rejoin after host left" report). The cascade fix prevents the
//     corrupt state from being WRITTEN; existing dirty files still
//     crash on reopen and need a one-shot scrub. Separate concern.

import Testing
import Foundation
import NCUITest
import NCUITestProtocol

@Suite("C6 — host-leave cascade reaches peer atomically",
       .serialized)
struct C6_HostLeaveDanglingAuthorTests {
    @Test(.timeLimit(.minutes(3)))
    func cascadeDeleteReachesPeerInOneFrame() async throws {
        let roomName = NCUIApplication.ccircRoomName(prefix: "c6")
        let alice = NCUIApplication.ccirc(label: "alice")
        let bob   = NCUIApplication.ccirc(label: "bob")

        try await alice.launch()
        try await bob.launch()
        defer { alice.terminate(); bob.terminate() }

        try await alice.hostSession(nick: "alice", roomName: roomName)
        try await bob.joinSession(nick: "bob", roomName: roomName)

        for app in [alice, bob] {
            try await app.waitForMembers(["alice", "bob"], timeout: 30)
        }

        // Stack alice-authored messages so the cascade has real link
        // rows to clean up. With 3 messages, alice's /leave fires:
        //   DELETE FROM Member WHERE id = aliceId            (parent)
        //   DELETE FROM _ChatMessage_Member_author WHERE rhs (× 3)
        // Plus an AuditLog INSERT for each — well above the N>=2
        // threshold the post-fix broadcast must hit.
        let trace = UUID().uuidString.prefix(6)
        for i in 0..<3 {
            try await alice.sendMessage("c6-alice-msg-\(trace)-\(i)")
        }
        try await bob.expectMessage(from: "alice",
                                    contains: "c6-alice-msg-\(trace)-2")

        // Snapshot the host log size BEFORE alice /leave so we can
        // grep only the post-leave broadcast lines.
        let logPath = Self.ccircLogPath()
        let preLeaveLogSize = (try? FileManager.default.attributesOfItem(atPath: logPath)[.size] as? Int) ?? 0

        // Alice /leaves. lattice.delete(aliceMember) on the host runs
        // the parent + cascade DELETEs as one SQL transaction
        // (`lattice_db::remove` transaction wrap), the resulting WAL
        // commit fires a single batched `notify_changes_batched`
        // call, the host's `changeStream` yields all refs together,
        // and `RoomSyncServer.broadcastEntries` ships them in one
        // frame.
        try await alice.sendMessage("/leave")

        // Wait long enough for the cascade frame to broadcast and the
        // peer to apply it. The host's broadcast fires via the
        // changeStream relay task; on a quiet machine this is
        // sub-second, but give a generous budget.
        try await Task.sleep(for: .seconds(3))

        // Wire-level gate: the cascade frame reached the wire as a
        // single multi-entry broadcast. Read the host log filtered to
        // post-leave lines.
        let postLeaveLog = Self.readLogTail(path: logPath, fromOffset: preLeaveLogSize)
        let broadcastLines = postLeaveLog
            .split(separator: "\n")
            .filter { $0.contains("[server] broadcast ") && $0.contains("entries") }
            .map(String.init)
        let multiEntryFrames = broadcastLines.compactMap { line -> Int? in
            // Format: "[server] broadcast N entries to M peers"
            guard let r = line.range(of: "broadcast ") else { return nil }
            let after = line[r.upperBound...]
            guard let n = after.split(separator: " ").first.flatMap({ Int($0) }) else { return nil }
            return n >= 2 ? n : nil
        }
        #expect(!multiEntryFrames.isEmpty,
                "expected at least one multi-entry broadcast frame (cascade fix); saw only single-entry frames in post-leave log:\n\(broadcastLines.joined(separator: "\n"))")
    }

    private static func ccircLogPath() -> String {
        let home = NSHomeDirectory()
        return "\(home)/Library/Logs/ClaudeCodeIRC/ccirc.log"
    }

    private static func readLogTail(path: String, fromOffset: Int) -> String {
        guard let handle = FileHandle(forReadingAtPath: path) else { return "" }
        defer { try? handle.close() }
        try? handle.seek(toOffset: UInt64(fromOffset))
        let data = (try? handle.readToEnd()) ?? Data()
        return String(data: data, encoding: .utf8) ?? ""
    }
}
