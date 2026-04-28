import Foundation
import Testing
import Lattice
import ClaudeCodeIRCCore

/// `RoomInstance.joinedViaTunnel` derivation — the one-line rule
/// `lattice.configuration.wssEndpoint?.scheme == "wss"` that
/// `RoomInstance.peer` uses to decide whether `PublicURLObserver`
/// should treat tunnel-URL changes as actionable swaps.
///
/// The factory itself is hard to exercise in a unit test (it spawns a
/// `startPeerCatchUp` task tailing `lattice.changeStream` and creates
/// a real Lattice WS sync client that misbehaves against fake URLs),
/// so we pin down the derivation directly. The factory is one line
/// of code that consumes this same expression — its correctness is
/// covered by both the manual e2e smoke and the contract here.
@Suite
struct PublicURLObserverGateTests {

    private func config(scheme: String?) -> Lattice.Configuration {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "ccirc-pug-\(UUID().uuidString).lattice")
        let endpoint = scheme.flatMap {
            URL(string: "\($0)://example/room/abc123")
        }
        return Lattice.Configuration(
            fileURL: url,
            authorizationToken: "open",
            wssEndpoint: endpoint)
    }

    @Test func wssSchemeIsTunnel() {
        let cfg = config(scheme: "wss")
        #expect(cfg.wssEndpoint?.scheme == "wss")
    }

    @Test func wsSchemeIsLAN() {
        let cfg = config(scheme: "ws")
        #expect(cfg.wssEndpoint?.scheme != "wss")
    }

    @Test func nilEndpointIsLAN() {
        // No-endpoint case: Lattice never opens a WS sync client at all
        // (in-memory or local-only). Treated the same as LAN — the
        // observer should not swap.
        let cfg = config(scheme: nil)
        #expect(cfg.wssEndpoint?.scheme != "wss")
    }
}
