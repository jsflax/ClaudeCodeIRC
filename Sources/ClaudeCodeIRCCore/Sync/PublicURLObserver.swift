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
        // Baseline: prefer the URL we *actually connected with* over the
        // (possibly nil) `session.publicURL` field. Catch-up populates
        // `Session.publicURL` shortly after peer-join with the same
        // tunnel origin we already dialed; comparing against the
        // unconnected baseline (`nil`) would treat that as a "URL
        // changed" event and trigger a redundant `swap()`. The swap
        // closes the lattice we're mid-render against → SIGSEGV in
        // `database::query` from the next `@Query` read. So seed the
        // baseline with our own `wssEndpoint` re-translated to the
        // host-written `https://*.trycloudflare.com` form (path
        // stripped, scheme flipped); the first catch-up fire then
        // matches and we skip the swap. Real tunnel rotations later
        // *do* fire as intended.
        self.lastObservedURL = Self.connectedHttpsOrigin(of: roomInstance.lattice)
            ?? roomInstance.session?.publicURL
        attach(lattice: roomInstance.lattice)
    }

    /// Re-translate the lattice's bound `wssEndpoint`
    /// (`wss://host/room/<code>`) back into the host-written
    /// `https://host` form that `Session.publicURL` carries. Returns
    /// `nil` if the lattice has no `wssEndpoint` (host-side instance,
    /// or LAN-bonjour peer with a `ws://` URL we don't want to compare
    /// against an https field anyway).
    private static func connectedHttpsOrigin(of lattice: Lattice) -> String? {
        guard let endpoint = lattice.configuration.wssEndpoint,
              endpoint.scheme == "wss",
              var components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false)
        else { return nil }
        components.scheme = "https"
        components.path = ""
        components.query = nil
        components.fragment = nil
        return components.url?.absoluteString
    }

    private func attach(lattice: Lattice) {
        let file = lattice.configuration.fileURL.lastPathComponent
        let last = self.lastObservedURL ?? "nil"
        Log.line("public-url-observer", "attach lattice=\(file) lastObserved=\(last)")
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
        else {
            Log.line("public-url-observer", "evaluate skip — guard failed (no room/host/session)")
            return
        }
        let cur = session.publicURL ?? "nil"
        let last = self.lastObservedURL ?? "nil"
        Log.line(
            "public-url-observer",
            "evaluate joinedViaTunnel=\(roomInstance.joinedViaTunnel) currentURL=\(cur) lastObserved=\(last)")

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
              let url = Self.wssEndpoint(forPublicURL: urlString,
                                         roomCode: roomInstance.roomCode)
        else {
            Log.line("public-url-observer", "publicURL cleared / unparseable; staying on current endpoint")
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

    /// Translate a host-written `Session.publicURL`
    /// (`https://*.trycloudflare.com`) into the fully-formed sync
    /// endpoint a peer needs (`wss://*.trycloudflare.com/room/<code>`).
    /// Returns nil for unparseable input or for a `URLComponents` we
    /// can't reassemble after the scheme + path edits.
    ///
    /// Single source of truth for the translation. Used both by the
    /// observer's `evaluate()` (mid-session tunnel-restart swap) and
    /// by `WorkspaceView.activateRecent` (`/reopen` after a peer
    /// crash). Without this helper the two paths drifted: the observer
    /// translated, the reopen path didn't, and a `/reopen` over the
    /// tunnel landed the peer on an https-scheme URL with no
    /// `/room/<code>` path. Lattice's WSS upgrade silently failed and
    /// sync was dead even though the room looked "live" locally.
    public static func wssEndpoint(
        forPublicURL urlString: String,
        roomCode: String
    ) -> URL? {
        guard let httpsURL = URL(string: urlString),
              var components = URLComponents(url: httpsURL, resolvingAgainstBaseURL: false)
        else { return nil }
        components.scheme = "wss"
        components.path = "/room/\(roomCode)"
        return components.url
    }
}
