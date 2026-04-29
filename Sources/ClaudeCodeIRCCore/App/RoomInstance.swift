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

    /// Mutable so a peer can `swap()` to a new wss endpoint when the
    /// host's `cloudflared` URL changes (tunnel restart). The on-disk
    /// SQLite file stays at the same path, so per-synchronizer state
    /// (`_lattice_sync_state`) survives close+reopen and the new
    /// connection resumes via `?last-event-id=` deltas.
    public private(set) var lattice: Lattice
    public let roomCode: String
    /// `nil` for an open room; the bearer code otherwise. Host displays
    /// it so they can share it out-of-band. Mutable for the swap path
    /// in case the host rotates the join code on a tunnel-URL change.
    public private(set) var joinCode: String?
    public let isHost: Bool

    /// Peer-only. `true` when this peer joined through the host's
    /// tunnel URL (a `wss://*.trycloudflare.com/...` endpoint coming
    /// from the directory or a paste-link), `false` when it joined
    /// directly over LAN via Bonjour (`ws://host.local:port/...`).
    /// `PublicURLObserver` consults this to decide whether to react
    /// to `Session.publicURL` changes — only tunnel peers need to
    /// follow tunnel-URL rotations; LAN peers stay on their direct
    /// connection. Always `false` on the host.
    public let joinedViaTunnel: Bool

    public private(set) var session: Session?
    public private(set) var selfMember: Member?

    public let server: RoomSyncServer?
    public let publisher: BonjourPublisher?
    /// Host-only, non-private rooms only. Spawns `cloudflared`, surfaces
    /// `https://*.trycloudflare.com` URLs via `urlChanges`. Bridge task
    /// (`tunnelTask`) propagates URL changes onto `Session.publicURL`,
    /// which peers observe and use to swap their WS endpoint.
    public let tunnelManager: TunnelManager?

    /// Host-only, non-private rooms only. Heartbeats `POST /publish`
    /// to the directory Worker every 30s while the room is up. Started
    /// after construction; stopped in `leave()`. The publisher's
    /// internals skip cycles until `Session.publicURL` is non-nil, so
    /// it's safe to start immediately even before the tunnel has
    /// resolved its URL.
    public let directoryPublisher: DirectoryPublisher?
    /// Host-only. Reads the user's Claude Code `statusLine` config,
    /// runs the configured shell command on triggers (turn complete,
    /// permission-mode change, optional refresh interval), and writes
    /// stdout to `Session.hostStatusLine`. Peers see the value via
    /// Lattice sync — only the host runs the driver. Nil when the
    /// user hasn't configured a statusLine, or for peer instances.
    public private(set) var statusLineDriver: StatusLineDriver?
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
    /// Mutable: rebuilt after `swap()` so observers attach to the new
    /// `Lattice` instance.
    private var voteCoordinator: ApprovalVoteCoordinator
    /// Sibling of `voteCoordinator` for `AskQuestion` rows. Same
    /// run-everywhere, idempotent-writes story; different tally rule.
    private var askCoordinator: AskVoteCoordinator

    /// Prefs handle — shared across all RoomInstances. Threaded from
    /// `RoomsModel` so `/nick` inside a room persists across launches.
    public let prefs: AppPreferences

    /// Last time the UI showed this room as active. The sessions
    /// sidebar's unread badge is computed from ChatMessage rows newer
    /// than this. Updated by WorkspaceView on activation.
    public var lastSeenAt: Date = Date()

    /// Local-only scrollback cutoff. Set by `/clear` to `Date.now` so
    /// `MessageListView` hides everything authored before it; rows are
    /// not deleted from the lattice, so peers still see them and the
    /// filter doesn't sync. Persists only for the lifetime of this
    /// `RoomInstance` — relaunching the app repopulates the scrollback.
    public var scrollbackFloor: Date?

    private var catchUpTask: Task<Void, Never>?
    /// Periodic `selfMember.lastSeenAt = Date()` ping. Quorum coordinators
    /// filter members by `lastSeenAt` recency, so a member who stops
    /// pinging (process killed, network dropped, laptop closed) is auto-
    /// excluded from quorum after `Self.presenceThreshold`. Explicit
    /// `/leave` deletes the row outright; the heartbeat is the safety net
    /// for everything else. Cancelled in `leave()`.
    private var heartbeatTask: Task<Void, Never>?
    private var chatObserver: AnyCancellable?
    /// Host-only. Lattice observers feeding `StatusLineDriver.nudge()`.
    /// One on Turn (status flips → assistant turn complete) and one on
    /// Session (permission-mode flips). Match the Claude Code spec's
    /// event-driven trigger points. Reset in `leave()`.
    private var turnStatusObserver: AnyCancellable?
    private var permissionModeObserver: AnyCancellable?
    private var lastObservedPermissionMode: PermissionMode?
    /// Host-only. Bridge task: starts the tunnel, waits for URLs, writes
    /// each new URL to `Session.publicURL`. Cancelled in `leave()`.
    private var tunnelTask: Task<Void, Never>?
    /// Watches `Session.publicURL` for tunnel-URL changes pushed by the
    /// host and triggers `swap()` to reconnect. Optional only because
    /// it's wired by the factory methods after `init`; in practice it's
    /// always non-nil for a returned `RoomInstance`. The observer's
    /// `evaluate()` is a no-op on host instances. Rebuilt after each
    /// `swap()` because Lattice observers are tied to a specific
    /// `Lattice` instance.
    private var publicURLObserver: PublicURLObserver?

    /// Opens a fresh peer-side `Lattice` against a new endpoint when
    /// `swap()` runs. Injected so tests substitute a path-controlled
    /// implementation; production uses `DefaultPeerLatticeStore` which
    /// forwards to `RoomStore.openPeer`.
    private let peerLatticeStore: any PeerLatticeStore

    /// Host-side factory — Session + Member rows already inserted by
    /// the caller. Starts the turn-manager chat observer.
    ///
    /// - Parameter tunnelManager: pass when `Session.visibility != .private`.
    ///   The instance starts the tunnel asynchronously and bridges its
    ///   `urlChanges` onto `Session.publicURL`. `nil` for LAN-only rooms.
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
        prefs: AppPreferences,
        tunnelManager: TunnelManager? = nil,
        directoryPublisher: DirectoryPublisher? = nil,
        statusLineDriver: StatusLineDriver? = nil,
        peerLatticeStore: any PeerLatticeStore = DefaultPeerLatticeStore()
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
            prefs: prefs,
            tunnelManager: tunnelManager,
            directoryPublisher: directoryPublisher,
            joinedViaTunnel: false,
            peerLatticeStore: peerLatticeStore)
        instance.startChatObserver()
        instance.startHeartbeat()
        // No-op on host (observer guards isHost), but constructed so the
        // peer/host code paths stay symmetric.
        instance.publicURLObserver = PublicURLObserver(roomInstance: instance)
        if tunnelManager != nil {
            instance.startTunnelBridge()
        }
        // Directory heartbeat — safe to start before the tunnel
        // resolves; the publisher skips cycles while
        // `Session.publicURL == nil`, then publishes once the URL
        // lands. No await needed; `start()` is fire-and-forget.
        if let directoryPublisher {
            Task { await directoryPublisher.start() }
        }
        if let statusLineDriver {
            instance.statusLineDriver = statusLineDriver
            Task { await statusLineDriver.start() }
            instance.startStatusLineObservers()
        }
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
        prefs: AppPreferences,
        peerLatticeStore: any PeerLatticeStore = DefaultPeerLatticeStore()
    ) -> RoomInstance {
        Log.line("room-peer", "creating peer nick=\(prefs.nick) roomCode=\(roomCode)")
        let me = Member()
        me.nick = prefs.nick
        me.isHost = false
        lattice.add(me)
        Log.line("room-peer", "inserted selfMember nick=\(me.nick)")

        // Tunnel peers join through `wss://`; LAN peers via `ws://`.
        // The scheme of the wssEndpoint baked into the lattice's
        // configuration is the canonical record of which path was used.
        let joinedViaTunnel = lattice.configuration.wssEndpoint?.scheme == "wss"

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
            prefs: prefs,
            tunnelManager: nil,
            directoryPublisher: nil,
            joinedViaTunnel: joinedViaTunnel,
            peerLatticeStore: peerLatticeStore)
        instance.startPeerCatchUp(roomCode: roomCode)
        instance.startHeartbeat()
        instance.publicURLObserver = PublicURLObserver(roomInstance: instance)
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
        prefs: AppPreferences,
        tunnelManager: TunnelManager?,
        directoryPublisher: DirectoryPublisher?,
        joinedViaTunnel: Bool,
        peerLatticeStore: any PeerLatticeStore
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
        self.tunnelManager = tunnelManager
        self.directoryPublisher = directoryPublisher
        self.joinedViaTunnel = joinedViaTunnel
        // Every room instance runs a coordinator — tally is
        // deterministic and writes are idempotent.
        self.voteCoordinator = ApprovalVoteCoordinator(lattice: lattice)
        self.askCoordinator = AskVoteCoordinator(lattice: lattice)
        self.prefs = prefs
        self.peerLatticeStore = peerLatticeStore
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

    /// How often `heartbeatTask` writes `selfMember.lastSeenAt`. Members
    /// whose `lastSeenAt` is older than `presenceThreshold` are excluded
    /// from the quorum denominator — see `ApprovalVoteCoordinator` /
    /// `AskVoteCoordinator`.
    static let heartbeatInterval: TimeInterval = 30
    /// Window after which an unheard-from member is treated as gone.
    /// Three missed heartbeats — large enough to ride out a brief
    /// network blip, small enough that a quorum stuck on a crashed peer
    /// recovers in well under two minutes.
    static let presenceThreshold: TimeInterval = 90

    /// Bumps `selfMember.lastSeenAt` every `heartbeatInterval` seconds.
    /// The write itself synchronises like any other Member update —
    /// peers re-evaluate their quorum tallies via the existing
    /// `Member.update` observer in the coordinators, so other members
    /// going stale gets noticed every time someone else heartbeats.
    private func startHeartbeat() {
        guard heartbeatTask == nil else { return }
        heartbeatTask = Task { [weak self] in
            let nanos = UInt64(Self.heartbeatInterval * 1_000_000_000)
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: nanos)
                if Task.isCancelled { return }
                await MainActor.run {
                    self?.selfMember?.lastSeenAt = Date()
                }
            }
        }
    }

    public func leave() async {
        heartbeatTask?.cancel()
        heartbeatTask = nil
        // Persist the leave by removing our Member row before tearing
        // down the sync transport. The local audit log entry is
        // durable; on the host it propagates through the relay task
        // (which `server.stop()` drains below). On a peer it must
        // ride out over WS — `awaitSyncFlush` polls until either
        // there are no unsynced AuditLog rows or the bounded deadline
        // elapses (we don't block leaving forever on a stuck network).
        if let me = selfMember {
            lattice.delete(me)
            selfMember = nil
        }
        if !isHost {
            await awaitSyncFlush(deadline: 1.0)
        }
        catchUpTask?.cancel()
        chatObserver?.cancel()
        turnStatusObserver?.cancel()
        permissionModeObserver?.cancel()
        tunnelTask?.cancel()
        tunnelTask = nil
        if let directoryPublisher { await directoryPublisher.stop() }
        if let tunnelManager { await tunnelManager.stop() }
        if let statusLineDriver { await statusLineDriver.stop() }
        if let driver { await driver.stop() }
        if let server { try? await server.stop() }
        publisher?.stop()
    }

    /// Best-effort wait for the local lattice to push pending writes
    /// over WS. Polls `AuditLog.isSynchronized == false` count and
    /// returns either when the queue empties or `deadline` seconds
    /// elapse — bounded so a dropped network can't block the leave.
    private func awaitSyncFlush(deadline: TimeInterval) async {
        let end = Date().addingTimeInterval(deadline)
        while Date() < end {
            let pending = lattice.count(AuditLog.self,
                                        where: { $0.isSynchronized == false })
            if pending == 0 { return }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
    }

    /// Host-only. Kicks off `cloudflared` (asynchronously, may take 2–10s
    /// to resolve a URL) and pipes each new public URL onto
    /// `Session.publicURL`. Peers observe that field via
    /// `PublicURLObserver` and `swap()` to the new endpoint.
    ///
    /// `start()` failure (cloudflared not on `PATH`, etc.) is logged but
    /// not surfaced — the room still works on LAN, the public-URL field
    /// stays nil, and the UI can show a "tunnel unavailable" badge by
    /// reading `Session.publicURL == nil`. Two-phase host: the LAN
    /// experience never blocks on tunnel readiness.
    private func startTunnelBridge() {
        guard let tunnelManager else { return }
        tunnelTask = Task { [weak self] in
            do {
                try await tunnelManager.start()
            } catch {
                Log.line("room-host", "tunnel start failed: \(error) — room is LAN-only")
                return
            }
            for await url in tunnelManager.urlChanges {
                if Task.isCancelled { return }
                guard let self else { return }
                self.session?.publicURL = url.absoluteString
                Log.line("room-host", "Session.publicURL ← \(url.absoluteString)")
                // Kick the directory publisher immediately. Without
                // this, the heartbeat loop's first publish skips
                // (wssURL is still nil at start time), and the next
                // attempt is 30s away — meaning peers wait ~30s +
                // KV propagation before discovering the room. The
                // Worker's 25s rate limit caps any abuse.
                if let directoryPublisher = self.directoryPublisher {
                    Task { await directoryPublisher.nudge() }
                }
            }
        }
    }

    /// Peer-only. Swap this instance's WS sync endpoint without
    /// destroying the on-disk transcript. Used when the host's
    /// `cloudflared` URL changes (tunnel restart) — the host's local
    /// `RoomSyncServer` is unchanged, only the public address differs.
    ///
    /// The room's SQLite file stays at the same path (PID-scoping was
    /// removed), so `_lattice_sync_state` carries the last-acked
    /// globalId across `close()`+`open()`. The new WS connection sends
    /// `?last-event-id=<thatUUID>` and the host streams only the delta
    /// since. Unsynced local AuditLog rows replay against the new
    /// server idempotently.
    ///
    /// Object references (Session, Member, etc.) are tied to the
    /// previous `Lattice` instance and become invalid on close — they
    /// are re-fetched from the new instance using stable `globalId`.
    public func swap(toEndpoint endpoint: URL, joinCode: String?) throws {
        precondition(
            !isHost,
            "RoomInstance.swap() is peer-only; the host's local server is unaffected by tunnel-URL changes")
        Log.line(
            "room-instance",
            "swap → \(endpoint.absoluteString) joinCode=\(joinCode != nil ? "present" : "nil")")

        // Snapshot stable identity for re-link after reopen.
        let selfMemberGlobalId = selfMember?.globalId
        let sessionCode = self.roomCode

        // Cancel observers / tasks tied to the old Lattice.
        catchUpTask?.cancel()
        catchUpTask = nil
        chatObserver?.cancel()
        chatObserver = nil

        // Drop model references *before* close. `self` is `@Observable`,
        // so any later assignment to `selfMember` or `session` triggers
        // a setter that reads the old value — which by then would be a
        // dangling pointer into the closed Lattice's C++ store, crashing
        // SQLite/the binding layer. Niling them while the old Lattice is
        // still live releases their backing handles cleanly.
        self.selfMember = nil
        self.session = nil

        // Close the old connection BEFORE opening the new one — two
        // Lattice instances on the same SQLite file race their WS
        // sync clients on `_lattice_sync_state` and the new client
        // never connects (`broadcast … to 0 peers`). Single-handle
        // ordering keeps the sync state unambiguous.
        lattice.close()

        let newLattice = try peerLatticeStore.openPeer(
            code: roomCode,
            endpoint: endpoint,
            joinCode: joinCode)
        self.lattice = newLattice
        self.joinCode = joinCode

        // Rebuild coordinators on the new instance — old ones drop and
        // their `AnyCancellable` observers cancel automatically.
        self.voteCoordinator = ApprovalVoteCoordinator(lattice: newLattice)
        self.askCoordinator = AskVoteCoordinator(lattice: newLattice)

        // Re-link object references from the new instance. Same on-disk
        // rows, fresh object identity.
        if let gid = selfMemberGlobalId {
            self.selfMember = newLattice.object(Member.self, globalId: gid)
        }
        let resolvedSession = newLattice.objects(Session.self)
            .first(where: { $0.code == sessionCode })
        if let resolvedSession {
            linkToSession(resolvedSession)
        } else {
            // Session row hasn't synced yet on the new connection — restart
            // the catch-up task so the link backfills once it arrives.
            self.session = nil
            startPeerCatchUp(roomCode: roomCode)
        }

        // Re-attach the publicURL observer to the new Lattice instance.
        // Old observer's AnyCancellable drops here.
        self.publicURLObserver = PublicURLObserver(roomInstance: self)
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

    // MARK: - Host-side statusLine triggers

    /// Host-only. Wires two Lattice observers — one on `Turn.status`
    /// (assistant-turn complete) and one on `Session.permissionMode`
    /// — to nudge `StatusLineDriver`. Mirrors Claude Code's event-
    /// driven trigger spec; the driver itself debounces 300ms so
    /// rapid bursts coalesce into a single command invocation.
    ///
    /// Permission-mode observation guards on a snapshot of the last-
    /// seen value to avoid firing on every Session row insert/update
    /// (most aren't mode changes — ChatMessage relations, publicURL,
    /// etc. all flow through the same `observe(Session.self)` stream).
    private func startStatusLineObservers() {
        guard let driver = statusLineDriver else { return }
        lastObservedPermissionMode = session?.permissionMode
        Log.line("statusline-obs", "wired (Turn + Session) for room=\(self.roomCode)")

        turnStatusObserver = lattice.observe(Turn.self) { @Sendable [weak self] change in
            // Log every fire: bursts that flood ccirc.log indicate a
            // runaway feedback loop. Pre-filter so only `.update`
            // bursts surface — `.insert` for a new Turn isn't relevant
            // to the nudge path.
            Log.line("statusline-obs", "Turn fire change=\(change) room=\(self?.roomCode ?? "?" as String)")
            guard case .update = change else { return }
            Task { [weak self] in await self?.nudgeStatusLineIfTurnComplete(driver: driver) }
        }

        permissionModeObserver = lattice.observe(Session.self) { @Sendable [weak self] change in
            // Same instrumentation rationale as above: this observer
            // fires on every Session row mutation (publicURL,
            // hostStatusLine writes, etc.) — the per-fire log makes
            // self-induced loops obvious.
            Log.line("statusline-obs", "Session fire change=\(change) room=\(self?.roomCode ?? "?" as String)")
            switch change {
            case .insert, .update: break
            default: return
            }
            Task { @MainActor [weak self] in
                guard let self,
                      let mode = self.session?.permissionMode else { return }
                if mode != self.lastObservedPermissionMode {
                    Log.line("statusline-obs", "permissionMode \(self.lastObservedPermissionMode.map(String.init(describing:)) ?? "nil") → \(mode) — nudging")
                    self.lastObservedPermissionMode = mode
                    Task { await driver.nudge() }
                }
            }
        }
    }

    private func nudgeStatusLineIfTurnComplete(driver: StatusLineDriver) async {
        // Coarse trigger: any Turn row update fires `nudge()`. We could
        // narrow to `.complete` transitions specifically, but the
        // 300ms debounce in the driver makes the extra precision
        // pointless and the simpler observer is easier to keep correct
        // across schema additions.
        await driver.nudge()
    }
}
