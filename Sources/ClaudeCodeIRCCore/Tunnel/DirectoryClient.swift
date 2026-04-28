import Foundation

/// Peer-side: polls `GET /list?group=<groupId>` for every group the
/// user has loaded plus the well-known `"public"` bucket. Stores the
/// merged result internally; UI consumers subscribe to
/// `roomsByGroupStream` for live updates or read a snapshot via
/// `currentRoomsByGroup`.
///
/// **Cadence**: ~10s per poll cycle, all groups in sequence (so we're
/// well within the Worker's free-tier request budget — 1 host + N
/// groups + 1 public bucket per cycle).
///
/// **Filtering**: callers exclude rooms whose `roomId` is already in
/// `joinedRooms` so the sidebar doesn't double-show. The directory
/// keeps the raw data here; filtering belongs at the view layer where
/// `joinedRooms` is observable.
///
/// **Isolation**: actor — all directory I/O happens off MainActor so
/// network blips don't affect UI responsiveness. Snapshot reads use
/// the async accessor; UI views drive a `task { for await … }` off
/// the stream.
public actor DirectoryClient {

    /// Async stream of `[groupId: rooms]` snapshots, emitted after
    /// each completed poll cycle. UI subscribers call
    /// `for await snapshot in client.roomsByGroupStream { … }` and
    /// reflect the snapshot into MainActor-isolated state. Multi-cast
    /// is unnecessary today (one subscriber: `RoomsModel`'s mirror).
    public nonisolated let roomsByGroupStream: AsyncStream<[String: [DirectoryAPI.ListedRoom]]>
    private let snapshotContinuation: AsyncStream<[String: [DirectoryAPI.ListedRoom]]>.Continuation

    private var roomsByGroup: [String: [DirectoryAPI.ListedRoom]] = [:]

    private let urlSession: URLSession
    private let endpointProvider: @Sendable () async -> URL?
    private let groupIdsProvider: @Sendable () async -> [String]

    private var pollTask: Task<Void, Never>?
    private static let pollInterval: Duration = .seconds(10)

    public init(
        endpointProvider: @escaping @Sendable () async -> URL?,
        groupIdsProvider: @escaping @Sendable () async -> [String],
        urlSession: URLSession = .shared
    ) {
        self.endpointProvider = endpointProvider
        self.groupIdsProvider = groupIdsProvider
        self.urlSession = urlSession
        var continuation: AsyncStream<[String: [DirectoryAPI.ListedRoom]]>.Continuation!
        self.roomsByGroupStream = AsyncStream { continuation = $0 }
        self.snapshotContinuation = continuation
    }

    /// Snapshot read of the current map. Useful for one-shot reads in
    /// tests / lobby init; production UI uses `roomsByGroupStream`.
    public func currentRoomsByGroup() -> [String: [DirectoryAPI.ListedRoom]] {
        roomsByGroup
    }

    public func start() {
        guard pollTask == nil else { return }
        Log.line("dir-cli", "start")
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.fetchAll()
                try? await Task.sleep(for: Self.pollInterval)
            }
        }
    }

    public func stop() {
        pollTask?.cancel()
        pollTask = nil
        snapshotContinuation.finish()
    }

    /// One full poll cycle — sequential per group. Sequential keeps
    /// the connection count low (one TCP at a time) and order
    /// deterministic for log readability; the Worker is fast enough
    /// that parallelism wouldn't materially help.
    private func fetchAll() async {
        guard let endpoint = await endpointProvider() else { return }
        let groups = await groupIdsProvider()
        var next: [String: [DirectoryAPI.ListedRoom]] = [:]
        for groupId in groups {
            next[groupId] = await fetchOne(endpoint: endpoint, groupId: groupId)
        }
        roomsByGroup = next
        snapshotContinuation.yield(next)
    }

    private func fetchOne(endpoint: URL, groupId: String) async -> [DirectoryAPI.ListedRoom] {
        var components = URLComponents(
            url: endpoint.appendingPathComponent("list"),
            resolvingAgainstBaseURL: false)
        components?.queryItems = [URLQueryItem(name: "group", value: groupId)]
        guard let url = components?.url else { return [] }

        do {
            let (data, response) = try await urlSession.data(from: url)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                Log.line("dir-cli",
                    "list \(groupId.prefix(8))… non-200: \((response as? HTTPURLResponse)?.statusCode ?? -1)")
                return []
            }
            let decoded = try JSONDecoder().decode(DirectoryAPI.ListResponse.self, from: data)
            Log.line("dir-cli",
                "list \(groupId.prefix(8))… got \(decoded.rooms.count) rooms")
            return decoded.rooms
        } catch {
            Log.line("dir-cli", "list failed: \(error)")
            return []
        }
    }
}
