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
    public func host(name: String, cwd: String, mode: PermissionMode) async throws -> RoomModel {
        let roomCode = Self.generateCode()
        let joinCode = Self.generateCode()
        let lattice = try RoomStore.openHost(code: roomCode)

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

        let publisher = BonjourPublisher(
            name: name,
            port: Int32(port),
            roomCode: roomCode,
            hostNick: prefs.nick,
            cwd: cwd)
        publisher.publish()

        prefs.lastCwd = cwd

        return RoomModel.host(
            lattice: lattice,
            session: session,
            selfMember: me,
            joinCode: joinCode,
            server: server,
            publisher: publisher)
    }

    /// Join an existing room. Opens a peer-side Lattice pointed at the
    /// host's WS endpoint. The peer's own `Member` row is inserted by
    /// `RoomModel` once `Session` catch-up arrives via sync.
    public func join(_ room: DiscoveredRoom, joinCode: String) throws -> RoomModel {
        let lattice = try RoomStore.openPeer(
            code: room.roomCode,
            endpoint: room.wsURL,
            joinCode: joinCode)
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
