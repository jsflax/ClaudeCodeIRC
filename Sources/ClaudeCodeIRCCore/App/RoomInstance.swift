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
    /// Off-`MainActor`. Pings `selfMember.lastSeenAt = Date()` every
    /// `Self.heartbeatInterval` seconds so quorum coordinators (which
    /// filter members by `lastSeenAt` recency) see this member as
    /// present. A stopped heartbeat ages this member out of quorum
    /// after `Self.presenceThreshold` and the host's sweeper flips
    /// them to AFK. Explicit `/leave` deletes the row outright.
    /// Stopped in `leave()`.
    private var heartbeat: MemberHeartbeat?
    /// Host-only, off-`MainActor`. Periodically marks stale members
    /// (process killed, network dropped) as `isAway = true` so they
    /// stop blocking quorum. Stopped in `leave()`.
    private var presenceSweeper: MemberPresenceSweeper?
    /// Observes ChatMessage inserts. Two responsibilities:
    /// (1) host-only — forward each row's globalId to TurnManager so it
    /// can decide whether to fire the driver. (2) anyone — fire
    /// `onForeignMessage` for non-self user/action messages newer than
    /// `messageCutoff`, used by `RoomsModel` to bell the terminal when
    /// a non-active room receives traffic.
    private var messageObserver: AnyCancellable?
    /// Wall-clock at observer start. Filters historical messages
    /// streamed during initial catch-up out of the bell path so a
    /// fresh peer joining a long-running room doesn't get a flood.
    private let messageCutoff: Date = Date()
    /// Set by `RoomsModel` after each `joinedRooms.append`. Fires on
    /// foreign user/action messages; the model decides whether to bell
    /// based on `activeRoomId`. `nil` while the instance is in flight
    /// before `RoomsModel` wires it.
    public var onForeignMessage: (() -> Void)?
    /// Host-only. Watches `Turn.cancelRequested` flips so anyone in
    /// the room (including a peer that ESC'd, propagating via sync)
    /// can interrupt the in-flight `claude` subprocess. Reset in
    /// `leave()`.
    private var cancelObserver: AnyCancellable?
    /// Re-entrancy guard for the cancel handler — observer fires can
    /// pile up while `driver.stop()` is in flight; without this, each
    /// fire would write a duplicate "*** turn interrupted" system
    /// message.
    private var cancelInProgress: Bool = false
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
    /// Peer-only. Owns the WebSocket reconnect timer + attempt counter
    /// off-MainActor; the timer's `Task.sleep` runs on the monitor's
    /// own actor isolation so it doesn't block UI ticks. `RoomInstance`
    /// only re-arms it (after `peer()` and after each `swap()`) and
    /// cancels it in `leave()`. Nil on host instances and on peers that
    /// don't have a `wssEndpoint` (LAN-only without internet path).
    private var reconnectMonitor: PeerReconnectMonitor?
    /// Peer-only. Watches Member deletes — when our own `selfMember`
    /// row vanishes from the synced state (host ran `/kick` on us),
    /// we ourselves should auto-leave instead of leaving a stale UI
    /// pointing at a dead Member. Cancelled in `leave()`.
    private var selfMemberObserver: AnyCancellable?
    /// Peer-only. Watches Session updates — host /leave clears
    /// `session.host` (without deleting the host's Member row, which
    /// would cascade-delete every `_ChatMessage_Member_author` link
    /// and erase the durable "this is alice's room" marker). When the
    /// link goes nil we fire `ejectIfHostLeft` to auto-leave the peer.
    /// Cancelled in `leave()`.
    private var sessionObserver: AnyCancellable?
    /// Re-entrancy guard so two near-simultaneous Member.delete
    /// observer fires don't both kick off `onKickedFromHost`.
    private var kickInProgress: Bool = false
    /// Re-entrancy guard for `onHostLeft` — separate from `kickInProgress`
    /// because a host-left can race a self-delete observation in either
    /// order, and each needs its own once-only fire.
    private var hostLeaveInProgress: Bool = false
    /// Peer-only. Snapshot of `session.name` taken in `linkToSession`
    /// so the host-left notice can show the friendly name even after
    /// `ejectIfHostLeft` nils `session` to keep dying-link renders
    /// out of the view tree.
    public private(set) var cachedSessionName: String?
    /// Wired by `RoomsModel` after the peer factory returns. Called
    /// once on the MainActor when this instance detects its own
    /// `selfMember` row was deleted from the synced state by the host
    /// (i.e. a `/kick`). The handler is responsible for both posting
    /// the user-facing system message and tearing the instance down
    /// via `leave(_:)`. Held by reference; set to `nil` in `leave()`.
    public var onKickedFromHost: ((UUID) async -> Void)?
    /// Peer-only. Wired by `RoomsModel` like `onKickedFromHost`. Fires
    /// once when the host's Member row is deleted from the synced
    /// state — i.e. the host ran `/leave`. The handler tears the
    /// instance down and posts a "host left" notice. Set to `nil` in
    /// `leave()`.
    public var onHostLeft: ((UUID) async -> Void)?

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
        instance.startMessageObserver()
        instance.startCancelObserver()
        instance.startHeartbeat()
        instance.startPresenceSweeper()
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

    /// Peer-side factory. Looks up an existing `Member` whose
    /// `userId` matches `prefs.userId` (rejoin after a transient drop,
    /// crash + relaunch, or swap) and reuses it — clearing `isAway`
    /// from a host-set timeout, refreshing nick if `/nick`'d, bumping
    /// `lastSeenAt`. Inserts a new Member only when no prior row
    /// exists. The Session relationship arrives asynchronously via
    /// sync catch-up; `startPeerCatchUp` backfills `Member.session`.
    public static func peer(
        lattice: Lattice,
        roomCode: String,
        joinCode: String?,
        prefs: AppPreferences,
        peerLatticeStore: any PeerLatticeStore = DefaultPeerLatticeStore()
    ) -> RoomInstance {
        Log.line("room-peer", "creating peer nick=\(prefs.nick) roomCode=\(roomCode)")
        let userId = prefs.userId
        let me: Member
        if let existing = lattice.objects(Member.self)
            .where({ $0.userId == userId })
            .first {
            existing.nick = prefs.nick
            existing.isAway = false
            existing.awayReason = nil
            existing.lastSeenAt = Date()
            me = existing
            Log.line("room-peer", "reused existing selfMember nick=\(me.nick) userId=\(userId)")
        } else {
            me = Member()
            me.nick = prefs.nick
            me.userId = userId
            me.isHost = false
            lattice.add(me)
            Log.line("room-peer", "inserted selfMember nick=\(me.nick) userId=\(userId)")
        }

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
        instance.startSelfMemberObserver()
        instance.startMessageObserver()
        instance.publicURLObserver = PublicURLObserver(roomInstance: instance)
        instance.installReconnectMonitor()
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
        if !isHost {
            self.cachedSessionName = session.name
        }
    }

    /// How often `MemberHeartbeat` writes `selfMember.lastSeenAt`.
    /// Members whose `lastSeenAt` is older than `presenceThreshold`
    /// are excluded from the quorum denominator — see
    /// `ApprovalVoteCoordinator` / `AskVoteCoordinator`. Same value
    /// is used as the sweeper cadence (`MemberPresenceSweeper`).
    static let heartbeatInterval: TimeInterval = 30
    /// Window after which an unheard-from member is treated as gone.
    /// Three missed heartbeats — large enough to ride out a brief
    /// network blip, small enough that a quorum stuck on a crashed peer
    /// recovers in well under two minutes.
    static let presenceThreshold: TimeInterval = 90

    /// Constructs and starts the off-MainActor `MemberHeartbeat` keyed
    /// to this instance's `selfMember.globalId`. Called from both
    /// factories once `selfMember` is non-nil. The heartbeat actor
    /// resolves its own `Lattice` handle via `sendableReference` so
    /// the periodic write never touches the main thread; cross-
    /// instance change observation (per Lattice's C++ layer) still
    /// fires the MainActor-side `@LatticeQuery` / coordinator
    /// observers naturally.
    private func startHeartbeat() {
        guard heartbeat == nil,
              let me = selfMember,
              let id = me.globalId
        else { return }
        do {
            let hb = try MemberHeartbeat(
                latticeReference: lattice.sendableReference,
                selfMemberGlobalId: id,
                interval: Self.heartbeatInterval)
            heartbeat = hb
            Task { await hb.start() }
        } catch {
            Log.line("room", "heartbeat init failed: \(error)")
        }
    }

    /// Host-only. Constructs and starts the off-MainActor
    /// `MemberPresenceSweeper`. Called from the host factory only —
    /// the host owns the canonical AFK write.
    private func startPresenceSweeper() {
        guard isHost,
              presenceSweeper == nil,
              let me = selfMember,
              let id = me.globalId
        else { return }
        do {
            let sw = try MemberPresenceSweeper(
                latticeReference: lattice.sendableReference,
                selfMemberGlobalId: id,
                interval: Self.heartbeatInterval,
                staleThreshold: Self.presenceThreshold)
            presenceSweeper = sw
            Task { await sw.start() }
        } catch {
            Log.line("room", "presence sweeper init failed: \(error)")
        }
    }

    /// Peer-only. Lattice's `observe(Member.self)` fires on every
    /// Member row delete (no per-row subscription API), so the
    /// callback's job is to detect the one case that matters: our
    /// own `selfMember` row was the deleted row — i.e. the host ran
    /// `/kick` on us, and the delete just arrived via WS sync.
    /// `ejectIfSelfDeleted` does the per-fire check + handoff.
    private func startSelfMemberObserver() {
        selfMemberObserver = lattice.observe(Member.self) {
            @Sendable [weak self] change in
            guard case .delete = change else { return }
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.ejectIfSelfDeleted()
                // Defensive: legacy hosts that still cascade-delete on
                // /leave produce a Member-delete frame as well as the
                // session.host clear. `ejectIfHostLeft` is idempotent
                // via `hostLeaveInProgress` so firing from both paths
                // is safe.
                self.ejectIfHostLeft()
            }
        }
        sessionObserver = lattice.observe(Session.self) {
            @Sendable [weak self] _ in
            Task { @MainActor [weak self] in
                self?.ejectIfHostLeft()
            }
        }
    }

    /// MainActor-side per-fire check: our own row gone? If so,
    /// fire `onKickedFromHost` exactly once and clear the local
    /// reference so subsequent UI reads + `leave()` teardown can't
    /// touch a dead Member.
    private func ejectIfSelfDeleted() {
        guard !kickInProgress, !isHost else { return }
        guard let me = selfMember, let id = me.globalId else { return }
        guard lattice.object(Member.self, globalId: id) == nil else { return }
        kickInProgress = true
        let roomId = self.id
        let handler = onKickedFromHost
        selfMember = nil
        Task { await handler?(roomId) }
    }

    /// Peer-only. Fires when the host runs `/leave` — they clear
    /// `session.host` (without deleting their Member row, since that
    /// would cascade-delete every `_ChatMessage_Member_author` link
    /// and orphan their authored messages on every peer). Idempotent
    /// via `hostLeaveInProgress` so firing from both the Session
    /// observer and the legacy Member-delete path is safe.
    private func ejectIfHostLeft() {
        guard !hostLeaveInProgress, !isHost else { return }
        // Require `session` to be linked first — otherwise a Session
        // observer fire that arrives while `linkToSession` is still
        // pending (catch-up sync window) would treat "I haven't linked
        // yet" as "the host left" and self-eject a fresh peer.
        guard let s = self.session, s.host == nil else { return }
        hostLeaveInProgress = true
        let roomId = self.id
        let handler = onHostLeft
        // Delete our own Member row so the local lattice ends in a
        // "no member" state — when the peer rejoins later via `/join`,
        // the peer factory mints a fresh Member instead of reusing a
        // stale one whose backing C++ identity may have been torn down
        // by the lattice close in `leave()`. Mirrors the old
        // cascade-driven path: alice's /leave used to delete her
        // Member, the cascade synced bob's view of her down, AND bob's
        // lattice's own Member was dropped in `instance.leave()` —
        // because `selfMember` was still non-nil when leave ran. Now
        // alice's leave doesn't cascade, so we have to clear bob's
        // Member explicitly here.
        if let me = selfMember {
            lattice.delete(me)
        }
        // Drop the @Observable references — SwiftUI views observing
        // them will re-evaluate with `nil` and short-circuit before
        // the async leave runs.
        selfMember = nil
        session = nil
        Task { await handler?(roomId) }
    }

    public func leave() async {
        if let heartbeat { await heartbeat.stop() }
        heartbeat = nil
        if let presenceSweeper { await presenceSweeper.stop() }
        presenceSweeper = nil
        selfMemberObserver?.cancel()
        selfMemberObserver = nil
        sessionObserver?.cancel()
        sessionObserver = nil
        onKickedFromHost = nil
        onHostLeft = nil
        // Persist the leave by removing our Member row before tearing
        // down the sync transport. The local audit log entry is
        // durable; on the host it propagates through the relay task
        // (which `server.stop()` drains below). On a peer it must
        // ride out over WS — `awaitSyncFlush` watches Lattice's own
        // `syncProgressStream` and returns either when `pendingUpload`
        // hits zero or the bounded deadline elapses (we don't block
        // leaving forever on a stuck network).
        if let me = selfMember {
            if isHost {
                // Host /leave: don't cascade-delete. Flipping `isAway`
                // signals presence-gone; clearing `session.host` is the
                // wire signal peers' `ejectIfHostLeft` watches. Keeping
                // `isHost = true` and the Member row itself preserves
                // the durable "this is my room" marker that
                // `activateRecent` and `reopenAsHost`'s Member-fallback
                // both consume on rejoin — and avoids the cascade that
                // would otherwise nil out every `_ChatMessage_Member_author`
                // link row, orphaning alice's prior messages.
                me.isAway = true
                session?.host = nil
            } else {
                lattice.delete(me)
            }
            selfMember = nil
        }
        if !isHost {
            await awaitSyncFlush(deadline: 1.5)
        }
        catchUpTask?.cancel()
        messageObserver?.cancel()
        cancelObserver?.cancel()
        turnStatusObserver?.cancel()
        permissionModeObserver?.cancel()
        tunnelTask?.cancel()
        tunnelTask = nil
        // Stop the reconnect monitor before tearing down the lattice
        // so a state-change callback that fires during teardown finds
        // a stale generation (cancel() bumps it) and bails instead of
        // scheduling a fresh reconnect against a Lattice we're closing.
        if let reconnectMonitor {
            await reconnectMonitor.cancel()
            self.reconnectMonitor = nil
        }
        if let directoryPublisher { await directoryPublisher.stop() }
        if let tunnelManager { await tunnelManager.stop() }
        if let statusLineDriver { await statusLineDriver.stop() }
        if let driver { await driver.stop() }
        if let server { try? await server.stop() }
        publisher?.stop()
        // Synchronous close — required for both hosts and peers.
        //
        // Host: `RoomsModel.leave(_:)` immediately reopens the same
        // SQLite file as a recent-mode handle; two live handles racing
        // on the WAL is the original C4/C6-class hazard.
        //
        // Peer: LatticeCore's `setup_sync_if_configured` guards on a
        // cross-process `flock` over `<path>.sync.lock`. If this peer
        // immediately re-`/join`s the same room (e.g. host /leave →
        // host /reopen → peer /join again), the new Lattice's flock
        // acquire is non-blocking and silently no-ops when the OLD
        // peer Lattice still holds the lock — the new instance
        // initialises with no synchronizer at all. ARC release isn't
        // deterministic enough to clear the flock in time, so we
        // close synchronously here.
        Log.line("room-instance",
                 "leave: about to lattice.close() isHost=\(self.isHost) " +
                 "file=\(self.lattice.configuration.fileURL.lastPathComponent)")
        lattice.close()
        Log.line("room-instance", "leave: lattice.close() returned")
    }

    /// Best-effort wait for the local lattice to push pending writes
    /// over WS. Subscribes to `Lattice.syncProgressStream` and returns
    /// when `pendingUpload == 0` or the deadline elapses — bounded so
    /// a dropped network can't block the leave indefinitely.
    private func awaitSyncFlush(deadline seconds: TimeInterval) async {
        let stream = lattice.syncProgressStream
        await withTaskGroup(of: Void.self) { group in
            group.addTask {
                for await progress in stream {
                    if progress.pendingUpload == 0 { return }
                }
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            }
            // Whichever finishes first wins; cancel the other.
            await group.next()
            group.cancelAll()
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
        let oldFile = lattice.configuration.fileURL.lastPathComponent

        // No-op when the target matches the current connection. Reopening
        // the Lattice for an unchanged endpoint leaves every cached
        // `TableResults` in `@Query` wrappers pointing at the closed
        // C++ `swift_lattice` (Configuration-equality bind-skip in
        // Query.swift), and the next `RoomPane.body` read crashes in
        // `database::query` with a null `db_`. This guard keeps callers
        // (PeerReconnectMonitor in particular) from triggering that
        // teardown when nothing has actually changed.
        let currentEndpoint = lattice.configuration.wssEndpoint
        let currentAuth = lattice.configuration.authorizationToken
        let incomingAuth = joinCode ?? RoomStore.openRoomBearer
        if currentEndpoint == endpoint && currentAuth == incomingAuth {
            Log.line(
                "room-instance",
                "swap NO-OP — endpoint+joinCode match current connection (\(oldFile))")
            return
        }

        Log.line(
            "room-instance",
            "swap ENTER → \(endpoint.absoluteString) joinCode=\(joinCode != nil ? "present" : "nil") oldLattice=\(oldFile)")

        // Snapshot stable identity for re-link after reopen.
        let selfMemberGlobalId = selfMember?.globalId
        let sessionCode = self.roomCode

        // Cancel observers / tasks tied to the old Lattice.
        catchUpTask?.cancel()
        catchUpTask = nil
        messageObserver?.cancel()
        messageObserver = nil

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
        Log.line("room-instance", "swap CLOSING old lattice file=\(oldFile)")
        lattice.close()
        Log.line("room-instance", "swap CLOSED old lattice file=\(oldFile)")

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
        // Re-arm the multi-purpose ChatMessage observer on the new
        // Lattice. Same `messageCutoff` filter still applies — historical
        // rows replayed during catch-up are stamped with their original
        // createdAt and stay older than the cutoff captured at instance
        // creation.
        startMessageObserver()
        // Re-arm the reconnect monitor on the new Lattice. The OLD
        // C++-side handler context was released when `lattice.close()`
        // ran above, so any in-flight callback for the closed Lattice
        // is gone; only the new one watches the new connection.
        installReconnectMonitor()
        Log.line(
            "room-instance",
            "swap EXIT newLattice=\(newLattice.configuration.fileURL.lastPathComponent)")
    }

    // MARK: - Peer-side reconnect monitor

    /// Peer-only. Lazily constructs `PeerReconnectMonitor` and
    /// registers an `onSyncStateChange` callback on the current
    /// (MainActor-resident) `Lattice`. The callback's only job is to
    /// pump the bool into the monitor actor; the monitor owns the
    /// timer, the attempt count, and the eventual hop back here for
    /// `swap()`.
    ///
    /// Called once at peer creation and again after every `swap()`,
    /// because each `swap()` produces a fresh Lattice with its own
    /// C++ callback slot. The new callback is registered with a fresh
    /// generation so any in-flight callback against the OLD Lattice
    /// short-circuits on the monitor's generation check.
    private func installReconnectMonitor() {
        guard !isHost, let endpoint = lattice.configuration.wssEndpoint else { return }

        // Lazy-construct so the monitor instance survives across
        // `swap()` calls — same exp-backoff state machine, just
        // re-armed against the fresh Lattice.
        let monitor: PeerReconnectMonitor
        if let existing = reconnectMonitor {
            monitor = existing
        } else {
            monitor = PeerReconnectMonitor(owner: self, endpoint: endpoint, joinCode: joinCode)
            reconnectMonitor = monitor
        }

        // Capture the MainActor lattice value so the registration call
        // happens on the isolation that owns it. The callback's body is
        // intentionally tiny: pump the bool into the monitor actor.
        let lattice = self.lattice
        let join = joinCode
        Task { @MainActor in
            let gen = await monitor.arm(endpoint: endpoint, joinCode: join)
            lattice.onSyncStateChange { connected in
                Task { await monitor.handleStateChange(connected: connected, gen: gen) }
            }
        }
    }

    // MARK: - Host-side cancel observer

    /// Host-only. Watches `Turn` rows for any flipping
    /// `cancelRequested` to true while still streaming — that's the
    /// signal (from a local ESC or a peer's ESC propagated via
    /// Lattice sync) that someone wants to interrupt the in-flight
    /// `claude` subprocess. Stopping the driver triggers the same
    /// cleanup path used when claude exits naturally:
    /// `closeTurnOnEof` flips `status` → `.errored`, pending
    /// assistant text flushes, orphaned `AskQuestion` rows cancel.
    ///
    /// Wired only from the `host()` factory; `peer()` never calls
    /// this. The internal guard is belt-and-suspenders for any
    /// future caller that might mis-wire the peer path.
    private func startCancelObserver() {
        guard isHost, driver != nil else { return }
        Log.line("room-host", "cancel observer starting room=\(self.roomCode)")
        cancelObserver = lattice.observe(Turn.self) { @Sendable [weak self] change in
            guard case .update = change else { return }
            Task { @MainActor [weak self] in
                await self?.checkCancelRequested()
            }
        }
    }

    private func checkCancelRequested() async {
        guard isHost, !cancelInProgress, let driver else { return }
        let target = lattice.objects(Turn.self)
            .where { $0.status == .streaming && $0.cancelRequested == true }
            .first
        guard target != nil else { return }
        cancelInProgress = true
        Log.line("room-host", "cancel requested — stopping claude subprocess")
        await driver.stop()
        let m = ChatMessage()
        m.kind = .system
        m.text = "*** turn interrupted"
        m.session = session
        lattice.add(m)
        cancelInProgress = false
    }

    // MARK: - ChatMessage insert observer

    /// Wires the multi-purpose ChatMessage observer. Two consumers:
    /// (1) host-only — forward each new row's globalId to
    /// `TurnManager.ingest`, so it can decide whether to fire the
    /// driver. Per-row filtering (.side / .system / assistant-authored)
    /// happens inside TurnManager.
    /// (2) anyone — fire `onForeignMessage` for non-self user/action
    /// messages newer than `messageCutoff`. RoomsModel sets that
    /// callback to bell the terminal when a non-active room receives
    /// traffic.
    private func startMessageObserver() {
        Log.line("room", "message observer starting (host=\(self.isHost))")
        messageObserver = lattice.observe(ChatMessage.self) { @Sendable [weak self] change in
            guard case .insert(let rowId) = change else { return }
            Task { @MainActor [weak self] in
                self?.handleMessageInsert(rowId: rowId)
            }
        }
    }

    @MainActor
    private func handleMessageInsert(rowId: Int64) {
        guard let msg = lattice.object(ChatMessage.self, primaryKey: rowId),
              let gid = msg.globalId
        else { return }
        // (1) Host turn-manager dispatch.
        if turnManager != nil {
            Task { [weak self] in
                await self?.forwardToTurnManager(globalId: gid)
            }
        }
        // (2) Foreign-message bell. Skip catch-up replays, system /
        // assistant rows, and self-authored inserts.
        guard msg.createdAt > messageCutoff,
              msg.kind == .user || msg.kind == .action,
              let myId = selfMember?.globalId,
              msg.author?.globalId != myId
        else { return }
        onForeignMessage?()
    }

    private func forwardToTurnManager(globalId: UUID) async {
        guard let turnManager else { return }
        await turnManager.ingest(globalId: globalId)
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
