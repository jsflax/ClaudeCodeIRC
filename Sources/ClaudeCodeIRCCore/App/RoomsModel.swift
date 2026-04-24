import Foundation
import Lattice

/// App-wide model. Replaces the old `LobbyModel` + `RoomModel` split —
/// the design doesn't have a distinct lobby screen any more; the app
/// boots straight into a single workspace view with sessions sidebar
/// on the left (showing both joined + discovered rooms) and the active
/// room's chat in the middle.
///
/// Owns: the Bonjour browser, the shared prefs Lattice (nick + last
/// cwd + palette survive across launches), the list of joined rooms,
/// and the currently-active room id. Heavy per-room work (sync server,
/// publisher, agent driver, catch-up task) lives on the `RoomInstance`
/// objects in `joinedRooms`.
@MainActor
@Observable
public final class RoomsModel {
    public let browser = BonjourBrowser()
    public let prefs: AppPreferences
    private let prefsLattice: Lattice

    /// Ordered list of rooms this instance has joined. The sessions
    /// sidebar renders one row per entry; Alt+1..9 maps to the Nth
    /// element by index (1-based to match the hotkey label).
    public var joinedRooms: [RoomInstance] = []

    /// Currently-active room's `RoomInstance.id`. `nil` means the
    /// "welcome" empty state is shown in the center pane.
    public var activeRoomId: UUID?

    /// Convenience accessor — `nil` while on the welcome state.
    public var activeRoom: RoomInstance? {
        guard let id = activeRoomId else { return nil }
        return joinedRooms.first(where: { $0.id == id })
    }

    public init() {
        let prefsURL = RoomPaths.prefsURL
        do {
            try FileManager.default.createDirectory(
                at: prefsURL.deletingLastPathComponent(),
                withIntermediateDirectories: true)
            let lattice = try Lattice(
                for: [AppPreferences.self],
                configuration: .init(fileURL: prefsURL))
            self.prefsLattice = lattice
            if let existing = lattice.objects(AppPreferences.self).first {
                self.prefs = existing
            } else {
                let p = AppPreferences()
                lattice.add(p)
                self.prefs = p
            }
        } catch {
            fatalError("Could not open prefs at \(prefsURL.path): \(error)")
        }
        browser.start()
    }

    deinit {
        browser.stop()
    }

    // MARK: - Hosting + joining

    /// Host a new room. Opens the authoritative Lattice, inserts the
    /// `Session` + host `Member`, stands up `RoomSyncServer`, publishes
    /// via Bonjour, and appends + activates a new host-mode
    /// `RoomInstance`.
    ///
    /// - Parameter requireJoinCode: when `true`, generates a 6-char
    ///   bearer code and the server rejects upgrades that don't
    ///   present it; `false` means any LAN peer that discovers the
    ///   room can join.
    @discardableResult
    public func host(
        name: String,
        cwd: String,
        mode: PermissionMode,
        requireJoinCode: Bool
    ) async throws -> RoomInstance {
        let roomCode = Self.generateCode()
        let joinCode: String? = requireJoinCode ? Self.generateCode() : nil
        Log.line("rooms", "host name=\(name) cwd=\(cwd) roomCode=\(roomCode) auth=\(requireJoinCode ? "required" : "open")")
        let lattice = try RoomStore.openHost(code: roomCode)
        Log.line("rooms", "host lattice opened → \(lattice.configuration.fileURL.path)")

        let session = Session()
        session.code = roomCode
        session.name = name
        session.cwd = cwd
        session.permissionMode = mode
        lattice.add(session)

        let me = Member()
        me.nick = prefs.nick
        me.isHost = true
        me.session = session
        lattice.add(me)
        session.host = me

        let server = try RoomSyncServer(
            latticeReference: lattice.sendableReference,
            roomCode: roomCode,
            joinCode: joinCode)
        let port = try await server.start()
        Log.line("rooms", "server.start returned port=\(port)")

        let publisher = BonjourPublisher(
            name: name,
            port: Int32(port),
            roomCode: roomCode,
            hostNick: prefs.nick,
            cwd: cwd,
            requiresJoinCode: requireJoinCode)
        publisher.publish()
        Log.line("rooms", "bonjour publish name=\(name) port=\(port) nick=\(self.prefs.nick)")

        let driver = try await ClaudeCLIDriver(
            latticeRef: lattice.sendableReference,
            sessionRef: session.sendableReference,
            cwd: cwd)
        Log.line("rooms", "claude driver constructed for cwd=\(cwd) mode=\(mode)")

        let turnManager = try await TurnManager(
            driver: driver,
            latticeRef: lattice.sendableReference,
            sessionRef: session.sendableReference)
        Log.line("rooms", "turn manager constructed")

        prefs.lastCwd = cwd

        let instance = RoomInstance.host(
            lattice: lattice,
            roomCode: roomCode,
            session: session,
            selfMember: me,
            joinCode: joinCode,
            server: server,
            publisher: publisher,
            driver: driver,
            turnManager: turnManager,
            prefs: prefs)
        joinedRooms.append(instance)
        activeRoomId = instance.id
        return instance
    }

