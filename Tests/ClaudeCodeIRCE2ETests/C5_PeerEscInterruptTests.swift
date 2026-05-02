// Replaces scripts/smoke/c5-peer-esc.sh — peer-ESC interrupt fanout to all
// 3 panes. Any peer pressing ESC during a streaming Turn must:
//   - flip Turn.cancelRequested = 1 in lattice (syncs to host),
//   - cause the host's CancelObserver to call driver.stop(),
//   - terminate the underlying `claude -p` subprocess,
//   - render `*** turn interrupted` on every pane.
//
// This test extends the verified host-ESC + 2-peer-ESC paths to 3 peers
// to gate `RoomSyncServer.peers` fan-out at scale.

import Testing
import Foundation
import NCUITest
import NCUITestProtocol

@Suite("C5 — peer-ESC interrupts streaming Turn for all peers", .serialized)
struct C5_PeerEscInterruptTests {
    @Test(.timeLimit(.minutes(5)))
    func bobEscInterruptsForAll() async throws {
        let roomName = NCUIApplication.ccircRoomName(prefix: "c5")
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

        for app in [alice, bob, carol] {
            try await app.waitForMembers(["alice", "bob", "carol"], timeout: 30)
        }

        // Alice triggers a long claude turn — long enough that bob has time
        // to ESC before it finishes naturally. ~20–40s of streaming.
        try await alice.sendMessage(
            "@claude write a 200-line python script implementing a basic linked list " +
            "with insert, remove, find, and iter operations, plus a small test harness. " +
            "Include detailed comments."
        )

        // Wait for the turn to start streaming. The status bar's progress
        // bar from the claude driver shows non-zero percent while streaming;
        // match on a partial bar character or a token of partial output
        // (`def ` is in every Python script claude generates and won't
        // appear in any other UI text).
        // Wait for streaming to start — the progress bar only renders
        // during .streaming. Match the percent character (`%`) which only
        // appears in the running-turn status bar; the lobby's `[lobby]`
        // status doesn't include `%`.
        try await alice.waitForRenderedText("Opus 4.7", timeout: 90)
        // Give the stream ~6s of runway so the cancel happens mid-flight,
        // not right at startup. Bash uses similar timing implicitly via
        // its `sleep 1; sleep 2` polling cadence.
        try await Task.sleep(nanoseconds: 6_000_000_000)

        // Bob presses ESC.
        _ = try await bob.sendRaw(.sendKey(.code(.escape, modifiers: [])))

        // Every pane renders the `*** turn interrupted` system notice.
        // The "***" prefix anchors against any other "turn" mentions in
        // hint text or sidebars.
        for app in [alice, bob, carol] {
            try await app.waitForRenderedText("*** turn interrupted", timeout: 15)
        }

        // No `claude -p` subprocess should remain alive after the
        // interrupt + driver.stop(). The framework's atexit/teardown
        // cleanup also reaps these, but the assertion gates the
        // CancelObserver path itself, before terminate() runs.
        try await Task.sleep(nanoseconds: 2_000_000_000)
        let pgrepResult = Self.runPgrep("claude -p")
        #expect(pgrepResult == 0, "expected 0 live `claude -p` processes after ESC; got \(pgrepResult)")
    }

    private static func runPgrep(_ pattern: String) -> Int {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        task.arguments = ["-cf", pattern]
        let stdout = Pipe()
        task.standardOutput = stdout
        task.standardError = Pipe()
        do { try task.run() } catch { return -1 }
        task.waitUntilExit()
        let data = stdout.fileHandleForReading.readDataToEndOfFile()
        let s = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "0"
        return Int(s) ?? 0
    }
}
