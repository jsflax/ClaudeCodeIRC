import Foundation
import Lattice

/// Room-screen state. Holds the room's Lattice handle and, on the
/// host, the sync server + Bonjour publisher. On a peer, those are
/// nil and the Lattice's own `WebsocketClient` handles sync.
///
/// `@MainActor` because the TUI reads from this during view body
/// evaluation. Heavy work stays off main: `RoomSyncServer` is a
/// background actor, Lattice's sync client runs on its own scheduler,
/// Bonjour delegates to its own dispatch queue.
@MainActor
@Observable
public final class RoomModel {
    public let lattice: Lattice
    public let joinCode: String
    public private(set) var session: Session?
    public private(set) var selfMember: Member?

    public let server: RoomSyncServer?
    public let publisher: BonjourPublisher?

    private var catchUpTask: Task<Void, Never>?

    /// Host-side factory — Session + Member rows already inserted by caller.
    public static func host(
        lattice: Lattice,
        session: Session,
        selfMember: Member,
        joinCode: String,
        server: RoomSyncServer,
        publisher: BonjourPublisher
    ) -> RoomModel {
        RoomModel(
            lattice: lattice,
            session: session,
            selfMember: selfMember,
            joinCode: joinCode,
            server: server,
            publisher: publisher)
    }

    /// Peer-side factory — Session hasn't arrived yet. Spawn a task
    /// that tails `changeStream` until the host's `Session` row syncs
    /// down, then insert this peer's own `Member` linked to it.
    public static func peer(
        lattice: Lattice,
        roomCode: String,
        joinCode: String,
        nick: String
    ) -> RoomModel {
        let model = RoomModel(
            lattice: lattice,
            session: nil,
            selfMember: nil,
            joinCode: joinCode,
            server: nil,
            publisher: nil)
        model.startPeerCatchUp(roomCode: roomCode, nick: nick)
        return model
    }

    private init(
        lattice: Lattice,
        session: Session?,
        selfMember: Member?,
        joinCode: String,
        server: RoomSyncServer?,
        publisher: BonjourPublisher?
    ) {
        self.lattice = lattice
        self.session = session
        self.selfMember = selfMember
        self.joinCode = joinCode
        self.server = server
        self.publisher = publisher
    }

    private func startPeerCatchUp(roomCode: String, nick: String) {
        catchUpTask = Task { [weak self, lattice] in
            // Check once up front in case the Session already exists
            // (reconnect to a room whose DB is on disk from a prior run).
            if let existing = lattice.objects(Session.self)
                .first(where: { $0.code == roomCode }) {
                self?.registerSelf(session: existing, nick: nick)
                return
            }
            // Otherwise tail changeStream until it shows up.
            for await _ in lattice.changeStream {
                if Task.isCancelled { return }
                if let s = lattice.objects(Session.self)
                    .first(where: { $0.code == roomCode }) {
                    self?.registerSelf(session: s, nick: nick)
                    return
                }
            }
        }
    }

    private func registerSelf(session: Session, nick: String) {
        let me = Member()
        me.nick = nick
        me.isHost = false
        me.session = session
        lattice.add(me)
        self.session = session
        self.selfMember = me
    }

    public func leave() async {
        catchUpTask?.cancel()
        if let server { try? await server.stop() }
        publisher?.stop()
    }
}
