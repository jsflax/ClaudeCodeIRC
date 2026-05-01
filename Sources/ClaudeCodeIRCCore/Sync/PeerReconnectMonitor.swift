import Foundation
import Lattice

/// Peer-side WebSocket reconnect supervisor.
///
/// Tunneled deployments (cloudflared in particular) silently drop a
/// peer's WebSocket the moment keepalive misses a beat or the upstream
/// tunnel rotates. Without auto-reconnect the peer keeps running but
/// never sees another audit row from the host — `Session.publicURL`
/// observation only handles URL *changes*, not stalls on the same URL.
///
/// This actor owns the reconnect timer + attempt counter. It runs on
/// its own isolation domain on purpose: the backoff sleep must NOT
/// sit on the MainActor queue (the actor that owns `RoomInstance`),
/// because doing so makes a UI tick block until the timer wakes. We
/// only hop back to the owner — `RoomInstance` — to perform the actual
/// `swap()`, which is intrinsically MainActor work (rebinding observers
/// + UI-visible state).
///
/// Lattice handles are isolation-bound: a `Lattice` value's underlying
/// `swift_lattice` is keyed to the scheduler that resolved it, so the
/// monitor never touches `Lattice` directly. `RoomInstance` registers
/// the `onSyncStateChange` callback on the MainActor lattice; the
/// callback's body just pumps the bool into this actor.
///
/// Lifecycle:
///   • `arm(endpoint:joinCode:)` — bumps the generation and updates the
///     reconnect target. `RoomInstance` calls this once at peer
///     creation and again after each `swap()`. The returned generation
///     is captured by the freshly-registered `onSyncStateChange`
///     closure so handleStateChange can short-circuit any callback
///     that fires after the underlying Lattice has been replaced.
///   • `handleStateChange(connected:gen:)` — called from the
///     `onSyncStateChange` closure once it's pumped through `Task`
///     into this actor's isolation. Drops mismatched-generation events.
///   • `cancel()` — fired from `RoomInstance.leave()`. Stops the
///     in-flight timer, drops the owner reference (breaking the strong
///     cycle), and bumps the generation so any callback already pumped
///     finds a stale generation and bails.
///
/// Backoff schedule: 1, 2, 4, 8, 16, 30, 30, … seconds. Resets to 0 on
/// every transition back to `connected = true`.
public actor PeerReconnectMonitor {
    /// `RoomInstance` is `@MainActor`; we hold a strong-but-nilable
    /// reference and clear it in `cancel()` so the strong cycle is
    /// broken at a known point in the lifecycle.
    private var owner: RoomInstance?
    private var endpoint: URL
    private var joinCode: String?

    /// Bumped on every `arm()` and on `cancel()`. The
    /// `onSyncStateChange` closures we hand off to Lattice capture
    /// their generation by value; mismatched generations short-circuit
    /// any callback that fires after `RoomInstance.swap()` has rebuilt
    /// the underlying Lattice.
    private var generation: Int = 0
    /// Number of consecutive failed reconnects since the last
    /// `connected = true`. Drives the backoff delay.
    private var attempt: Int = 0
    /// Pending `Task.sleep` + `swap()` invocation. Cancelled and
    /// replaced when a fresh state-change comes in.
    private var task: Task<Void, Never>?

    public init(owner: RoomInstance, endpoint: URL, joinCode: String?) {
        self.owner = owner
        self.endpoint = endpoint
        self.joinCode = joinCode
    }

    /// Refresh the target endpoint + joinCode and bump the generation.
    /// Returns the new generation for the caller to embed in its
    /// freshly-registered `onSyncStateChange` closure.
    public func arm(endpoint: URL, joinCode: String?) -> Int {
        self.endpoint = endpoint
        self.joinCode = joinCode
        generation += 1
        return generation
    }

    /// Pump a state-change event into the monitor. Drops mismatched
    /// generations (callback registered against a Lattice that has
    /// since been replaced by `swap()`).
    public func handleStateChange(connected: Bool, gen: Int) {
        guard gen == generation else {
            Log.line(
                "peer-conn",
                "stale onSyncStateChange (gen=\(gen), current=\(self.generation)) — ignoring")
            return
        }
        if connected {
            if attempt > 0 {
                Log.line("peer-conn", "WebSocket reconnected after \(self.attempt) attempt(s)")
            }
            attempt = 0
            task?.cancel()
            task = nil
        } else {
            Log.line("peer-conn", "WebSocket disconnected — scheduling reconnect")
            scheduleReconnect()
        }
    }

    /// Stop reconnecting and release the `RoomInstance` ref. Idempotent.
    public func cancel() {
        task?.cancel()
        task = nil
        generation += 1
        owner = nil
    }

    // MARK: - Private

    private func scheduleReconnect() {
        task?.cancel()
        let myAttempt = attempt
        attempt += 1
        // 1, 2, 4, 8, 16, 30, 30 … seconds.
        let delaySeconds: TimeInterval = min(30, pow(2.0, Double(myAttempt)))
        Log.line(
            "peer-conn",
            "reconnect scheduled in \(Int(delaySeconds))s (attempt=\(myAttempt + 1)) → \(self.endpoint.absoluteString)")
        task = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delaySeconds))
            guard !Task.isCancelled else { return }
            await self?.performReconnect()
        }
    }

    /// Reads the CURRENT `endpoint` / `joinCode` from actor state — not
    /// values captured at schedule time — so a `swap()` that updates
    /// the target between scheduling and firing doesn't reconnect to
    /// the stale URL.
    ///
    /// Note: `swap()` short-circuits when the target matches the current
    /// Lattice's connection (see `RoomInstance.swap`). Because this
    /// monitor's `endpoint`/`joinCode` are re-armed from each successful
    /// swap, calling `swap()` here for a same-URL stall is a no-op — the
    /// "reconnect on the same URL" case the monitor was originally
    /// written for is currently not handled (closing+reopening the
    /// Lattice was crashing on cached `@Query` results). The narrow path
    /// — kicking just the WSS sync client without tearing down Lattice —
    /// needs a `Lattice.reconnectSync()` API that doesn't exist yet.
    /// Tracked as a follow-up; tunnel-URL-rotation reconnects (the only
    /// case where endpoint actually changes) still work via
    /// `PublicURLObserver`.
    private func performReconnect() async {
        guard let owner else { return }
        let currentEndpoint = endpoint
        let currentJoin = joinCode
        do {
            try await owner.swap(toEndpoint: currentEndpoint, joinCode: currentJoin)
            // Success is signaled when the new Lattice's
            // `onSyncStateChange` transitions back to `true` — that
            // fires `handleStateChange` and resets `attempt`.
        } catch {
            Log.line("peer-conn", "reconnect swap() failed: \(error) — re-queueing")
            scheduleReconnect()
        }
    }
}
