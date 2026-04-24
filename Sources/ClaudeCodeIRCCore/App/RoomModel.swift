import Combine
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
    /// `nil` for an open room; the bearer code otherwise. Host displays
    /// it in the status bar so they can share it out-of-band.
    public let joinCode: String?
    public private(set) var session: Session?
    public private(set) var selfMember: Member?

    public let server: RoomSyncServer?
    public let publisher: BonjourPublisher?
    /// Host-only. The `claude` subprocess driver. Created eagerly on
    /// `host(...)`; `send(prompt:)` forwards to it. Peers talk to
    /// Claude via the host's Lattice rows — they have no local driver.
    public let driver: (any ClaudeDriver)?

    private var catchUpTask: Task<Void, Never>?
    private var mentionObserver: AnyCancellable?

    /// Host-side factory — Session + Member rows already inserted by caller.
    public static func host(
        lattice: Lattice,
        session: Session,
        selfMember: Member,
        joinCode: String?,
        server: RoomSyncServer,
        publisher: BonjourPublisher,
        driver: (any ClaudeDriver)
    ) -> RoomModel {
        let model = RoomModel(
            lattice: lattice,
            session: session,
            selfMember: selfMember,
            joinCode: joinCode,
            server: server,
            publisher: publisher,
            driver: driver)
        model.startClaudeMentionObserver()
        return model
    }

    /// Peer-side factory. Inserts the peer's own `Member` immediately
    /// with an unset `session` link so the UI shows the correct nick
    /// right away; the Session arrives asynchronously via sync
    /// catch-up, at which point `startPeerCatchUp` backfills
    /// `Member.session`.
    public static func peer(
        lattice: Lattice,
        roomCode: String,
        joinCode: String?,
        nick: String
    ) -> RoomModel {
        Log.line("room-peer", "creating peer nick=\(nick) roomCode=\(roomCode)")
        let me = Member()
        me.nick = nick
        me.isHost = false
        lattice.add(me)
        Log.line("room-peer", "inserted selfMember nick=\(me.nick)")

        let model = RoomModel(
            lattice: lattice,
            session: nil,
            selfMember: me,
            joinCode: joinCode,
            server: nil,
            publisher: nil,
            driver: nil)
        model.startPeerCatchUp(roomCode: roomCode)
        return model
    }

    private init(
        lattice: Lattice,
        session: Session?,
        selfMember: Member?,
        joinCode: String?,
        server: RoomSyncServer?,
        publisher: BonjourPublisher?,
        driver: (any ClaudeDriver)?
    ) {
        self.lattice = lattice
        self.session = session
        self.selfMember = selfMember
        self.joinCode = joinCode
        self.server = server
        self.publisher = publisher
        self.driver = driver
    }

    private func startPeerCatchUp(roomCode: String) {
        catchUpTask = Task { [weak self, lattice] in
            Log.line("room-peer", "catch-up task started, watching for Session code=\(roomCode)")
            // Check once up front in case the Session already exists
            // (reconnect to a room whose DB is on disk from a prior run).
            if let existing = lattice.objects(Session.self)
                .first(where: { $0.code == roomCode }) {
                Log.line("room-peer", "session already present → link immediately")
                self?.linkToSession(existing)
                return
            }
            Log.line("room-peer", "tailing changeStream for Session arrival")
            // Otherwise tail changeStream until it shows up.
            for await refs in lattice.changeStream {
                if Task.isCancelled { return }
                Log.line("room-peer", "changeStream yielded \(refs.count) refs")
                if let s = lattice.objects(Session.self)
                    .first(where: { $0.code == roomCode }) {
                    Log.line("room-peer", "Session \(roomCode) arrived via sync → linking")
                    self?.linkToSession(s)
                    return
                }
            }
            Log.line("room-peer", "catch-up task exited (stream ended)")
        }
    }

    private func linkToSession(_ session: Session) {
        Log.line("room-peer", "linkToSession name=\(session.name) code=\(session.code)")
        self.session = session
        selfMember?.session = session
    }

    public func leave() async {
        catchUpTask?.cancel()
        mentionObserver?.cancel()
        if let driver { await driver.stop() }
        if let server { try? await server.stop() }
        publisher?.stop()
    }

    // MARK: - Host-side @claude trigger

    /// Host-only. Observes the `ChatMessage` table directly — both
    /// local writes and peer uploads land as `.insert` notifications
    /// here. On a mention, forward the message as a single-turn prompt
    /// to the `claude` subprocess. P5's TurnManager will replace this
    /// with multi-message intra-turn assembly and inter-turn queueing;
    /// for now the goal is a working end-to-end path.
    private func startClaudeMentionObserver() {
        guard driver != nil else { return }
        Log.line("room-host", "@claude observer starting")
        mentionObserver = lattice.observe(ChatMessage.self) { @Sendable [weak self] change in
            guard case .insert(let rowId) = change else { return }
            Task { [weak self] in
                await self?.handleInsertedChatMessage(rowId: rowId)
            }
        }
    }

    private func handleInsertedChatMessage(rowId: Int64) async {
        guard let msg = lattice.object(ChatMessage.self, primaryKey: rowId),
              msg.kind == .user,
              !msg.side,
              ClaudeMention.matches(msg.text),
              let driver
        else { return }
        let nick = msg.author?.nick ?? "?"
        let prompt = "\(nick): \(msg.text)"
        let ref = msg.sendableReference
        Log.line("room-host", "@claude fire nick=\(nick) text=\(msg.text.prefix(80))")
        do { try await driver.send(prompt: prompt, promptMessageRef: ref) }
        catch { Log.line("room-host", "driver.send failed: \(error)") }
    }
}
