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
        for code in codes where !joined.contains(code) {
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
            directoryPublisher: directoryPublisher)
        joinedRooms.append(instance)
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
        let me: Member
        if let existing = session.host {
            existing.nick = prefs.nick   // user may have /nick'd since last run
            me = existing
        } else {
            // Defensive: file had a Session but no host link. Insert one
            // with our current nick + flag so the room is consistent.
            let m = Member()
            m.nick = prefs.nick
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
