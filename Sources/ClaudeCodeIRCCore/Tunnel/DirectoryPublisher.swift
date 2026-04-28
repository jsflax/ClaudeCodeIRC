import Foundation

/// Host-side: heartbeats `POST /publish` to the directory Worker every
/// ~30s while a non-private room is live, and emits a best-effort
/// `DELETE /publish/<roomId>` on `stop()`.
///
/// **Wiring**: created by `RoomInstance.host` only when
/// `Session.visibility != .private`. Owned by the `RoomInstance` so
/// teardown is symmetric with the rest of the host stack
/// (`RoomSyncServer`, `BonjourPublisher`, `TunnelManager`). Reads
/// `Session.publicURL` each cycle — when the tunnel restarts and
/// writes a new URL, the next heartbeat carries it without explicit
/// poking.
///
/// **Idempotence**: if `Session.publicURL` is `nil` (tunnel hasn't
/// resolved yet), `publishOnce` skips. The room appears in the
/// directory the moment the tunnel comes up and the next heartbeat
/// fires.
public actor DirectoryPublisher {
    private let endpoint: URL
    private let urlSession: URLSession

    /// Snapshot fields captured at construction. The wssURL is read
    /// fresh from `Session.publicURL` each cycle — async-provided so
    /// the actor can hop to `@MainActor` (where Session lives) without
    /// us holding a non-Sendable reference inside the actor.
    private let roomId: String
    private let roomName: String
    private let hostHandle: String
    private let groupId: String
    private let wssURLProvider: @Sendable () async -> URL?

    /// Read-modify-write of `AppPreferences.publishVersion` — bumped
    /// each successful publish. Async-provided for the same reason as
    /// `wssURLProvider`; AppPreferences is `@MainActor`-isolated.
    private let publishVersionProvider: @Sendable () async -> Int
    private let publishVersionConsumer: @Sendable (Int) async -> Void

    private var heartbeatTask: Task<Void, Never>?
    private var stopped = false

    /// Heartbeat cadence. Picked to fit comfortably within the
    /// Worker's 25s rate-limit window and to leave 6x slack against
    /// the 180s TTL.
    private static let heartbeatInterval: Duration = .seconds(30)

    public init(
        endpoint: URL,
        roomId: String,
        roomName: String,
        hostHandle: String,
        groupId: String,
        wssURLProvider: @escaping @Sendable () async -> URL?,
        publishVersionProvider: @escaping @Sendable () async -> Int,
        publishVersionConsumer: @escaping @Sendable (Int) async -> Void,
        urlSession: URLSession = .shared
    ) {
        self.endpoint = endpoint
        self.roomId = roomId
        self.roomName = roomName
        self.hostHandle = hostHandle
        self.groupId = groupId
        self.wssURLProvider = wssURLProvider
        self.publishVersionProvider = publishVersionProvider
        self.publishVersionConsumer = publishVersionConsumer
        self.urlSession = urlSession
    }

    public func start() {
        guard heartbeatTask == nil, !stopped else { return }
        Log.line("dir-pub", "start roomId=\(self.roomId) groupId=\(self.groupId.prefix(8))…")
        heartbeatTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                if await self.isStopped { return }
                await self.publishOnce()
                try? await Task.sleep(for: Self.heartbeatInterval)
            }
        }
    }

    private var isStopped: Bool { stopped }

    /// Fire a single `/publish` request immediately. Used after URL
    /// changes so the directory reflects the new `wssURL` without
    /// waiting for the next heartbeat window. The Worker's per-roomId
    /// rate limit (25s) caps the actual cadence regardless.
    public func nudge() async {
        await publishOnce()
    }

    public func stop() async {
        guard !stopped else { return }
        stopped = true
        heartbeatTask?.cancel()
        heartbeatTask = nil
        await deleteOnce()
        Log.line("dir-pub", "stop roomId=\(self.roomId)")
    }

    // MARK: - HTTP

    private func publishOnce() async {
        guard !stopped else { return }
        guard let wssURL = await wssURLProvider() else {
            Log.line("dir-pub", "skip publish — no wssURL yet")
            return
        }
        let nextVersion = await publishVersionProvider() + 1
        let body = DirectoryAPI.PublishRequest(
            roomId: roomId,
            name: roomName,
            hostHandle: hostHandle,
            wssURL: wssURL.absoluteString,
            groupId: groupId,
            publishVersion: nextVersion)

        var req = URLRequest(url: endpoint.appendingPathComponent("publish"))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "content-type")
        do {
            req.httpBody = try JSONEncoder().encode(body)
        } catch {
            Log.line("dir-pub", "encode failed: \(error)")
            return
        }

        do {
            let (_, response) = try await urlSession.data(for: req)
            guard let http = response as? HTTPURLResponse else { return }
            switch http.statusCode {
            case 200:
                await publishVersionConsumer(nextVersion)
                Log.line("dir-pub", "publish ok version=\(nextVersion)")
            case 409:
                // Stale publishVersion — Worker has a higher one. Fast-
                // forward our local counter so the next nudge wins.
                await publishVersionConsumer(nextVersion + 100)
                Log.line("dir-pub", "stale version; jumping ahead")
            case 429:
                // Worker rate-limit. Heartbeat cadence ensures this is
                // rare; just wait for the next tick.
                Log.line("dir-pub", "rate limited; will retry next tick")
            default:
                Log.line("dir-pub", "publish unexpected status=\(http.statusCode)")
            }
        } catch {
            // Network blip. Heartbeat retries — no special handling.
            Log.line("dir-pub", "publish failed: \(error)")
        }
    }

    private func deleteOnce() async {
        var req = URLRequest(url: endpoint.appendingPathComponent("publish/\(roomId)"))
        req.httpMethod = "DELETE"
        req.setValue("application/json", forHTTPHeaderField: "content-type")
        do {
            req.httpBody = try JSONEncoder().encode(
                DirectoryAPI.DeleteRequest(groupId: groupId))
        } catch {
            return
        }
        // Best effort — if it fails, the 180s TTL evicts the entry.
        _ = try? await urlSession.data(for: req)
    }
}
