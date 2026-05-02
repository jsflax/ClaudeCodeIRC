import Testing
import Foundation
import NCUITest
import NCUITestProtocol

@Suite("ClaudeCodeIRC e2e — proof of life", .serialized)
struct ProofOfLifeTests {
    @Test("launch claudecodeirc and observe initial UI")
    func launchAndObserveInitialUI() async throws {
        let alice = NCUIApplication.ccirc(label: "alice")
        try await alice.launch()
        defer { alice.terminate() }

        // Give the app a moment to render its first frame.
        try await Task.sleep(nanoseconds: 500_000_000)

        // Sanity: tree has multiple top-level nodes (rooms list, status bar, input).
        let response = try await alice.sendRaw(.tree)
        guard case .tree(let root) = response.result else {
            Issue.record("expected tree response, got \(response.result)")
            alice.terminate()
            return
        }
        #expect(root.children.count > 0, "root should have children after first draw")

        alice.terminate()
    }

    @Test("typeText into the lobby command line writes characters")
    func typeIntoLobby() async throws {
        let alice = NCUIApplication.ccirc(label: "alice2")
        try await alice.launch()
        defer { alice.terminate() }

        try await Task.sleep(nanoseconds: 500_000_000)

        // Type a partial command into the input line. We don't submit (no \n)
        // so we don't hit the host/join state machines yet.
        _ = try await alice.sendRaw(.sendKeys("/nick alice"))
        try await Task.sleep(nanoseconds: 300_000_000)

        // The text should appear somewhere on screen (in the input line).
        let typed = alice.staticTexts.matching(.label(contains: "/nick alice")).firstMatch
        let exists = try await typed.waitForExistence(timeout: 2)
        if !exists {
            // Fallback diagnostic: dump what's on screen for debugging.
            if let ansi = try? alice.captureANSI() {
                Issue.record("typed '/nick alice' but tree didn't reflect it. Screen:\n\(ansi.prefix(2000))")
            }
        }
        #expect(exists)

        alice.terminate()
    }

    @Test("PNG screenshot of the lobby renders successfully")
    func lobbyScreenshot() async throws {
        let alice = NCUIApplication.ccirc(label: "alice3")
        try await alice.launch()
        defer { alice.terminate() }

        try await Task.sleep(nanoseconds: 500_000_000)

        let path = "/tmp/ccirc-e2e-lobby.png"
        try? FileManager.default.removeItem(atPath: path)
        try await alice.saveScreenshot(to: path)

        let attrs = try FileManager.default.attributesOfItem(atPath: path)
        let size = attrs[.size] as? Int ?? 0
        #expect(size > 1024)

        alice.terminate()
    }
}
