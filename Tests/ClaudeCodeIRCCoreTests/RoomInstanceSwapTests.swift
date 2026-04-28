import Foundation
import Testing
import Lattice
import ClaudeCodeIRCCore

/// L0 gating tests for `RoomInstance.swap(toEndpoint:joinCode:)`.
///
/// The swap mechanism is load-bearing for tunnel-restart recovery:
/// when the host's `cloudflared` URL changes, peers must reconnect
/// to the new endpoint without losing the on-disk transcript or
/// the live object references the UI is observing.
///
/// **Topology.** One host Lattice serving as the canonical source.
/// Two `RoomSyncServer` instances bound to different ephemeral ports,
/// both backed by the same host Lattice — analogous to the same host
/// being reachable through two different tunnel URLs (the v2 case).
/// Peer connects to server A, swaps to server B, both should keep
/// working against the same on-disk transcript.
/// `.serialized` because every test stands up real `RoomSyncServer`
/// instances (each owning a `MultiThreadedEventLoopGroup`) and writes
/// to per-test SQLite files. Parallel runs were racing on:
/// 1. NIO event loops being shut down via deferred async cleanup
///    while a sibling test was still using them ("Cannot schedule
///    tasks on an EventLoop that has already shut down").
/// 2. MainActor reentry during `await` suspensions causing one test's
///    lattice teardown to interleave with another's open.
/// Tests inside this suite are not actually independent of each other
/// at the OS-resource level — they're sharing the process's
/// `Lattice` C++ state and a NIO thread pool.
@MainActor
@Suite(.serialized)
struct RoomInstanceSwapTests {

    // MARK: - Helpers

    private struct HostHarness {
        let lattice: Lattice
        let server: RoomSyncServer
        let port: Int
        let fileURL: URL
    }

