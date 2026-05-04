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
    /// Public so child views (sidebar's group section) can attach a
    /// `@Query LocalGroup` against `prefs.lattice` via the `\.lattice`
    /// environment override — the active room's lattice is the
    /// default but doesn't contain `LocalGroup` rows.
    public let prefsLattice: Lattice

    /// Ordered list of rooms this instance has joined. The sessions
    /// sidebar renders one row per entry; Alt+1..9 maps to the Nth
    /// element by index (1-based to match the hotkey label).
    public var joinedRooms: [RoomInstance] = []

    /// Persisted-but-not-joined rooms — the `<code>.lattice` files on
    /// disk that we haven't currently `host()`ed or `join()`ed. One
    /// `Lattice` instance per room is held alive so the sidebar's
    /// child views can attach `@Query Session` against it via the
    /// `\.lattice` environment and react to live writes (e.g. nick
    /// changes, name edits made in another instance) without us
    /// maintaining a parallel snapshot model.
    ///
    /// Promoting a recent room to a joined one (via `reopenAsHost` or
    /// `reopenAsPeer`) drops the entry here, closes its idle Lattice,
    /// and reopens with the appropriate role-specific configuration
    /// (`openHost` for hosts; `openPeer` with `wssEndpoint` + bearer
    /// for peers).
    public var recentLattices: [(code: String, lattice: Lattice)] = []

    /// Mirror of `DirectoryClient`'s latest snapshot. The client lives
    /// off-main as an actor; this property is updated on MainActor
    /// from a snapshot-stream consumer task. Keyed by `groupId`
    /// (`"public"` for the public bucket, `LocalGroup.hashHex` for
    /// each group). Empty until the first poll completes.
    public var directoryRoomsByGroup: [String: [DirectoryAPI.ListedRoom]] = [:]

    public let directoryClient: DirectoryClient

    /// Currently-active room's `RoomInstance.id`. `nil` means the
    /// "welcome" empty state is shown in the center pane.
    public var activeRoomId: UUID?

    /// One-shot user-facing notice posted by `RoomsModel` itself
    /// (e.g. "kicked from <room>") that the workspace view drains
    /// into the active room's chat as a system message. The view is
    /// responsible for clearing this back to `nil` after rendering.
    public var pendingNotice: String?

    /// Convenience accessor — `nil` while on the welcome state.
    public var activeRoom: RoomInstance? {
        guard let id = activeRoomId else { return nil }
        return joinedRooms.first(where: { $0.id == id })
    }

    public init() {
        let prefsURL = RoomPaths.prefsURL
        let prefsLattice: Lattice
        let prefs: AppPreferences
        do {
            try FileManager.default.createDirectory(
                at: prefsURL.deletingLastPathComponent(),
                withIntermediateDirectories: true)
            prefsLattice = try Lattice(
                for: [AppPreferences.self, LocalGroup.self],
                configuration: .init(fileURL: prefsURL))
            if let existing = prefsLattice.objects(AppPreferences.self).first {
                prefs = existing
            } else {
                let p = AppPreferences()
                prefsLattice.add(p)
                prefs = p
            }
        } catch {
            fatalError("Could not open prefs at \(prefsURL.path): \(error)")
        }
        self.prefsLattice = prefsLattice
        self.prefs = prefs

        // Build the directory client up front. Closures capture the
        // prefs Lattice + AppPreferences row by reference; the actor
        // hops back to MainActor inside each provider call, so reads
        // are isolation-safe.
        self.directoryClient = DirectoryClient(
            endpointProvider: { @MainActor [weak prefs] in
                if let env = ProcessInfo.processInfo.environment["CCIRC_DIRECTORY_URL"],
                   !env.isEmpty, let url = URL(string: env) {
                    return url
                }
                return prefs.flatMap { URL(string: $0.directoryEndpointURL) }
            },
            groupIdsProvider: { @MainActor [prefsLattice] in
                // `Lattice` is a value type, captured by copy; safe to
                // strong-capture (no retain cycle, nothing to leak).
                let groups = prefsLattice.objects(LocalGroup.self).map(\.hashHex)
                return [GroupID.publicBucket] + groups
            })

        browser.start()
        // Disk scan deferred to a Task so init returns immediately —
        // lobby renders without waiting on N file opens.
        Task { [weak self] in
            await self?.loadPersistedRooms()
        }
        // Snapshot mirror — reflects the actor's stream onto MainActor
        // state so views can read it directly via the @Observable
        // property. Cancelled implicitly when the model deinits.
        Task { [weak self] in
            guard let stream = self?.directoryClient.roomsByGroupStream else { return }
            for await snapshot in stream {
                guard let self else { return }
                self.directoryRoomsByGroup = snapshot
            }
        }
        Task { [client = directoryClient] in
            await client.start()
        }
    }

    deinit {
        browser.stop()
        Task { [client = directoryClient] in
            await client.stop()
        }
    }

    /// Open every `<code>.lattice` file in `RoomPaths.rootDirectory`
    /// that we haven't already joined and stash a Lattice handle in
    /// `recentLattices`. Files for which we can't fetch a `Session`
    /// row (corrupt, schema mismatch) are skipped + closed.
    private func loadPersistedRooms() async {
        let dir = RoomPaths.rootDirectory
        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: dir,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles])
        else { return }
        let codes = urls
            .filter { $0.pathExtension == "lattice" }
            .map { $0.deletingPathExtension().lastPathComponent }
            .sorted()
        let joined = Set(joinedRooms.map(\.roomCode))
        let alreadyRecent = Set(recentLattices.map(\.code))
        for code in codes where !joined.contains(code) && !alreadyRecent.contains(code) {
            do {
                let lattice = try Lattice(
                    for: RoomStore.schema,
                    configuration: .init(fileURL: dir.appending(path: "\(code).lattice")))
                // Skip files without a matching Session row — could be
                // an empty file that never finished bootstrapping.
                guard lattice.objects(Session.self).first(where: { $0.code == code }) != nil else {
                    lattice.close()
                    continue
                }
                recentLattices.append((code: code, lattice: lattice))
            } catch {
                Log.line("rooms", "skip recent \(code): \(error)")
            }
        }
        Log.line("rooms", "loaded \(self.recentLattices.count) recent rooms")
    }

    /// Drop a recent entry — closes its idle Lattice and removes it
    /// from `recentLattices`. Called at the start of `reopenAs*` so
    /// the same on-disk file isn't held by two `Lattice` instances at
    /// once across the role transition.
    private func dropRecent(code: String) {
        guard let idx = recentLattices.firstIndex(where: { $0.code == code }) else { return }
        let entry = recentLattices.remove(at: idx)
        entry.lattice.close()
    }

    /// Reconcile in-flight rows left behind when a previous host process
    /// exited abruptly (Ctrl+C, crash, hard kill). The driver and
    /// `ApprovalMcpShim` subprocesses died with the parent — anything
    /// they wrote in non-terminal state is now an orphan: nothing is
    /// tailing votes, nothing is going to flip Turn.status to .done.
    /// Without this pass the UI either renders a permanent "thinking"
    /// strip (off `WorkspaceView.streamingTurn`), or shows an
    /// AskUserQuestion ballot whose votes can't route back to claude.
    ///
    /// Host-only by construction — only `reopenAsHost` calls this.
    /// Peer rejoin must NOT terminate these rows: the host could still
    /// be alive elsewhere, and we'd be racing its writes.
    ///
    /// Mirrors the existing in-driver `cancelOrphanedAskQuestions` at
    /// `ClaudeCLIDriver.cancelOrphanedAskQuestions()`; this is the
    /// app-restart twin (the in-driver one only runs from a live
    /// process, not on cold open).
    private func terminateOrphanedInFlightRows(lattice: Lattice, code: String) {
        let now = Date()
        let orphanTurns = Array(lattice.objects(Turn.self)
            .where { $0.status == .streaming })
        let orphanAsks = Array(lattice.objects(AskQuestion.self)
            .where { $0.status == .pending })
        let orphanTools = Array(lattice.objects(ToolEvent.self)
            .where { $0.status == .running })
        // ApprovalRequest has no `.cancelled` — `.denied` is the safe
        // host-takeover default (better than leaving the Y/A/D bar
        // mounted on a request whose shim is dead).
        let orphanApprovals = Array(lattice.objects(ApprovalRequest.self)
            .where { $0.status == .pending })
        let total = orphanTurns.count + orphanAsks.count + orphanTools.count + orphanApprovals.count
        guard total > 0 else { return }
        Log.line("rooms",
                 "reopen-as-host code=\(code) terminating orphans: " +
                 "\(orphanTurns.count) streaming Turn, \(orphanAsks.count) pending AskQuestion, " +
                 "\(orphanTools.count) running ToolEvent, \(orphanApprovals.count) pending ApprovalRequest")
        lattice.transaction {
            for t in orphanTurns where t.status == .streaming {
                t.status = .errored
                t.endedAt = now
            }
            for q in orphanAsks where q.status == .pending {
                q.status = .cancelled
                q.cancelReason = "host process exited"
                q.answeredAt = now
            }
            for e in orphanTools where e.status == .running {
                e.status = .errored
                e.endedAt = now
            }
            for r in orphanApprovals where r.status == .pending {
                r.status = .denied
                r.decidedAt = now
            }
        }
    }

    // MARK: - Hosting + joining

    /// Host a new room. Opens the authoritative Lattice, inserts the
    /// `Session` + host `Member`, stands up `RoomSyncServer`, publishes
    /// via Bonjour, and appends + activates a new host-mode
    /// `RoomInstance`. For non-private visibilities, also constructs a
    /// `TunnelManager` so the room is reachable from the open internet
    /// — but the LAN side is fully usable the moment this method
    /// returns; the tunnel resolves asynchronously inside the
    /// `RoomInstance`'s bridge task and writes onto `Session.publicURL`
    /// when the URL lands.
    ///
    /// - Parameter requireJoinCode: when `true`, generates a 6-char
    ///   bearer code and the server rejects upgrades that don't
    ///   present it; `false` means any LAN peer that discovers the
    ///   room can join.
    /// - Parameter visibility: `.private` (default) keeps the room LAN-
    ///   only via Bonjour. `.public` and `.group(hashHex:)` opt into
    ///   the directory-listed flow (L2/L3) and require the
    ///   `cloudflared` tunnel; the tunnel's resolved URL appears on
    ///   `Session.publicURL` once ready.
    /// Errors thrown by `host(...)` before the room is created. Caught
    /// by `HostFormOverlay` and rendered inline so the user can fix the
    /// precondition and resubmit.
    public enum HostError: Error, LocalizedError {
        /// Visibility is `.public` or `.group` but `cloudflared` is not
        /// on PATH. Public/Group rooms route through a Cloudflare quick
        /// tunnel; without it there is no public URL to expose, so we
        /// refuse to host rather than silently downgrading to LAN-only
        /// (which would leave the user staring at `[public:pending]`
        /// forever with no signal as to why).
        case cloudflaredMissing

        public var errorDescription: String? {
            switch self {
            case .cloudflaredMissing:
                return "cloudflared not installed — run: brew install cloudflared"
            }
        }
    }

    @discardableResult
    public func host(
        name: String,
        cwd: String,
        mode: PermissionMode,
        requireJoinCode: Bool,
        visibility: SessionVisibility = .private,
        groupHashHex: String? = nil
    ) async throws -> RoomInstance {
        // Cloudflared is a hard prerequisite for non-private rooms.
        // Check it before allocating any per-room state so a
        // resubmission after `brew install cloudflared` starts clean.
        if visibility != .private, Doctor.which("cloudflared") == nil {
            Log.line("rooms", "host refused: cloudflared not on PATH (visibility=\(visibility.rawValue))")
            throw HostError.cloudflaredMissing
        }

        let roomCode = Self.generateCode()
        let joinCode: String? = requireJoinCode ? Self.generateCode() : nil
        Log.line("rooms", "host name=\(name) cwd=\(cwd) roomCode=\(roomCode) auth=\(requireJoinCode ? "required" : "open") visibility=\(visibility.rawValue)")
        let lattice = try RoomStore.openHost(code: roomCode)
        Log.line("rooms", "host lattice opened → \(lattice.configuration.fileURL.path)")

        let session = Session()
        session.code = roomCode
        session.name = name
        session.cwd = cwd
        session.permissionMode = mode
        session.joinCode = joinCode
        session.visibility = visibility
        session.groupHashHex = (visibility == .group) ? groupHashHex : nil
        lattice.add(session)

        let me = Member()
        me.nick = prefs.nick
        me.userId = prefs.userId
        me.isHost = true
        me.session = session
        lattice.add(me)
        session.host = me

        prefs.lastCwd = cwd

        return try await bringUpHost(
            lattice: lattice,
            roomCode: roomCode,
            session: session,
            selfMember: me)
    }

    /// Shared between fresh `host()` and `reopenAsHost(code:)` — given
    /// a Lattice with the Session/Member rows already in place, stand
    /// up the host-side runtime: sync server, Bonjour publisher,
    /// Claude driver, turn manager, optional tunnel manager. Returns
    /// the appended+activated `RoomInstance`.
    private func bringUpHost(
        lattice: Lattice,
        roomCode: String,
        session: Session,
        selfMember: Member
    ) async throws -> RoomInstance {
        let joinCode = session.joinCode
        let server = try RoomSyncServer(
            latticeReference: lattice.sendableReference,
            roomCode: roomCode,
            joinCode: joinCode)
        let port = try await server.start()
        Log.line("rooms", "server.start returned port=\(port)")

        let publisher = BonjourPublisher(
            name: session.name,
            port: Int32(port),
            roomCode: roomCode,
            hostNick: prefs.nick,
            cwd: session.cwd,
            requiresJoinCode: joinCode != nil)
        publisher.publish()
        Log.line("rooms", "bonjour publish name=\(session.name) port=\(port) nick=\(self.prefs.nick)")

        let driver = try await ClaudeCLIDriver(
            latticeRef: lattice.sendableReference,
            sessionRef: session.sendableReference,
            cwd: session.cwd)
        Log.line("rooms", "claude driver constructed for cwd=\(session.cwd) mode=\(session.permissionMode)")

        let turnManager = try await TurnManager(
            driver: driver,
            latticeRef: lattice.sendableReference,
            sessionRef: session.sendableReference)
        Log.line("rooms", "turn manager constructed")

        // Tunnel only for non-private rooms. Owned by `RoomInstance` so
        // teardown (incl. `tunnel.stop()`) lives in one place. The
        // bridge task inside `RoomInstance.host()` runs the actual
        // `cloudflared` start and propagates URL changes to
        // `Session.publicURL` — never blocks LAN usability.
        let tunnelManager: TunnelManager?
        let directoryPublisher: DirectoryPublisher?
        if session.visibility != .private {
            tunnelManager = TunnelManager(localPort: UInt16(port))
            directoryPublisher = makeDirectoryPublisher(session: session)
        } else {
            tunnelManager = nil
            directoryPublisher = nil
        }

        // Statusline driver — only on the host, regardless of room
        // visibility. The user's `~/.claude/settings.json` may opt out
        // (no `statusLine` key); the driver itself short-circuits when
        // no command is configured, so it's safe to construct
        // unconditionally.
        let sessionRef = session.sendableReference
        let latticeRef = lattice.sendableReference
        let statusLineDriver = StatusLineDriver(
            context: .init(
                cwd: session.cwd,
                sessionId: session.claudeSessionId.uuidString,
                sessionName: session.name,
                appVersion: "0.0.1"),
            onOutput: { @Sendable output in
                guard let lattice = latticeRef.resolve(),
                      let session = sessionRef.resolve(on: lattice)
                else { return }
                session.hostStatusLine = output
            })

        let instance = RoomInstance.host(
            lattice: lattice,
            roomCode: roomCode,
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
            statusLineDriver: statusLineDriver)
        joinedRooms.append(instance)
        wireBell(instance)
        activeRoomId = instance.id
        return instance
    }

    /// Build a `DirectoryPublisher` for a non-private room. The
    /// publisher's wssURL / publishVersion accessors hop back to
    /// `@MainActor` to read the live `Session`/`AppPreferences` rows.
    /// `groupId` is `"public"` for public rooms or the
    /// `Session.groupHashHex` for group rooms; `.private` rooms don't
    /// publish at all.
    private func makeDirectoryPublisher(session: Session) -> DirectoryPublisher? {
        guard let endpoint = directoryEndpointURL() else {
            Log.line("rooms", "no directory endpoint configured — skipping publisher")
            return nil
        }
        let groupId: String
        switch session.visibility {
        case .private: return nil
        case .public:  groupId = GroupID.publicBucket
        case .group:   groupId = session.groupHashHex ?? GroupID.publicBucket
        }
        let prefs = self.prefs
        let sessionRef = session
        let roomCode = session.code
        return DirectoryPublisher(
            endpoint: endpoint,
            roomId: roomCode,
            roomName: session.name,
            hostHandle: prefs.nick,
            groupId: groupId,
            // Echoes the host's join-code requirement to peers via
            // the directory listing so the join overlay can skip
            // prompting for a code on open rooms.
            requireJoinCode: session.joinCode != nil,
            // `cloudflared` exposes the tunnel as `https://*.trycloudflare.com`
            // (it's a Cloudflare HTTPS edge that upgrades to WebSocket
            // on demand). The Worker rejects non-`wss://` URLs, and a
            // peer's `Lattice.Configuration.wssEndpoint` needs the
            // room path. Rewrite both: scheme `https` → `wss`, append
            // `/room/<code>`.
            wssURLProvider: { @MainActor [weak sessionRef, roomCode] in
                guard let raw = sessionRef?.publicURL,
                      let httpsURL = URL(string: raw),
                      var components = URLComponents(url: httpsURL, resolvingAgainstBaseURL: false)
                else { return nil }
                components.scheme = "wss"
                components.path = "/room/\(roomCode)"
                return components.url
            },
            publishVersionProvider: { @MainActor [weak prefs] in
                prefs?.publishVersion ?? 0
            },
            publishVersionConsumer: { @MainActor [weak prefs] v in
                prefs?.publishVersion = v
            })
    }

    /// Resolve the directory Worker base URL. `CCIRC_DIRECTORY_URL`
    /// env override (used by `wrangler dev` against `localhost:8787`)
    /// trumps the persisted `AppPreferences.directoryEndpointURL`.
    private func directoryEndpointURL() -> URL? {
        if let env = ProcessInfo.processInfo.environment["CCIRC_DIRECTORY_URL"],
           !env.isEmpty,
           let url = URL(string: env) {
            return url
        }
        return URL(string: prefs.directoryEndpointURL)
    }

    public enum ReopenError: Error {
        case sessionNotFound
    }

    public enum CreateGroupError: Error, LocalizedError {
        case nameAlreadyExists(String)
        public var errorDescription: String? {
            switch self {
            case .nameAlreadyExists(let n): return "group '\(n)' already exists"
            }
        }
    }

    public enum DeleteGroupError: Error, LocalizedError {
        case notFound(String)
        /// `candidates` are pre-rendered `displayLabel(among:)` strings —
        /// guaranteed to disambiguate the matched rows so the error
        /// message is directly actionable ("use the hash prefix").
        case ambiguous(String, candidates: [String])
        public var errorDescription: String? {
            switch self {
            case .notFound(let q):
                return "no group matching '\(q)'"
            case .ambiguous(let q, let cs):
                return "'\(q)' matches multiple groups: "
                    + cs.joined(separator: ", ")
                    + ". Use the hash prefix to disambiguate."
            }
        }
    }

    /// Resolve a `Session.groupHashHex` to the user-facing label drawn
    /// from the local `LocalGroup` rows. Returns `nil` when the hash
    /// isn't in `prefsLattice` (e.g. peer joined a group room without
    /// holding the secret) — the caller decides the fallback (commonly
    /// a 6-char hex prefix of the hash itself).
    public func groupLabel(forHash hash: String) -> String? {
        let groups = Array(prefsLattice.objects(LocalGroup.self))
        guard let match = groups.first(where: { $0.hashHex == hash }) else {
            return nil
        }
        return match.displayLabel(among: groups)
    }

    /// Generate a brand-new group: random 32-byte secret, computed
    /// `hashHex`, persisted `LocalGroup` row, and a returned invite
    /// code (`ccirc-group:v1:<name>:<base64url(secret)>`) the caller
    /// can surface so the user shares it with peers.
    ///
    /// Throws `CreateGroupError.nameAlreadyExists` if a group with the
    /// same `name` is already in `prefs.lattice` — silently colliding
    /// would be confusing because the second `LocalGroup` would have
    /// a different `hashHex` (different secret), so any directory
    /// rooms already published under the first group's hash would
    /// silently disappear from the sidebar.
    @discardableResult
    public func createGroup(name: String) throws -> (group: LocalGroup, invite: String) {
        if prefsLattice.objects(LocalGroup.self).first(where: { $0.name == name }) != nil {
            throw CreateGroupError.nameAlreadyExists(name)
        }
        // 32 bytes = 256-bit secret. `SystemRandomNumberGenerator` is
        // cryptographically secure on Apple platforms (CSPRNG-backed),
        // and `UInt8.random(using:)` reads from it.
        var rng = SystemRandomNumberGenerator()
        let secret = Data((0..<32).map { _ in UInt8.random(in: 0...255, using: &rng) })
        let hash = GroupID.compute(secret: secret)
        let g = LocalGroup()
        g.hashHex = hash
        g.name = name
        g.secretBase64 = GroupInviteCode.base64URL(secret)
        g.addedAt = Date()
        prefsLattice.add(g)
        let invite = GroupInviteCode.encode(name: name, secret: secret)
        Log.line("rooms", "createGroup: name=\(name) hash=\(hash.prefix(8))…")
        return (g, invite)
    }

    /// Remove a `LocalGroup` row from `prefs.lattice`. The query
    /// matches against either `name` (case-insensitive equality) or
    /// `hashHex` (case-insensitive prefix), and:
    ///
    /// - 0 matches → `DeleteGroupError.notFound`
    /// - 2+ matches → `DeleteGroupError.ambiguous`, with each
    ///   candidate's `displayLabel(among:)` so the user can re-issue
    ///   `/delgroup` with the disambiguating hash prefix.
    /// - 1 match → row deleted; returns the deleted row for the
    ///   caller's confirmation message.
    ///
    /// Does NOT unpublish a hosted room from the directory — the
    /// host's `Session.groupHashHex` and the directory bucket
    /// continue independently. Peers who hold the secret keep seeing
    /// the listing. The deletion is purely local: the corresponding
    /// sidebar section disappears, and the host can no longer pick
    /// this group from `/host`'s visibility cycler.
    /// Snapshot of the deleted row's identifying fields, captured
    /// **before** `prefsLattice.delete` zeroes the live object's
    /// properties — callers want to confirm "group <name> deleted",
    /// and reading `.name` off a post-delete `LocalGroup` returns
    /// empty.
    public struct DeletedGroup: Sendable {
        public let name: String
        public let hashHex: String
    }

    @discardableResult
    public func deleteGroup(matching query: String) throws -> DeletedGroup {
        let groups = Array(prefsLattice.objects(LocalGroup.self))
        let q = query.lowercased()
        let matches = groups.filter {
            $0.name.lowercased() == q || $0.hashHex.lowercased().hasPrefix(q)
        }
        switch matches.count {
        case 0:
            throw DeleteGroupError.notFound(query)
        case 1:
            let g = matches[0]
            let snapshot = DeletedGroup(name: g.name, hashHex: g.hashHex)
            Log.line("rooms",
                "deleteGroup: name=\(snapshot.name) hash=\(snapshot.hashHex.prefix(8))…")
            prefsLattice.delete(g)
            return snapshot
        default:
            throw DeleteGroupError.ambiguous(query,
                candidates: matches.map { $0.displayLabel(among: groups) })
        }
    }

    /// Parse a `ccirc-group:v1:` paste, compute the directory bucket
    /// hash, and persist a `LocalGroup` row in `prefs.lattice`. Pasting
    /// the same invite twice is a no-op — the existing row is returned.
    /// The persisted row is what the directory client `@Query`s against
    /// to render the "Groups → <name>" sidebar sections.
    @discardableResult
    public func addGroup(invitePaste: String) throws -> LocalGroup {
        let decoded = try GroupInviteCode.decode(invitePaste)
        let hash = GroupID.compute(secret: decoded.secret)
        if let existing = prefsLattice.objects(LocalGroup.self)
            .first(where: { $0.hashHex == hash })
        {
            Log.line("rooms", "addGroup: already present hash=\(hash.prefix(8))…")
            return existing
        }
        let g = LocalGroup()
        g.hashHex = hash
        g.name = decoded.name
        g.secretBase64 = GroupInviteCode.base64URL(decoded.secret)
        g.addedAt = Date()
        prefsLattice.add(g)
        Log.line("rooms", "addGroup: inserted name=\(decoded.name) hash=\(hash.prefix(8))…")
        return g
    }

    /// Reopen a room we previously hosted. Drops the recent (read-only)
    /// Lattice, opens a fresh host one, and runs the standard host
    /// bring-up against the existing `Session`/`Member` rows. Refreshes
    /// the host `Member`'s nick to `prefs.nick` in case the user
    /// `/nick`'d in a prior session.
    @discardableResult
    public func reopenAsHost(code: String) async throws -> RoomInstance {
        Log.line("rooms", "reopen as host code=\(code)")
        dropRecent(code: code)
        let lattice = try RoomStore.openHost(code: code)
        guard let session = lattice.objects(Session.self)
            .first(where: { $0.code == code })
        else {
            lattice.close()
            throw ReopenError.sessionNotFound
        }
        terminateOrphanedInFlightRows(lattice: lattice, code: code)
        let userId = prefs.userId
        let me: Member
        if let existing = session.host {
            existing.nick = prefs.nick   // user may have /nick'd since last run
            existing.userId = userId     // defensive — pre-userId rows have a default UUID
            existing.isAway = false
            existing.awayReason = nil
            existing.lastSeenAt = Date()
            me = existing
        } else if let existing = lattice.objects(Member.self)
            .where({ $0.userId == userId })
            .first {
            // Session exists but its `host` link was never wired (or
            // got nil'd). Re-link to the Member already representing
            // us in this room rather than minting a duplicate.
            existing.nick = prefs.nick
            existing.isHost = true
            existing.isAway = false
            existing.awayReason = nil
            existing.lastSeenAt = Date()
            existing.session = session
            session.host = existing
            me = existing
        } else {
            // Defensive: file had a Session but no host or self Member.
            // Insert one with our current nick + flag so the room is
            // consistent.
            let m = Member()
            m.nick = prefs.nick
            m.userId = userId
            m.isHost = true
            m.session = session
            lattice.add(m)
            session.host = m
            me = m
        }
        return try await bringUpHost(
            lattice: lattice,
            roomCode: code,
            session: session,
            selfMember: me)
    }

    /// Reopen a room we previously peered into. Drops the recent
    /// (read-only) Lattice, opens a fresh peer one with the cached
    /// wssEndpoint + bearer, and constructs the peer `RoomInstance`.
    /// If the host's URL has rotated since we last saw it, the WS
    /// client will fail to connect and retry — peer's local transcript
    /// remains visible regardless.
    @discardableResult
    public func reopenAsPeer(
        code: String,
        wssEndpoint: URL,
        joinCode: String?
    ) throws -> RoomInstance {
        Log.line("rooms", "reopen as peer code=\(code) wss=\(wssEndpoint.absoluteString)")
        dropRecent(code: code)
        let lattice = try RoomStore.openPeer(
            code: code,
            endpoint: wssEndpoint,
            joinCode: joinCode)
        let instance = RoomInstance.peer(
            lattice: lattice,
            roomCode: code,
            joinCode: joinCode,
            prefs: prefs)
        instance.onKickedFromHost = makeKickedHandler()
        instance.onHostLeft = makeHostLeftHandler()
        joinedRooms.append(instance)
        wireBell(instance)
        activeRoomId = instance.id
        return instance
    }

    /// Join an existing room. `joinCode` is `nil` for open rooms.
    ///
    /// Drops any matching `recentLattices` entry FIRST so the same
    /// on-disk file isn't held by two `Lattice` instances at once
    /// (the idle "recent" handle vs the new peer-mode handle).
    /// Without this, the recent's `Lattice` outlives the join, the
    /// sidebar's `@Query`s still point at the recent's handle, and
    /// any subsequent close/swap collapses both — `@Query`-driven
    /// reads then SIGSEGV through a freed `db_`. Mirrors the
    /// `reopenAsPeer` / `reopenAsHost` paths.
    @discardableResult
    public func join(
        _ room: DiscoveredRoom,
        joinCode: String?
    ) throws -> RoomInstance {
        Log.line("rooms", "join room=\(room.name) code=\(room.roomCode) ws=\(room.wsURL.absoluteString) auth=\(joinCode == nil ? "open" : "required")")
        dropRecent(code: room.roomCode)
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
        instance.onKickedFromHost = makeKickedHandler()
        instance.onHostLeft = makeHostLeftHandler()
        joinedRooms.append(instance)
        wireBell(instance)
        activeRoomId = instance.id
        return instance
    }

    /// Leave a joined room. Stops its server / driver / publisher and
    /// removes it from the list. If it was active, activation shifts
    /// to the previous room (or `nil` if it was the last).
    ///
    /// Order matters: detach the view tree from the dying instance
    /// **before** awaiting `instance.leave()`. The teardown deletes
    /// the host's `selfMember` row (which on a single-host room is
    /// also `session.host`) — and any active `RoomPane` reading
    /// `room.session?.host?.nick` after that delete crashes on the
    /// freed C++ string. Flipping `activeRoomId` and removing the
    /// instance from `joinedRooms` synchronously unbinds the view
    /// before the async tear-down runs.
    public func leave(_ roomId: UUID) async {
        guard let idx = joinedRooms.firstIndex(where: { $0.id == roomId })
        else { return }
        let instance = joinedRooms.remove(at: idx)
        if activeRoomId == roomId {
            if idx > 0 {
                activeRoomId = joinedRooms[idx - 1].id
            } else {
                activeRoomId = joinedRooms.first?.id
            }
        }
        let wasHost = instance.isHost
        await instance.leave()
        // Surface the just-left room in the Recent sidebar without
        // requiring a relaunch. Host-only: peers re-join via Bonjour
        // discovery, and `activateRecent` would route them back through
        // `reopenAsPeer` which requires a cached `publicURL` (LAN peers
        // don't have one). Adding peer auto-eject rooms to recents also
        // races the rejoin path's lattice open against the recent
        // handle's close.
        if wasHost {
            await loadPersistedRooms()
        }
    }

    /// Leave AND delete the joined room. Same teardown as `leave(_:)`
    /// (which stops the directory publisher / sync server / driver and
    /// removes the local Member row), then drops any cached recent-
    /// lattice handle for the same code and removes the on-disk
    /// `<rooms>/<code>.lattice` file. The room disappears from the
    /// Recent sidebar after this.
    ///
    /// Joined-only — for v0.0.1 we only support deleting the active
    /// room (the one the user is in). Recent-only rooms can be
    /// removed by `scripts/wipe-lattices.sh` or by reopening then
    /// `/delete-room`.
    public func deleteRoom(_ roomId: UUID) async {
        guard let instance = joinedRooms.first(where: { $0.id == roomId }) else {
            Log.line("rooms", "deleteRoom: no joined instance with id \(roomId)")
            return
        }
        let code = instance.roomCode
        // `leave(_:)` removes the instance from joinedRooms and runs
        // the full teardown (publisher DELETE, member-row delete, sync
        // flush, server.stop). Sync flush matters: peers must observe
        // our Member row vanish before we yank the file.
        await leave(roomId)
        // Drop any recent-lattice cache hit (loadPersistedRooms /
        // reopenAs* paths can leave a stale handle around) so the
        // SQLite lock is released before rm.
        dropRecent(code: code)
        do {
            try FileManager.default.removeItem(at: RoomPaths.storeURL(forCode: code))
            Log.line("rooms", "deleted room \(code)")
        } catch {
            Log.line("rooms", "delete room \(code) failed: \(error)")
        }
    }

    /// Closure handed to each peer `RoomInstance` so it can self-eject
    /// when the host runs `/kick` on it. Tears the instance down via
    /// `leave(_:)` first — that flips `activeRoomId` away from the
    /// kicked room — and only then sets `pendingNotice`. If we wrote
    /// the notice first, the view's drain would insert it as a system
    /// message into the still-active kicked room's lattice, which
    /// syncs the "you were kicked" line back to the host's chat
    /// history (and any other peers).
    private func makeKickedHandler() -> (UUID) async -> Void {
        return { [weak self] roomId in
            guard let self else { return }
            let name = self.joinedRooms.first(where: { $0.id == roomId })?
                .session?.name ?? "the room"
            await self.leave(roomId)
            self.pendingNotice = "you were kicked from \(name)"
        }
    }

    /// Closure handed to each peer `RoomInstance` so it can self-eject
    /// when the host runs `/leave` and the host's Member row delete
    /// syncs in. Same shape as `makeKickedHandler`: tear down via
    /// `leave(_:)` (which flips `activeRoomId` synchronously) and
    /// then post a notice. Reading `session?.name` here happens
    /// before `leave(_:)` runs, but the host-left observer already
    /// nilled out `session` to keep SwiftUI from re-rendering dead
    /// links — so use the stored room code as the user-facing label.
    private func makeHostLeftHandler() -> (UUID) async -> Void {
        return { [weak self] roomId in
            guard let self else { return }
            // `session` was nilled by `ejectIfHostLeft` to keep
            // SwiftUI from rendering dead links, so use the snapshot
            // captured in `linkToSession`. Fall back to the room
            // code if the snapshot was never taken.
            let instance = self.joinedRooms.first(where: { $0.id == roomId })
            let label = instance?.cachedSessionName
                ?? instance?.roomCode
                ?? "the room"
            await self.leave(roomId)
            self.pendingNotice = "host left \(label) — room closed"
        }
    }

    /// Optional bell hook — UI layer sets this at construction to
    /// route foreign-message events to the terminal bell. Kept as a
    /// callback (rather than RoomsModel writing BEL itself) so Core
    /// stays free of UI / terminfo dependencies; raw `\u{07}` writes
    /// also got swallowed by tmux pane bell handling and ncurses
    /// output buffering, whereas the UI's `Term.bell()` goes through
    /// terminfo via ncurses' `beep()`.
    public var onShouldBell: (() -> Void)?

    /// Wire `instance.onForeignMessage` so any non-self user/action
    /// message invokes `onShouldBell`. No active-room gating —
    /// `Term.bell()` fires unconditionally even when the user is
    /// already looking at the chat. Cheaper and simpler than focus
    /// detection; can be revisited if it gets noisy.
    private func wireBell(_ instance: RoomInstance) {
        instance.onForeignMessage = { [weak self, weak instance] in
            guard let self, let instance else { return }
            Log.line("bell", "ring (room=\(instance.roomCode))")
            self.onShouldBell?()
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
