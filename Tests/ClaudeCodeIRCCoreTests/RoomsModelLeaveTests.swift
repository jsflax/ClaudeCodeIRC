import Foundation
import Testing
import Lattice
import ClaudeCodeIRCCore

/// Covers two pieces of the post-/leave invariants that the existing
/// `RoomsModelDeleteRoomTests` doesn't already assert:
///
/// 1. **Recent sidebar is refreshed without a relaunch.** After
///    `host()` + `leave(_:)`, `model.recentLattices` contains the
///    just-left room with a readable Session row. Pre-fix this only
///    happened on a fresh `RoomsModel` (init scan via
///    `loadPersistedRooms`), so the user had to kill the binary
///    before they could `/reopen`.
///
/// 2. **`leave` is idempotent against the recents list.** Calling
///    `leave` (or `loadPersistedRooms`) repeatedly does not duplicate
///    entries in `recentLattices`. The dedup guard in
///    `loadPersistedRooms` is what makes the call from `leave(_:)`
///    safe to repeat.
@MainActor
@Suite(.serialized) struct RoomsModelLeaveTests {

    private func withTempDataDir<T>(_ body: () async throws -> T) async rethrows -> T {
        let tmp = FileManager.default.temporaryDirectory
            .appending(path: "ccirc-leave-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(
            at: tmp.appending(path: "rooms"),
            withIntermediateDirectories: true)
        let prior = RoomPaths.dataDirOverride
        RoomPaths.dataDirOverride = tmp
        defer {
            RoomPaths.dataDirOverride = prior
            try? FileManager.default.removeItem(at: tmp)
        }
        return try await body()
    }

    private func hostPrivate(name: String = "leave-test") async throws
        -> (RoomsModel, RoomInstance)
    {
        let model = RoomsModel()
        // RoomsModel.init kicks off `loadPersistedRooms` on a Task. Let
        // it land before we call host — otherwise the scan can fire
        // mid-host (during `server.start`'s await) and pick up the
        // just-created lattice file as a Recent entry while joinedRooms
        // hasn't been appended yet. Empty-dir scan settles in <50ms.
        try await Task.sleep(for: .milliseconds(100))
        let room = try await model.host(
            name: name,
            cwd: "/tmp",
            mode: .default,
            requireJoinCode: false,
            visibility: .private)
        return (model, room)
    }

    /// Wait for `recentLattices` to settle (loadPersistedRooms is
    /// async, called from leave). Polls up to `timeout` seconds.
    private func waitForRecent(
        _ model: RoomsModel,
        contains code: String,
        timeout: TimeInterval = 3
    ) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !model.recentLattices.contains(where: { $0.code == code }),
              Date() < deadline {
            try? await Task.sleep(for: .milliseconds(20))
        }
    }

    @Test func leaveAddsHostRoomToRecentLattices() async throws {
        try await withTempDataDir {
            let (model, room) = try await hostPrivate()
            let code = room.roomCode

            #expect(model.recentLattices.isEmpty,
                "fresh model with one joined room: nothing in Recent")

            await model.leave(room.id)
            await waitForRecent(model, contains: code)

            #expect(model.recentLattices.contains { $0.code == code },
                "leave must surface the room under Recent without a relaunch")

            // The recent handle exposes a readable Session row — the
            // sidebar's `RecentRoomRow` reads via `@Query Session` on
            // `\.lattice` so the lattice has to actually be open.
            let entry = model.recentLattices.first { $0.code == code }
            let session = entry?.lattice.objects(Session.self)
                .first(where: { $0.code == code })
            #expect(session != nil, "recent entry must expose the Session row")
            #expect(session?.name == "leave-test")
        }
    }

    @Test func leaveDoesNotDuplicateRecentEntries() async throws {
        try await withTempDataDir {
            let (model, room) = try await hostPrivate()
            let code = room.roomCode

            await model.leave(room.id)
            await waitForRecent(model, contains: code)

            #expect(model.recentLattices.filter { $0.code == code }.count == 1)

            // A second `leave` for an already-departed id is a no-op
            // (joinedRooms.firstIndex returns nil); the recents list
            // must not pick up a duplicate handle.
            await model.leave(room.id)
            #expect(model.recentLattices.filter { $0.code == code }.count == 1,
                "leave must not duplicate the Recent entry on a no-op call")
        }
    }
}
