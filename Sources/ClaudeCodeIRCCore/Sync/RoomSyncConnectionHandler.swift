import Foundation
import Lattice
import NIOCore
import NIOWebSocket

/// Per-peer NIO WebSocket handler for `RoomSyncServer`.
///
/// Responsibilities:
///   • Stream audit-log catch-up on upgrade (`?last-event-id` → everything
///     after that globalId, paged in chunks of 1000).
///   • On each binary upload frame, apply via `lattice.receive(...)`,
///     return an ack frame to the sender, and relay the original frame
///     bytes to the other connected peers in the room.
///   • Respond to control frames: close, ping. No pong keepalive logic —
///     NIO's `NIOWebSocketServerUpgrader` doesn't set one up by default,
///     and for a LAN tool that's fine.
///
/// The handler captures a reference to the `RoomSyncServer` actor. All
/// state mutations (peer registry) and Lattice calls hop onto the actor
/// via `Task { await ... }`; handler methods themselves are synchronous
/// NIO callbacks running on an event-loop thread.
final class RoomSyncConnectionHandler: ChannelInboundHandler {
    typealias InboundIn = WebSocketFrame
    typealias OutboundOut = WebSocketFrame

    private let server: RoomSyncServer
    private let lastEventId: UUID?

    /// Continuation buffer for fragmented binary frames. Lattice uploads
    /// fit in a single frame at our expected message sizes (~KBs), but
    /// the spec allows fragmentation so we accumulate `.continuation`
    /// frames until `fin == true`.
    private var binaryBuffer: ByteBuffer?

    init(server: RoomSyncServer, lastEventId: UUID?) {
        self.server = server
        self.lastEventId = lastEventId
    }

    // MARK: - Lifecycle

    func channelActive(context: ChannelHandlerContext) {
        let box = ChannelBox(channel: context.channel)
        let server = self.server
        let checkpoint = self.lastEventId
        Task.detached { await connectionOpened(server: server, box: box, checkpoint: checkpoint) }
    }

    func channelInactive(context: ChannelHandlerContext) {
        let box = ChannelBox(channel: context.channel)
        let server = self.server
        Task.detached { await connectionClosed(server: server, box: box) }
    }

    // MARK: - Frame dispatch

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let frame = unwrapInboundIn(data)
        switch frame.opcode {
        case .connectionClose:
            // Echo back and close. NIO tracks close-frame state; once
            // both sides have closed the channel is torn down.
            var data = frame.unmaskedData
            let closeFrame = WebSocketFrame(fin: true, opcode: .connectionClose, data: data.readSlice(length: min(2, data.readableBytes)) ?? ByteBuffer())
            context.writeAndFlush(wrapOutboundOut(closeFrame))
                .whenComplete { _ in context.close(promise: nil) }

        case .ping:
            var data = frame.unmaskedData
            let pong = WebSocketFrame(fin: true, opcode: .pong, data: data.readSlice(length: data.readableBytes) ?? ByteBuffer())
            context.writeAndFlush(wrapOutboundOut(pong), promise: nil)

        case .binary:
            var data = frame.unmaskedData
            if frame.fin {
                // Whole frame in one go.
                processUpload(
                    bytes: Data(data.readableBytesView),
                    originalFrame: frame,
                    channel: context.channel)
            } else {
                binaryBuffer = data
            }

        case .continuation:
            guard var acc = binaryBuffer else { return }
            var data = frame.unmaskedData
            acc.writeBuffer(&data)
            if frame.fin {
                binaryBuffer = nil
                processUpload(
                    bytes: Data(acc.readableBytesView),
                    originalFrame: frame,
                    channel: context.channel)
            } else {
                binaryBuffer = acc
            }

        case .text:
            // Lattice's client writes binary frames exclusively; text
            // frames are unexpected. Ignore for spike; real server
            // would log and maybe close.
            return

        default:
            return
        }
    }

    // MARK: - Upload pipeline

    private func processUpload(
        bytes: Data,
        originalFrame: WebSocketFrame,
        channel: Channel
    ) {
        let server = self.server
        let senderBox = ChannelBox(channel: channel)
        Task.detached { await handleUpload(server: server, sender: senderBox, bytes: bytes) }
    }

    // MARK: - Frame writer

    /// Write a binary WebSocket frame (unmasked, final) containing
    /// `bytes`. Safe to call from any thread — the NIO pipeline
    /// dispatches the write to the channel's event loop.
    static func write(_ bytes: Data, on box: ChannelBox) {
        let channel = box.channel
        var buf = channel.allocator.buffer(capacity: bytes.count)
        buf.writeBytes(bytes)
        let frame = WebSocketFrame(fin: true, opcode: .binary, data: buf)
        channel.writeAndFlush(frame, promise: nil)
    }
}

// MARK: - Free async helpers
//
// These live outside the handler class because Swift 6's region-based
// isolation checker refuses to analyze a `Task { … }` spawned from a
// ChannelHandler method that captures non-Sendable NIO types
// (`RoomSyncConnectionHandler` itself isn't `Sendable`). Lifting the
// async work to top-level functions that take only Sendable parameters
// — the actor, a `ChannelBox`, and plain values — sidesteps the check
// entirely. Semantics are identical.

func connectionOpened(server: RoomSyncServer, box: ChannelBox, checkpoint: UUID?) async {
    Log.line("server-conn", "connection opened (checkpoint=\(checkpoint?.uuidString ?? "nil"))")
    await server.registerPeer(box)
    let pageSize: Int64 = 1000
    var offset: Int64 = 0
    var pagesSent = 0
    while true {
        let pageData: Data?
        do {
            pageData = try await server.catchUpPage(
                checkpoint: checkpoint, offset: offset, limit: pageSize)
        } catch {
            Log.line("server-conn", "catch-up encode error: \(error)")
            return
        }
        guard let data = pageData else { break }
        RoomSyncConnectionHandler.write(data, on: box)
        pagesSent += 1
        offset += pageSize
    }
    Log.line("server-conn", "catch-up complete (\(pagesSent) pages sent)")
}

func connectionClosed(server: RoomSyncServer, box: ChannelBox) async {
    Log.line("server-conn", "connection closed")
    await server.unregisterPeer(box)
}

func handleUpload(server: RoomSyncServer, sender: ChannelBox, bytes: Data) async {
    Log.line("server-conn", "upload received (\(bytes.count) bytes)")
    do {
        let applied = try await server.receive(bytes)
        Log.line("server-conn", "applied \(applied.count) audit entries → ack")
        let ackEvent = ServerSentEvent.ack(applied)
        let ackData = try JSONEncoder().encode(ackEvent)
        RoomSyncConnectionHandler.write(ackData, on: sender)
        // Fan-out is handled by the server's changeStream relay —
        // `lattice.receive(bytes)` above writes new AuditLog rows, which
        // fire the relay and broadcast to every peer (including sender,
        // who idempotently reapplies its own entries).
    } catch {
        Log.line("server-conn", "receive error: \(error)")
    }
}
