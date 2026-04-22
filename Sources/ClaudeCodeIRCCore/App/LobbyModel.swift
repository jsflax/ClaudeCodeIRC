import Foundation
import Lattice

/// Lobby-screen state. Owns the Bonjour browser, the shared prefs
/// Lattice (nick + last-cwd survive across launches), and factory
/// methods for transitioning to a room (host-side or peer-side).
///
/// `@MainActor` because the TUI reads this during view body evaluation
/// and NCursesUI views run on the main actor. Heavy work (sync server,
/// publisher, agent driver) lives on its own background actors — this
/// class just holds references.
@MainActor
@Observable
public final class LobbyModel {
    public let browser = BonjourBrowser()
    public let prefs: AppPreferences
    private let prefsLattice: Lattice

    public init() {
        let prefsURL = RoomPaths.rootDirectory
            .deletingLastPathComponent()
            .appending(path: "prefs.lattice")
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

    /// Host a new room. Opens the authoritative Lattice, inserts the
    /// `Session` + host `Member`, stands up `RoomSyncServer`, publishes
    /// via Bonjour, and returns a host-mode `RoomModel`.
    ///
    /// - Parameter requireJoinCode: when `true`, generates a 6-char
    ///   bearer code and the server rejects upgrades that don't present
    ///   it; `false` means any LAN peer that discovers the room can join.
    public func host(
        name: String,
        cwd: String,
        mode: PermissionMode,
        requireJoinCode: Bool
    ) async throws -> RoomModel {
        let roomCode = Self.generateCode()
        let joinCode: String? = requireJoinCode ? Self.generateCode() : nil
        Log.line("lobby", "host name=\(name) cwd=\(cwd) roomCode=\(roomCode) auth=\(requireJoinCode ? "required" : "open")")
        let lattice = try RoomStore.openHost(code: roomCode)
        Log.line("lobby", "host lattice opened → \(lattice.configuration.fileURL.lastPathComponent)")

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
        Log.line("lobby", "server.start returned port=\(port)")

        let publisher = BonjourPublisher(
            name: name,
            port: Int32(port),
            roomCode: roomCode,
            hostNick: prefs.nick,
            cwd: cwd,
            requiresJoinCode: requireJoinCode)
        publisher.publish()
        Log.line("lobby", "bonjour publish name=\(name) port=\(port) nick=\(self.prefs.nick)")

        prefs.lastCwd = cwd

        return RoomModel.host(
            lattice: lattice,
            session: session,
            selfMember: me,
            joinCode: joinCode,
            server: server,
            publisher: publisher)
    }

    /// Join an existing room. `joinCode` is `nil` for open rooms; a
    /// string for password-protected ones.
    public func join(_ room: DiscoveredRoom, joinCode: String?) throws -> RoomModel {
        Log.line("lobby", "join room=\(room.name) code=\(room.roomCode) ws=\(room.wsURL.absoluteString) auth=\(joinCode == nil ? "open" : "required")")
        let lattice = try RoomStore.openPeer(
            code: room.roomCode,
            endpoint: room.wsURL,
            joinCode: joinCode)
        Log.line("lobby", "peer lattice opened → \(lattice.configuration.fileURL.lastPathComponent) wss=\(lattice.configuration.wssEndpoint?.absoluteString ?? "nil")")
        return RoomModel.peer(
            lattice: lattice,
            roomCode: room.roomCode,
            joinCode: joinCode,
            nick: prefs.nick)
    }

    // 6-char Crockford-base32ish code (no 0/O/1/I/L/U ambiguity).
    // 30^6 ≈ 730M — plenty for bearer auth on a LAN.
    private static let alphabet = Array("abcdefghjkmnpqrstvwxyz23456789")
    private static func generateCode() -> String {
        String((0..<6).map { _ in alphabet.randomElement()! })
    }
}