    private func makeHostHarness(roomCode: String, joinCode: String?) async throws -> HostHarness {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "ccirc-host-\(UUID().uuidString).lattice")
        let lattice = try Lattice(
            for: RoomStore.schema,
            configuration: .init(fileURL: url))
        let server = try RoomSyncServer(
            latticeReference: lattice.sendableReference,
            roomCode: roomCode,
            joinCode: joinCode)
        let port = try await server.start()
        return HostHarness(lattice: lattice, server: server, port: port, fileURL: url)
    }

    private func teardown(_ host: HostHarness) async throws {
        host.lattice.close()
        try? await host.server.stop()
        _ = host.fileURL
    }

    /// Test-side `PeerLatticeStore` that opens the peer Lattice at a
    /// fixed file URL passed in at construction. Both initial open and
    /// `swap()`'s reopen go through the same instance → same file.
    private struct FixedPathPeerLatticeStore: PeerLatticeStore {
        let fileURL: URL

        func openPeer(code: String, endpoint: URL, joinCode: String?) throws -> Lattice {
            try Lattice(
                for: RoomStore.schema,
                configuration: .init(
                    fileURL: fileURL,
                    authorizationToken: joinCode ?? RoomStore.openRoomBearer,
                    wssEndpoint: endpoint))
        }
    }

    private func makePeerStore() -> (FixedPathPeerLatticeStore, URL) {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "ccirc-peer-\(UUID().uuidString).lattice")
        return (FixedPathPeerLatticeStore(fileURL: url), url)
    }

    /// Wait until a Bool predicate flips true by tailing the lattice's
    /// `changeStream`. Per the project convention "never poll for sync
    /// results" — observer-driven only. Throws on timeout. The predicate
    /// runs on the same MainActor as the test, so it can read live
    /// model state safely.
    private func waitFor(
        on lattice: Lattice,
        timeout: Duration = .seconds(5),
        _ predicate: @MainActor () -> Bool
    ) async throws {
        if predicate() { return }
        let stream = lattice.changeStream
        let deadline = Date().addingTimeInterval(TimeInterval(timeout.components.seconds))
        for await _ in stream {
            if predicate() { return }
            if Date() > deadline { break }
        }
        if !predicate() { throw SwapTestError.timeout }
    }

    private enum SwapTestError: Error { case timeout }

    private func makePrefs(nick: String) -> AppPreferences {
        let prefs = AppPreferences()
        prefs.nick = nick
        return prefs
    }

    private func endpoint(forPort port: Int, code: String) -> URL {
        URL(string: "ws://127.0.0.1:\(port)/room/\(code)")!
    }

    // MARK: - Tests

    /// End-to-end swap: peer joins host via server A, sees data, swaps
    /// to server B (same host Lattice, different port), continues
    /// receiving data. Verifies the on-disk transcript persists across
    /// close/open and that re-linked object references reflect the new
    /// `Lattice` instance.
    @Test func peerCanSwapBetweenServersBackedBySameLattice() async throws {
        let code = "swaprt01"
        let host = try await makeHostHarness(roomCode: code, joinCode: nil)

        // Authoritative state — host writes Session + a chat row.
        let session = Session()
        session.code = code
        session.name = "swap-rt"
        session.cwd = "/tmp"
        host.lattice.add(session)

        let alice = Member()
        alice.nick = "alice"
        alice.isHost = true
        alice.session = session
        host.lattice.add(alice)
        session.host = alice

        let initialMsg = ChatMessage()
        initialMsg.text = "hello from A"
        initialMsg.author = alice
        initialMsg.session = session
        initialMsg.kind = .user
        initialMsg.createdAt = Date()
        host.lattice.add(initialMsg)
        let initialMsgGid = initialMsg.globalId

        // --- Peer connects to server A ---

        let endpointA = endpoint(forPort: host.port, code: code)
        let (peerStore, peerURL) = makePeerStore()
        let peerLattice = try peerStore.openPeer(
            code: code, endpoint: endpointA, joinCode: nil)

        let peer = RoomInstance.peer(
            lattice: peerLattice,
            roomCode: code,
            joinCode: nil,
            prefs: makePrefs(nick: "bob"),
            peerLatticeStore: peerStore)

        // Wait for Session sync (catch-up links it to selfMember).
        try await waitFor(on: peerLattice) { peer.session != nil }
        #expect(peer.session?.code == code)
        #expect(peer.session?.name == "swap-rt")

        // Wait for the initial ChatMessage to land on the peer.
        try await waitFor(on: peerLattice) {
            guard let gid = initialMsgGid else { return false }
            return peerLattice.object(ChatMessage.self, globalId: gid) != nil
        }

        // --- Stop A, start B (same host Lattice, new port) ---

        try await host.server.stop()
        let serverB = try RoomSyncServer(
            latticeReference: host.lattice.sendableReference,
            roomCode: code,
            joinCode: nil)
        let portB = try await serverB.start()
        let endpointB = endpoint(forPort: portB, code: code)

        // --- Peer swaps to server B ---

        try peer.swap(toEndpoint: endpointB, joinCode: nil)

        // Same on-disk file: pre-swap data must still be visible on
        // the new Lattice instance.
        if let gid = initialMsgGid {
            #expect(peer.lattice.object(ChatMessage.self, globalId: gid) != nil)
        }
        #expect(peer.session != nil)
        #expect(peer.session?.code == code)
        #expect(peer.selfMember != nil)
        #expect(peer.selfMember?.nick == "bob")

        // --- New write on host post-swap should propagate to peer ---

        let postSwapMsg = ChatMessage()
        postSwapMsg.text = "hello from B"
        postSwapMsg.author = alice
        postSwapMsg.session = session
        postSwapMsg.kind = .user
        postSwapMsg.createdAt = Date()
        host.lattice.add(postSwapMsg)
        let postSwapGid = postSwapMsg.globalId

        try await waitFor(on: peer.lattice) {
            guard let gid = postSwapGid else { return false }
            return peer.lattice.object(ChatMessage.self, globalId: gid) != nil
        }

        // Cleanup. Order: close peer's Lattice first to release WS-client
        // handles before the host server's NIO group goes away. Skip
        // explicit `removeItem` — racing SQLite's deferred close
        // produces "vnode unlinked while in use" warnings.
        peer.lattice.close()
        try? await serverB.stop()
        try await teardown(host)
        _ = peerURL
    }

    /// Local writes the peer made before the swap remain in the local
    /// SQLite file and replay against the new server idempotently
    /// (globalId dedup). Verifies that close/open doesn't lose unsynced
    /// outbox state.
    @Test func peerLocalWritesSurviveSwap() async throws {
        let code = "swaprt02"
        let host = try await makeHostHarness(roomCode: code, joinCode: nil)

        let session = Session()
        session.code = code
        session.name = "outbox-test"
        session.cwd = "/tmp"
        host.lattice.add(session)

        let alice = Member()
        alice.nick = "alice"
        alice.isHost = true
        alice.session = session
        host.lattice.add(alice)
        session.host = alice

        let endpointA = endpoint(forPort: host.port, code: code)
        let (peerStore, peerURL) = makePeerStore()
        let peerLattice = try peerStore.openPeer(
            code: code, endpoint: endpointA, joinCode: nil)

        let peer = RoomInstance.peer(
            lattice: peerLattice,
            roomCode: code,
            joinCode: nil,
            prefs: makePrefs(nick: "bob"),
            peerLatticeStore: peerStore)
        _ = peerURL  // kept alive for cleanup at end

        // Wait for catch-up so peer.selfMember.session is wired up.
        try await waitFor(on: peerLattice) { peer.session != nil }

        // Peer-local write before the swap.
        let bobMsg = ChatMessage()
        bobMsg.text = "peer-side write before swap"
        bobMsg.author = peer.selfMember
        bobMsg.session = peer.session
        bobMsg.kind = .user
        bobMsg.createdAt = Date()
        peerLattice.add(bobMsg)
        let bobMsgGid = bobMsg.globalId

        // Swap to a fresh server on the same host file.
        try await host.server.stop()
        let serverB = try RoomSyncServer(
            latticeReference: host.lattice.sendableReference,
            roomCode: code,
            joinCode: nil)
        let portB = try await serverB.start()
        let endpointB = endpoint(forPort: portB, code: code)

        try peer.swap(toEndpoint: endpointB, joinCode: nil)

        // The pre-swap write is still in the peer's on-disk lattice.
        if let gid = bobMsgGid {
            #expect(peer.lattice.object(ChatMessage.self, globalId: gid) != nil,
                "peer-local write must survive swap")
        }

        // And it propagates up to the host through the new connection.
        try await waitFor(on: host.lattice) {
            guard let gid = bobMsgGid else { return false }
            return host.lattice.object(ChatMessage.self, globalId: gid) != nil
        }

        try? await serverB.stop()
        peer.lattice.close()
        try? FileManager.default.removeItem(at: peerURL)
        try await teardown(host)
    }
}