    /// Join an existing room. `joinCode` is `nil` for open rooms.
    @discardableResult
    public func join(
        _ room: DiscoveredRoom,
        joinCode: String?
    ) throws -> RoomInstance {
        Log.line("rooms", "join room=\(room.name) code=\(room.roomCode) ws=\(room.wsURL.absoluteString) auth=\(joinCode == nil ? "open" : "required")")
        let lattice = try RoomStore.openPeer(
            code: room.roomCode,
            endpoint: room.wsURL,
            joinCode: joinCode)
        Log.line("rooms", "peer lattice opened → \(lattice.configuration.fileURL.lastPathComponent) wss=\(lattice.configuration.wssEndpoint?.absoluteString ?? "nil")")
        let instance = RoomInstance.peer(
            lattice: lattice,
            roomCode: room.roomCode,
            joinCode: joinCode,
            prefs: prefs)
        joinedRooms.append(instance)
        activeRoomId = instance.id
        return instance
    }

    /// Leave a joined room. Stops its server / driver / publisher and
    /// removes it from the list. If it was active, activation shifts
    /// to the previous room (or `nil` if it was the last).
    public func leave(_ roomId: UUID) async {
        guard let idx = joinedRooms.firstIndex(where: { $0.id == roomId })
        else { return }
        let instance = joinedRooms[idx]
        await instance.leave()
        joinedRooms.remove(at: idx)
        if activeRoomId == roomId {
            if idx > 0 {
                activeRoomId = joinedRooms[idx - 1].id
            } else {
                activeRoomId = joinedRooms.first?.id
            }
        }
    }

    // MARK: - Activation

    public func activate(_ roomId: UUID) {
        guard joinedRooms.contains(where: { $0.id == roomId }) else { return }
        activeRoomId = roomId
        if let room = activeRoom {
            room.lastSeenAt = Date()
        }
    }

    /// Alt+1..9 addressing — 1-based index into `joinedRooms`.
    public func activateIndex(_ oneBased: Int) {
        guard oneBased >= 1, oneBased <= joinedRooms.count else { return }
        activate(joinedRooms[oneBased - 1].id)
    }

    public func cycleNext() {
        guard !joinedRooms.isEmpty else { return }
        if let active = activeRoomId,
           let i = joinedRooms.firstIndex(where: { $0.id == active }) {
            let next = (i + 1) % joinedRooms.count
            activate(joinedRooms[next].id)
        } else {
            activate(joinedRooms[0].id)
        }
    }

    public func cyclePrev() {
        guard !joinedRooms.isEmpty else { return }
        if let active = activeRoomId,
           let i = joinedRooms.firstIndex(where: { $0.id == active }) {
            let prev = (i - 1 + joinedRooms.count) % joinedRooms.count
            activate(joinedRooms[prev].id)
        } else {
            activate(joinedRooms.last!.id)
        }
    }

    // MARK: - Code generation

    // 6-char Crockford-base32ish code (no 0/O/1/I/L/U ambiguity).
    // 30^6 ≈ 730M — plenty for bearer auth on a LAN.
    private static let alphabet = Array("abcdefghjkmnpqrstvwxyz23456789")
    private static func generateCode() -> String {
        String((0..<6).map { _ in alphabet.randomElement()! })
    }
}
