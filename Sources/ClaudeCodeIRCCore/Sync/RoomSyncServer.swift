import Foundation
import Lattice
import NIOCore
import NIOPosix
import NIOHTTP1
import NIOWebSocket

/// WebSocket sync server for a single ClaudeCodeIRC room.
///
/// Accepts peer connections at `ws://host:port/room/<code>`, validates a
/// bearer join code, streams catch-up from the authoritative room DB on
/// connect, and relays subsequent upload frames to other connected peers.
///
/// One server = one room. Multiple rooms on the same host means multiple
/// server instances on different ephemeral ports.
///
/// Isolation: `actor`. The server owns its `Lattice` instance (resolved
/// inside `init` from a `LatticeThreadSafeReference` the caller passes in
/// — that's how Lattice crosses isolation domains, since the instance
/// itself isn't Sendable). NIO handler callbacks run on event-loop
/// threads and hop to the actor (`Task { await server.foo(...) }`)
/// before touching either Lattice or the peer registry.
public actor RoomSyncServer {
    public let roomCode: String
    /// `nil` means the room is open — any LAN peer that discovers the
    /// Bonjour advertisement can join without a bearer token. Set to a
    /// string to require `Authorization: Bearer <joinCode>` on upgrade.
    public let joinCode: String?

    let lattice: Lattice
    private let group: MultiThreadedEventLoopGroup
    private var channel: Channel?
    private var peers: [ObjectIdentifier: Channel] = [:]
    private var relayTask: Task<Void, Never>?
    /// `stop()` may be invoked more than once (e.g. by tests calling
    /// it explicitly and a deinit-style teardown calling it again).
    /// Both `Channel.close()` and `EventLoopGroup.shutdownGracefully()`
    /// hang on a duplicate call rather than returning quickly, so we
    /// gate the body on this flag.
    private var stopped: Bool = false

    /// - Parameter latticeReference: a `sendableReference` taken from a
    ///   caller-side `Lattice` handle. Resolving it here re-opens the
    ///   same underlying SQLite store inside the actor's isolation
    ///   domain, which is the only way to associate a non-Sendable
    ///   Lattice with an actor.
    public init(
        latticeReference: LatticeThreadSafeReference,
        roomCode: String,
        joinCode: String?
    ) throws {
        guard let resolved = latticeReference.resolve() else {
            throw RoomSyncError.latticeResolveFailed
        }
        self.lattice = resolved
        self.roomCode = roomCode
        self.joinCode = joinCode
        self.group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
    }

    /// Bind to an ephemeral port on all interfaces and start accepting
    /// connections. Returns the bound port so the caller can advertise
    /// it (Bonjour in production; stdout for the spike harness).
    public func start() async throws -> Int {
        let bootstrap = ServerBootstrap(group: group)
            .serverChannelOption(ChannelOptions.backlog, value: 16)
            .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .childChannelInitializer { [roomCode, joinCode] channel in
                RoomSyncServer.configurePipeline(
                    on: channel, server: self,
                    roomCode: roomCode,
                    joinCode: joinCode)
            }
            .childChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)

        let boundChannel = try await bootstrap.bind(host: "0.0.0.0", port: 0).get()
        self.channel = boundChannel
        guard let port = boundChannel.localAddress?.port else {
            throw RoomSyncError.bindFailed
        }
        Log.line("server", "bound 0.0.0.0:\(port) roomCode=\(self.roomCode) auth=\(self.joinCode == nil ? "open" : "required")")

        // Tail the audit log. Each write the host's UI makes (or a peer
        // upload applied via `lattice.receive`) fires as a new
        // AuditLog row; we broadcast it to every connected peer. Same-
        // origin entries are reapplied idempotently by Lattice's
        // globalId dedup, so sender gets its own back — fine.
        let stream = lattice.changeStream
        relayTask = Task.detached { [weak self] in
            Log.line("server", "relay task started")
            for await refs in stream {
                guard let self else { return }
                Log.line("server", "changeStream yielded \(refs.count) refs")
                await self.broadcastEntries(refs)
            }
            Log.line("server", "relay task exited")
        }

        return port
    }

    /// Idempotent. Calling `stop()` twice is a no-op the second time —
    /// both `Channel.close()` and `EventLoopGroup.shutdownGracefully()`
    /// hang on a duplicate call rather than returning quickly. The
    /// `stopped` flag short-circuits the duplicate cleanly.
    ///
    /// **Drain order matters.** The relay task does
    ///
    ///     for await refs in lattice.changeStream {
    ///         await broadcastEntries(refs)   // schedules writes on
    ///                                        // the NIO event loop
    ///     }
    ///
    /// `cancel()` only takes effect at the next suspension point. If
    /// the task is mid-`broadcastEntries`, it's already queueing work
    /// onto channels owned by `group`. Shutting `group` down while
    /// those writes are in flight produces "Cannot schedule tasks on
    /// an EventLoop that has already shut down" — which surfaces as
    /// a SIGSEGV / SIGBUS in parallel test runs that stand up multiple
    /// servers concurrently.
    ///
    /// We therefore `await task.value` after cancellation so the relay
    /// has fully exited (and any pending channel writes have either
    /// completed or been dropped on close) before we tear down the
    /// channel and group.
    public func stop() async throws {
        guard !stopped else { return }
        stopped = true
        let task = relayTask
        relayTask = nil
        task?.cancel()
        await task?.value
        try await channel?.close().get()
        channel = nil
        try await group.shutdownGracefully()
    }

    private func broadcastEntries(_ refs: [any SendableReference<AuditLog>]) {
        let resolved = refs.compactMap { $0.resolve(on: lattice) }
        guard !resolved.isEmpty else {
            Log.line("server", "broadcast skipped — no resolvable refs")
            return
        }
        guard let data = try? JSONEncoder().encode(ServerSentEvent.auditLog(resolved)) else {
            Log.line("server", "broadcast skipped — encode failed")
            return
        }
        Log.line("server", "broadcast \(resolved.count) entries to \(self.peers.count) peers")
        for channel in peers.values {
            RoomSyncConnectionHandler.write(data, on: ChannelBox(channel: channel))
        }
    }

    // MARK: - Pipeline setup (nonisolated, runs on NIO threads)

    private nonisolated static func configurePipeline(
        on channel: Channel,
        server: RoomSyncServer,
        roomCode: String,
        joinCode: String?
    ) -> EventLoopFuture<Void> {
        let expectedPath = "/room/\(roomCode)"
        let expectedAuth = joinCode.map { "Bearer \($0)" }

        let upgrader = NIOWebSocketServerUpgrader(
            shouldUpgrade: { channel, head in
                let pathOnly = head.uri.split(separator: "?", maxSplits: 1)
                    .first.map(String.init) ?? head.uri
                Log.line("server", "upgrade request uri=\(head.uri) remote=\(channel.remoteAddress?.description ?? "?")")
                guard pathOnly == expectedPath else {
                    Log.line("server", "reject: path=\(pathOnly) != \(expectedPath)")
                    return channel.eventLoop.makeSucceededFuture(nil)
                }
                if let expectedAuth {
                    guard head.headers["Authorization"].first == expectedAuth else {
                        Log.line("server", "reject: auth mismatch (got=\(head.headers["Authorization"].first ?? "nil"))")
                        return channel.eventLoop.makeSucceededFuture(nil)
                    }
                }
                Log.line("server", "accept upgrade")
                return channel.eventLoop.makeSucceededFuture(HTTPHeaders())
            },
            upgradePipelineHandler: { channel, head in
                let lastEventId = parseLastEventId(uri: head.uri)
                let handler = RoomSyncConnectionHandler(
                    server: server, lastEventId: lastEventId)
                return channel.pipeline.addHandler(handler)
            })

        let httpHandler = HTTPUpgradeRejectHandler()
        let config = NIOHTTPServerUpgradeConfiguration(
            upgraders: [upgrader],
            completionHandler: { ctx in
                ctx.pipeline.removeHandler(httpHandler, promise: nil)
            })

        return channel.pipeline.configureHTTPServerPipeline(withServerUpgrade: config)
            .flatMap { channel.pipeline.addHandler(httpHandler) }
    }

    private nonisolated static func parseLastEventId(uri: String) -> UUID? {
        guard let queryStart = uri.firstIndex(of: "?") else { return nil }
        let query = uri[uri.index(after: queryStart)...]
        for pair in query.split(separator: "&") {
            let kv = pair.split(separator: "=", maxSplits: 1)
            guard kv.count == 2, kv[0] == "last-event-id" else { continue }
            return UUID(uuidString: String(kv[1]))
        }
        return nil
    }

    // MARK: - Peer registry

    func registerPeer(_ box: ChannelBox) {
        peers[box.id] = box.channel
    }

    func unregisterPeer(_ box: ChannelBox) {
        peers.removeValue(forKey: box.id)
    }

    /// Peer channels excluding the sender — the fan-out set for a relay.
    func peerChannels(excluding sender: ChannelBox) -> [ChannelBox] {
        peers.compactMap { $0.key == sender.id ? nil : ChannelBox(channel: $0.value) }
    }

    // MARK: - Lattice pass-throughs

    /// Apply an inbound audit-log upload and return the global IDs that
    /// were actually persisted (what we ack to the sender).
    func receive(_ data: Data) throws -> [UUID] {
        try lattice.receive(data)
    }

    /// Encode one page of audit-log catch-up as a `ServerSentEvent.auditLog`
    /// JSON frame. Done entirely on-actor because neither
    /// `TableResults<AuditLog>` nor `AuditLog` is Sendable — returning
    /// `Data` is the clean cross-isolation hand-off.
    ///
    /// Returns `nil` when the page would be empty, signaling the caller
    /// to stop paging.
    func catchUpPage(
        checkpoint: UUID?, offset: Int64, limit: Int64
    ) throws -> Data? {
        let results = lattice.eventsAfter(globalId: checkpoint)
        let page = results.snapshot(limit: limit, offset: offset)
        if page.isEmpty { return nil }
        let event = ServerSentEvent.auditLog(page)
        return try JSONEncoder().encode(event)
    }

    // MARK: - Spike writer (host-side convenience)

    /// Test helper for the P3 spike — inserts a ChatMessage on the
    /// host's side of the room DB. The audit-log insert triggers the
    /// same relay path as any remote peer's upload, so peers observe
    /// it via their sync connections.
    public func insertSystemChatMessage(_ text: String) {
        let m = ChatMessage()
        m.kind = .system
        m.text = text
        lattice.add(m)
    }
}

