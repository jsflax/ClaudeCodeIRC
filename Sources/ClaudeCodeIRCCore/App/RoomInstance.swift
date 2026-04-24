import Combine
import Foundation
import Lattice

/// One joined room. Replaces the old `RoomModel` and widens it to live
/// inside the new multi-room `RoomsModel` — the UI renders many
/// `RoomInstance`s simultaneously (sessions sidebar shows all joined
/// rooms, only one is active at a time).
///
/// Holds the room's `Lattice` handle and — on the host — the sync
/// server + Bonjour publisher + Claude driver + TurnManager. On a
/// peer, those are nil and the `Lattice`'s own sync client handles
/// catch-up.
///
/// `@MainActor` because the TUI reads from this during view body
/// evaluation. Heavy work stays off main (server is a background
/// actor, sync client on its own scheduler, Bonjour on its own
/// dispatch queue).
@MainActor
@Observable
public final class RoomInstance: Identifiable {
    /// App-scoped identity — used by the sessions sidebar + Alt+1..9
    /// to address a specific joined room. Not the sync code.
    public let id: UUID = UUID()

    public let lattice: Lattice
    public let roomCode: String
    /// `nil` for an open room; the bearer code otherwise. Host displays
    /// it so they can share it out-of-band.
    public let joinCode: String?
    public let isHost: Bool

    public private(set) var session: Session?
    public private(set) var selfMember: Member?

    public let server: RoomSyncServer?
    public let publisher: BonjourPublisher?
    /// Host-only. The `claude` subprocess driver. Created eagerly at
    /// host() time; the TurnManager drives it. Peers talk to Claude
    /// via the host's Lattice rows — they have no local driver.
    public let driver: (any ClaudeDriver)?
    /// Host-only. Accumulates ChatMessage inserts, fires the driver on
    /// @claude mentions with the surrounding context, queues arrivals
    /// until the current Turn completes. Protocol-typed so tests can
    /// substitute a fake.
    public let turnManager: (any TurnManaging)?
    /// Watches vote inserts + member AFK flips and commits the
    /// terminal `ApprovalRequest.status` when quorum lands. Runs on
    /// every client — the tally is deterministic so host + peers all
    /// compute the same outcome from the same sync'd state; Lattice's
    /// last-writer-wins semantics make the writes idempotent. Peers
    /// seeing quorum locally get the status flip immediately instead
    /// of waiting for the host's sync round-trip.
    private let voteCoordinator: ApprovalVoteCoordinator

    /// Prefs handle — shared across all RoomInstances. Threaded from
    /// `RoomsModel` so `/nick` inside a room persists across launches.
    public let prefs: AppPreferences

    /// Last time the UI showed this room as active. The sessions
    /// sidebar's unread badge is computed from ChatMessage rows newer
    /// than this. Updated by WorkspaceView on activation.
    public var lastSeenAt: Date = Date()

    private var catchUpTask: Task<Void, Never>?
    private var chatObserver: AnyCancellable?

    /// Host-side factory — Session + Member rows already inserted by
    /// the caller. Starts the turn-manager chat observer.
    public static func host(
        lattice: Lattice,
        roomCode: String,
        session: Session,
        selfMember: Member,
        joinCode: String?,
        server: RoomSyncServer,
        publisher: BonjourPublisher,
        driver: (any ClaudeDriver),
        turnManager: any TurnManaging,
        prefs: AppPreferences
    ) -> RoomInstance {
        let instance = RoomInstance(
            lattice: lattice,
            roomCode: roomCode,
            isHost: true,
            session: session,
            selfMember: selfMember,
            joinCode: joinCode,
            server: server,
            publisher: publisher,
            driver: driver,
            turnManager: turnManager,
            prefs: prefs)
        instance.startChatObserver()
        return instance
    }

    /// Peer-side factory. Inserts the peer's own Member immediately
    /// with an unset `session` link so the UI shows the correct nick
    /// right away; the Session arrives asynchronously via sync
    /// catch-up, at which point `startPeerCatchUp` backfills
    /// `Member.session`.
    public static func peer(
        lattice: Lattice,
        roomCode: String,
        joinCode: String?,
        prefs: AppPreferences
    ) -> RoomInstance {
        Log.line("room-peer", "creating peer nick=\(prefs.nick) roomCode=\(roomCode)")
        let me = Member()
        me.nick = prefs.nick
        me.isHost = false
        lattice.add(me)
        Log.line("room-peer", "inserted selfMember nick=\(me.nick)")

        let instance = RoomInstance(
            lattice: lattice,
            roomCode: roomCode,
            isHost: false,
            session: nil,
            selfMember: me,
            joinCode: joinCode,
            server: nil,
            publisher: nil,
            driver: nil,
            turnManager: nil,
            prefs: prefs)
        instance.startPeerCatchUp(roomCode: roomCode)
        return instance
    }

    private init(
        lattice: Lattice,
        roomCode: String,
        isHost: Bool,
        session: Session?,
        selfMember: Member?,
        joinCode: String?,
        server: RoomSyncServer?,
        publisher: BonjourPublisher?,
        driver: (any ClaudeDriver)?,
        turnManager: (any TurnManaging)?,
        prefs: AppPreferences
    ) {
        self.lattice = lattice
        self.roomCode = roomCode
        self.isHost = isHost
        self.session = session
        self.selfMember = selfMember
        self.joinCode = joinCode
        self.server = server
        self.publisher = publisher
        self.driver = driver
        self.turnManager = turnManager
        // Every room instance runs a coordinator — tally is
        // deterministic and writes are idempotent.
        self.voteCoordinator = ApprovalVoteCoordinator(lattice: lattice)
        self.prefs = prefs
    }

    private func startPeerCatchUp(roomCode: String) {
        catchUpTask = Task { [weak self, lattice] in
            Log.line("room-peer", "catch-up task started, watching for Session code=\(roomCode)")
            if let existing = lattice.objects(Session.self)
                .first(where: { $0.code == roomCode }) {
                Log.line("room-peer", "session already present → link immediately")
                self?.linkToSession(existing)
                return
            }
            Log.line("room-peer", "tailing changeStream for Session arrival")
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
        chatObserver?.cancel()
        if let driver { await driver.stop() }
        if let server { try? await server.stop() }
        publisher?.stop()
    }

    // MARK: - Host-side chat observer → TurnManager

    /// Host-only. Every `ChatMessage` insert (local write or peer
    /// upload) forwards to TurnManager.ingest. The manager decides
    /// whether to buffer, fire the driver, or queue for after the
    /// current turn. Filtering — .side, .system, assistant-authored
    /// messages — happens inside TurnManager.
    private func startChatObserver() {
        guard turnManager != nil else { return }
        Log.line("room-host", "turn-manager chat observer starting")
        chatObserver = lattice.observe(ChatMessage.self) { @Sendable [weak self] change in
            guard case .insert(let rowId) = change else { return }
            Task { [weak self] in
                await self?.forwardToTurnManager(rowId: rowId)
            }
        }
    }

    private func forwardToTurnManager(rowId: Int64) async {
        guard let msg = lattice.object(ChatMessage.self, primaryKey: rowId),
              let gid = msg.globalId,
              let turnManager
        else { return }
        await turnManager.ingest(globalId: gid)
    }
}
