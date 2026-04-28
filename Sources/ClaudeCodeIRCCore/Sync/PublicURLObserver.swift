import Combine
import Foundation
import Lattice

/// Peer-side wire signal for "the host's public tunnel URL changed."
///
/// When `cloudflared` on the host crashes and is restarted by
/// `TunnelManager`, the host writes the new `*.trycloudflare.com`
/// URL onto `Session.publicURL`. Lattice syncs that single field
/// change to peers like any other update; this observer notices the
/// new value and calls `RoomInstance.swap(toEndpoint:joinCode:)` to
/// reconnect against the new edge URL.
///
/// **Why one observer per `RoomInstance`, recreated on swap.** The
/// Combine cancellable is bound to a specific `Lattice` instance.
/// `swap()` closes the old `Lattice` and opens a new one; observers
/// attached to the old instance no longer fire. `RoomInstance.swap()`
/// rebuilds this observer (and the vote coordinators) against the new
/// `Lattice` so the chain stays alive across tunnel restarts.
///
/// **Suppressing self-fire on attach.** The observer snapshots the
/// session's current `publicURL` at construction so the first
/// `change` callback after `swap()` doesn't spuriously re-swap to
/// the URL we just connected to.
///
/// **Host-side is no-op.** A host's `cloudflared` restart is observed
/// locally by `TunnelManager.urlChanges` (in-process) and the host
/// writes `Session.publicURL` directly — it doesn't need to react to
/// its own write. `RoomInstance.swap()` is `precondition`-gated to
/// peer-only, so this observer is only constructed in the peer factory.
@MainActor
public final class PublicURLObserver {
    private weak var roomInstance: RoomInstance?
    private var observer: AnyCancellable?
    private var lastObservedURL: String?

    public init(roomInstance: RoomInstance) {
        self.roomInstance = roomInstance
        // Snapshot — see "Suppressing self-fire on attach" above.
        self.lastObservedURL = roomInstance.session?.publicURL
        attach(lattice: roomInstance.lattice)
    }

    private func attach(lattice: Lattice) {
        observer = lattice.observe(Session.self) { @Sendable [weak self] change in
            switch change {
            case .insert, .update: break
            case .delete: return
            @unknown default: return
            }
            Task { @MainActor [weak self] in
                self?.evaluate()
            }
        }
    }

    private func evaluate() {
        guard let roomInstance,
              !roomInstance.isHost,           // host doesn't react to own writes
              let session = roomInstance.session
        else { return }

        // Only react if the peer is currently connected through the
        // tunnel — which is the only case `swap()` is for (cloudflared
        // restart yields a new public URL). LAN peers joined via
        // Bonjour have a direct connection to the host's local NIO
        // server; their connection is unaffected when the tunnel
        // restarts, and swapping them onto a tunnel URL would be a
        // needless reconnect through cloudflared. `RoomInstance.peer`
        // sets `joinedViaTunnel` based on whether the wssURL used at
        // join time was a `wss://` (tunnel) or `ws://` (LAN/Bonjour).
        guard roomInstance.joinedViaTunnel else { return }

        let currentURL = session.publicURL
        guard currentURL != lastObservedURL else { return }
        lastObservedURL = currentURL

        // Field cleared (host went private mid-session, or tunnel down).
        // We can't swap to "no URL" — keep the existing connection alive
        // and wait for the next non-nil value.
        guard let urlString = currentURL,
              let httpsURL = URL(string: urlString),
              var components = URLComponents(url: httpsURL, resolvingAgainstBaseURL: false)
        else {
            Log.line("public-url-observer", "publicURL cleared; staying on current endpoint")
            return
        }

        // Host writes the bare `https://*.trycloudflare.com` origin — the
        // tunnel tip — onto Session.publicURL. The peer's WS upgrade needs
        // a `wss://` scheme and the same `/room/<code>` path the host's
        // RoomSyncServer is bound to. Translate here so swap() always
        // gets a fully-formed sync endpoint.
        components.scheme = "wss"
        components.path = "/room/\(roomInstance.roomCode)"
        guard let url = components.url else {
            Log.line("public-url-observer", "could not build wss URL from \(urlString)")
            return
        }

        Log.line(
            "public-url-observer",
            "publicURL → \(url.absoluteString) — calling swap")
        do {
            try roomInstance.swap(
                toEndpoint: url,
                joinCode: session.joinCode)
        } catch {
            Log.line("public-url-observer", "swap failed: \(error)")
        }
    }
}
