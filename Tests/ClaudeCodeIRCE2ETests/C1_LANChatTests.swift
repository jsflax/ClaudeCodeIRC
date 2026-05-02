// Replaces scripts/smoke/c1-3p-chat.sh — 3-peer LAN host/join + bidirectional chat baseline.
// Gates that RoomSyncServer's broadcast path actually fans out to N
// concurrent peers. Alice hosts, bob & carol join via /join, all three
// send messages, every peer sees all three lines.

import Testing
import Foundation
import NCUITest
import NCUITestProtocol

@Suite("C1 — 3-peer LAN host/join + bidirectional chat", .serialized)
struct C1_LANChatTests {
    @Test("3 peers see each other's messages")
    func threePeerLANChat() async throws {
        let roomName = NCUIApplication.ccircRoomName(prefix: "c1")
        let alice = NCUIApplication.ccirc(label: "alice")
        let bob   = NCUIApplication.ccirc(label: "bob")
        let carol = NCUIApplication.ccirc(label: "carol")

        try await alice.launch()
        try await bob.launch()
        try await carol.launch()
        defer { alice.terminate(); bob.terminate(); carol.terminate() }

        try await alice.hostSession(nick: "alice", roomName: roomName)
        try await bob.joinSession(nick: "bob", roomName: roomName)
        try await carol.joinSession(nick: "carol", roomName: roomName)

        // All three peers should see all three nicks in their users sidebar.
        for app in [alice, bob, carol] {
            try await app.waitForMembers(["alice", "bob", "carol"], timeout: 30)
        }

        try await alice.sendMessage("hello-from-alice-c1")
        try await bob.sendMessage("hello-from-bob-c1")
        try await carol.sendMessage("hello-from-carol-c1")

        // Every peer sees every message.
        for app in [alice, bob, carol] {
            try await app.expectMessage(from: "alice", contains: "hello-from-alice-c1")
            try await app.expectMessage(from: "bob",   contains: "hello-from-bob-c1")
            try await app.expectMessage(from: "carol", contains: "hello-from-carol-c1")
        }
    }
}
