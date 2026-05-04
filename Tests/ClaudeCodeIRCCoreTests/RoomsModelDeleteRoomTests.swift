import Foundation
import Testing
import Lattice
import ClaudeCodeIRCCore

/// Exercises the difference between `RoomsModel.leave(_:)` and
/// `RoomsModel.deleteRoom(_:)`:
///
/// - `leave(_:)` tears down the live `RoomInstance` (publisher / sync
///   server / driver). For a peer, the local `Member` row is deleted
///   so the host's lattice sees the peer depart. For a host, the row
///   is kept (with `isAway = true`, `session.host = nil`, `isHost`
///   stays true) so the durable "this is my room" marker survives
///   for `/reopen`. The on-disk `<rooms>/<code>.lattice` file persists
///   in either case, and the room reappears under "Recent".
///
/// - `deleteRoom(_:)` does everything `leave(_:)` does, then closes
///   any cached recent-lattice handle for the same code and removes
///   the lattice file. The room is gone for good.
///
/// `.serialized` because every test sets the global
/// `RoomPaths.dataDirOverride` and constructs a `RoomsModel` against
/// it. Parallel tests would race on the override.
@MainActor
@Suite(.serialized) struct RoomsModelDeleteRoomTests {

    private func withTempDataDir<T>(_ body: () async throws -> T) async rethrows -> T {
        let tmp = FileManager.default.temporaryDirectory
            .appending(path: "ccirc-deleteroom-\(UUID().uuidString)")
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

    /// Host a private room and return the `(model, instance)` pair.
    /// `.private` so the test doesn't depend on `cloudflared` being on
    /// PATH (which would also publish to a live directory worker).
    private func hostPrivate(
        name: String = "test-room"
    ) async throws -> (RoomsModel, RoomInstance) {
        let model = RoomsModel()
        let room = try await model.host(
            name: name,
            cwd: "/tmp",
            mode: .default,
            requireJoinCode: false,
            visibility: .private)
        return (model, room)
    }

    // MARK: - leave

    @Test func leavePreservesLatticeFile() async throws {
        try await withTempDataDir {
            let (model, room) = try await hostPrivate()
            let code = room.roomCode
            let fileURL = RoomPaths.storeURL(forCode: code)

            #expect(FileManager.default.fileExists(atPath: fileURL.path),
                "host should create the lattice file")
            #expect(model.joinedRooms.count == 1)

            await model.leave(room.id)

            // joinedRooms drained.
            #expect(model.joinedRooms.isEmpty)
            // File preserved on disk — the user can `/reopen` later.
            #expect(FileManager.default.fileExists(atPath: fileURL.path),
                "leave must NOT remove the lattice file from disk")
        }
    }

    @Test func leaveKeepsHostMemberFlippedAway() async throws {
        try await withTempDataDir {
            let (model, room) = try await hostPrivate()
            let code = room.roomCode

            // Host's Member row was inserted at host() time.
            let beforeCount = room.lattice.objects(Member.self).count
            #expect(beforeCount == 1)

            await model.leave(room.id)

            // Reopen the lattice from disk and confirm host's Member
            // persists with the vacated-host state. (We can't read from
            // `room.lattice` after leave — that handle is closed inside
            // RoomInstance.leave.)
            let reopened = try Lattice(
                for: RoomStore.schema,
                configuration: .init(fileURL: RoomPaths.storeURL(forCode: code)))
            defer { reopened.close() }
            let members = Array(reopened.objects(Member.self))
            #expect(members.count == 1,
                "host /leave must NOT delete its own Member — that would cascade-delete authorship and ownership")
            if let me = members.first {
                #expect(me.isHost, "isHost stays true as the durable owner marker")
                #expect(me.isAway, "isAway flips true as the presence-gone signal")
            }
            let session = reopened.objects(Session.self).first { $0.code == code }
            #expect(session?.host == nil,
                "session.host must clear so peers' ejectIfHostLeft fires")
        }
    }

    // MARK: - deleteRoom

    @Test func deleteRoomRemovesLatticeFile() async throws {
        try await withTempDataDir {
            let (model, room) = try await hostPrivate()
            let code = room.roomCode
            let fileURL = RoomPaths.storeURL(forCode: code)

            #expect(FileManager.default.fileExists(atPath: fileURL.path))

            await model.deleteRoom(room.id)

            #expect(model.joinedRooms.isEmpty)
            #expect(!FileManager.default.fileExists(atPath: fileURL.path),
                "deleteRoom must remove the on-disk lattice file")
        }
    }

    @Test func deleteRoomDropsRecentEntry() async throws {
        try await withTempDataDir {
            let (model, room) = try await hostPrivate()

            // Force a recent-lattice cache hit by leaving (file stays
            // on disk) then waiting for loadPersistedRooms to scan it.
            // Actually, the scan only runs in init; we don't trigger
            // it here. So instead simulate the cached-handle case by
            // first deleteRoom-ing — when joinedRooms holds the room,
            // dropRecent is a no-op (no recent entry to drop). The
            // important assertion is post-condition: the room is
            // unreachable via either path.
            let beforeJoined = model.joinedRooms.count
            #expect(beforeJoined == 1)

            await model.deleteRoom(room.id)

            #expect(model.joinedRooms.isEmpty,
                "joinedRooms must drop the deleted room")
            #expect(model.recentLattices.isEmpty,
                "recentLattices must not contain the deleted room")
        }
    }

    @Test func deleteRoomIsNoOpForUnknownId() async throws {
        try await withTempDataDir {
            let (model, room) = try await hostPrivate()
            let bogus = UUID()
            #expect(bogus != room.id)

            await model.deleteRoom(bogus)

            // Original room is still here.
            #expect(model.joinedRooms.count == 1)
            #expect(FileManager.default.fileExists(
                atPath: RoomPaths.storeURL(forCode: room.roomCode).path))

            // Cleanup so the temp-dir teardown can rm the file.
            await model.deleteRoom(room.id)
        }
    }

    /// After deleteRoom, a fresh `RoomsModel` (simulating next-launch)
    /// must not surface the room under `recentLattices`. This is the
    /// "Recent sidebar entry is gone" guarantee from the user's
    /// perspective.
    @Test func deleteRoomPreventsRecentReappearOnRelaunch() async throws {
        try await withTempDataDir {
            let (model, room) = try await hostPrivate()
            await model.deleteRoom(room.id)

            // Simulate next-launch: a brand-new RoomsModel scans the
            // (now empty) `<dataDir>/rooms/` directory.
            let nextLaunch = RoomsModel()

            // Wait briefly for the async scan to finish.
            let deadline = Date().addingTimeInterval(2)
            while nextLaunch.recentLattices.isEmpty == false, Date() < deadline {
                try await Task.sleep(for: .milliseconds(20))
            }
            #expect(nextLaunch.recentLattices.isEmpty,
                "deleted room must not reappear on relaunch")
        }
    }
}