public enum RoomSyncError: Error {
    case bindFailed
    case latticeResolveFailed
}

/// Sendable wrapper around a NIO `Channel`. NIO's Channel protocol only
/// conforms to the legacy `_NIOPreconcurrencySendable`, so Swift 6's
/// region-based isolation checker refuses transfers of bare `Channel`
/// into actor methods. Wrapping it lets us cross the boundary without
/// compromising correctness — the actor uses the channel only to queue
/// frame writes, which NIO dispatches to the channel's event loop
/// internally (thread-safe by construction).
struct ChannelBox: @unchecked Sendable, Hashable {
    let channel: Channel
    var id: ObjectIdentifier { ObjectIdentifier(channel) }

    static func == (lhs: ChannelBox, rhs: ChannelBox) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

/// Rejects HTTP requests that weren't upgraded to WebSocket. With only
/// `/room/<code>` as a valid route, anything else is garbage.
///
/// `@unchecked Sendable`: the NIO upgrade API passes the handler through
/// a `@Sendable` completion closure. ChannelHandler instances live on
/// one event loop at a time and aren't mutated off it, so the flag is
/// correct — Swift's checker just can't see through the pipeline API.
final class HTTPUpgradeRejectHandler: ChannelInboundHandler, RemovableChannelHandler, @unchecked Sendable {
    typealias InboundIn = HTTPServerRequestPart
    typealias OutboundOut = HTTPServerResponsePart

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let part = unwrapInboundIn(data)
        guard case .head = part else { return }
        var headers = HTTPHeaders()
        headers.add(name: "Connection", value: "close")
        headers.add(name: "Content-Length", value: "0")
        let head = HTTPResponseHead(version: .http1_1, status: .badRequest, headers: headers)
        context.write(wrapOutboundOut(HTTPServerResponsePart.head(head)), promise: nil)
        context.writeAndFlush(wrapOutboundOut(HTTPServerResponsePart.end(nil)))
            .whenComplete { _ in context.close(promise: nil) }
    }
}
