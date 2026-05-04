// Smoke test for the cascade-audit fragmentation fix
// (LatticeCore notify_changes_batched + cascade transaction wrap +
// Lattice changeStream batching).
//
// Original bug: when a member ran /leave, their lattice deleted
// their Member row plus the cascade `_ChatMessage_Member_author`
// link rows. Pre-fix this committed as N separate auto-commit
// transactions, fanned out as N wire frames via
// `RoomSyncServer.broadcastEntries` (one frame per `changeStream`
// yield). The receiver applied N frames as N transactions; between
// frames their lattice held link-table FKs pointing at a Member row
// that was already gone. Any redraw in that window walked
// `Optional<Member>.getField` → `dynamic_object::get_object` → freed
// `dynamic_object` and SIGSEGV'd in
// `swift_lattice::get_properties_for_table`.
//
// Post-fix: parent + cascade DELETEs commit as one SQL transaction
// (`lattice_db::remove` transaction wrap), all audits fire as one
// observer batch (`notify_changes_batched`), the host server ships
// them in one wire frame, the receiver applies atomically. No window.
//
// Trigger note: the original repro used alice (host) /leave. The
// architectural fix in `RoomInstance.leave()` now skips the cascade
// for hosts (host /leave flips `isAway`/clears `session.host` instead
// of deleting the Member row, preserving ownership + authorship).
// Peer /leave still cascades — same code path on `LatticeCore`'s
// side, same primitive coverage. So this test now drives bob (peer)
// /leave with 3 authored messages.
//
// What this test asserts (wire-level evidence):
//   1. After bob writes 3 messages and runs /leave, the host server
//      broadcasts a multi-entry frame containing the cascade DELETEs.
//      A `broadcast N entries to 1 peers` line with N >= 2 in
//      ~/Library/Logs/ClaudeCodeIRC/ccirc.log proves the cascade
//      reached the wire in one frame, not N separate frames. Pre-fix
//      this would always be N=1 entries per broadcast (one frame per
//      `changeStream` yield, one yield per `notify_change` call).
//
// What this test does NOT cover:
//   - Reopening a previously-corrupted persisted lattice file (the
//     "rejoin after host left" report). The cascade fix prevents the
//     corrupt state from being WRITTEN; existing dirty files still
//     crash on reopen and need a one-shot scrub. Separate concern.

import Testing
import Foundation
import NCUITest
import NCUITestProtocol

@Suite("C6 — peer-leave cascade reaches host atomically",
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

        // Stack bob-authored messages so the cascade has real link
        // rows to clean up. With 3 messages, bob's /leave fires:
        //   DELETE FROM Member WHERE id = bobId             (parent)
        //   DELETE FROM _ChatMessage_Member_author WHERE rhs (× 3)
        // Plus an AuditLog INSERT for each — well above the N>=2
        // threshold the post-fix broadcast must hit.
        let trace = UUID().uuidString.prefix(6)
        for i in 0..<3 {
            try await bob.sendMessage("c6-bob-msg-\(trace)-\(i)")
        }
        try await alice.expectMessage(from: "bob",
                                      contains: "c6-bob-msg-\(trace)-2")

        // Snapshot the host log size BEFORE bob /leave so we can
        // grep only the post-leave broadcast lines.
        let logPath = Self.ccircLogPath()
        let preLeaveLogSize = (try? FileManager.default.attributesOfItem(atPath: logPath)[.size] as? Int) ?? 0

        // Bob /leaves. lattice.delete(bobMember) on bob's peer runs
        // the parent + cascade DELETEs as one SQL transaction
        // (`lattice_db::remove` transaction wrap), the resulting WAL
        // commit fires a single batched `notify_changes_batched`
        // call, bob's `awaitSyncFlush` lets the upload land, alice's
        // host server applies as one transaction and the host's
        // `RoomSyncServer.broadcastEntries` re-emits them in one
        // frame to any other peers. With only one peer (bob) the
        // re-emission is a no-op; the wire-level evidence we look
        // for here is the host-side `applied N audit entries` log
        // line, which mirrors the same atomicity on the receive
        // path.
        try await bob.sendMessage("/leave")

        // Wait long enough for the cascade frame to upload and the
        // host to apply it. Quiet machines do this sub-second; give
        // a generous budget.
        try await Task.sleep(for: .seconds(3))

        // Wire-level gate: the cascade frame reached the wire (or
        // landed at the host) as a single multi-entry batch. Either
        // a multi-entry `broadcast N entries` (when there's another
        // peer to fan out to) or a multi-entry `applied N audit
        // entries` is sufficient evidence — both come from the same
        // atomic batch.
        let postLeaveLog = Self.readLogTail(path: logPath, fromOffset: preLeaveLogSize)
        let multiEntry = postLeaveLog
            .split(separator: "\n")
            .compactMap { line -> Int? in
                let s = String(line)
                if let r = s.range(of: "broadcast ") {
                    let rest = s[r.upperBound...]
                    if let n = rest.split(separator: " ").first.flatMap({ Int($0) }),
                       s.contains("entries"), n >= 2 {
                        return n
                    }
                }
                if let r = s.range(of: "applied ") {
                    let rest = s[r.upperBound...]
                    if let n = rest.split(separator: " ").first.flatMap({ Int($0) }),
                       s.contains("audit entries"), n >= 2 {
                        return n
                    }
                }
                return nil
            }
        #expect(!multiEntry.isEmpty,
                "expected at least one multi-entry batched frame (cascade fix); none seen in post-leave log:\n\(postLeaveLog)")
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
