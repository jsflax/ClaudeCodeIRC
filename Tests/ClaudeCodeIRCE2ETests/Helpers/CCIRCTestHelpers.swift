import Foundation
import NCUITest
import NCUITestProtocol

/// Visibility cycle for `/host`. Default in the form is `.publicTunneled`
/// (cloudflared); tests pick `.lan` to skip the cloudflared dependency.
public enum HostVisibility: Sendable, Equatable {
    case lan
    case publicTunneled
    case group(String)

    var formLabelSubstring: String {
        switch self {
        case .lan: return "private"
        case .publicTunneled: return "public"
        case .group(let name): return name.lowercased()
        }
    }
}

extension NCUIApplication {
    // MARK: - Lobby readiness

    /// Wait for the lobby to render — the welcome banner is the cheapest
    /// stable signal. Skipped automatically when the app is mid-overlay
    /// (FirstRunNickOverlay covers the welcome banner).
    public func waitForLobby(timeout: TimeInterval = 10) async throws {
        let banner = staticTexts.matching(.label(contains: "welcome to claude-code.irc")).firstMatch
        _ = try await banner.waitForExistence(timeout: timeout, captureScope: "waitForLobby")
    }

    // MARK: - Nick handling (incl. FirstRunNickOverlay dismissal)

    /// Set the nick, handling both first-run-overlay and steady-state cases.
    /// On a fresh data dir, the FirstRunNickOverlay owns input — type bare
    /// nick + Enter to dismiss it. On a re-run with prefs already populated,
    /// the overlay is absent and `/nick \(nick)` works normally.
    ///
    /// We detect the overlay via its body text (`Pick a nickname for this device.`)
    /// rather than the BoxView title — `BoxView` draws its title via raw
    /// `Term.put` (no child Text node), so a title-substring query won't match.
    public func setNick(_ nick: String) async throws {
        let overlayProbe = staticTexts.matching(
            .label(contains: "Pick a nickname for this device")
        ).firstMatch
        if try await overlayProbe.exists {
            _ = try await sendRaw(.sendKeys("\(nick)\n"))
            // Wait for the overlay to dismiss before we type anything else
            // — otherwise the second `/nick` lands inside the overlay's
            // text field on top of partial input.
            let deadline = Date().addingTimeInterval(3)
            while Date() < deadline {
                if try await !(overlayProbe.exists) { break }
                try await Task.sleep(nanoseconds: 100_000_000)
            }
        }
        // Always issue /nick to canonicalize (idempotent on rerun).
        _ = try await sendRaw(.sendKeys("/nick \(nick)\n"))
        try await Task.sleep(nanoseconds: 200_000_000)
    }

    // MARK: - /host

    /// Host a new session. Reproduces `_lib.sh:host_session` exactly:
    /// /host → form → name typed → Tab×3 to visibility → cycle to target →
    /// Enter. Defaults to `.lan` to skip cloudflared.
    public func hostSession(
        nick: String,
        roomName: String,
        visibility: HostVisibility = .lan
    ) async throws {
        try await setNick(nick)

        _ = try await sendRaw(.sendKeys("/host\n"))
        // BoxView titles are drawn via raw Term.put (no child Text node);
        // detect the host form by a child Text unique to it. The visibility
        // row's label is the cleanest signal.
        let formProbe = staticTexts.matching(.label(contains: "visibility:")).firstMatch
        _ = try await formProbe.waitForExistence(timeout: 5, captureScope: "hostForm")

        // Focus is on .name; type the room name.
        _ = try await sendRaw(.sendKeys(roomName))
        try await Task.sleep(nanoseconds: 200_000_000)

        // Tab × 3: name → cwd → auth → visibility.
        for _ in 0..<3 {
            _ = try await sendRaw(.sendKey(.code(.tab, modifiers: [])))
            try await Task.sleep(nanoseconds: 80_000_000)
        }

        // Cycle visibility until the label matches the target. Default is
        // .publicTunneled; with no groups added, choices are
        // [private, public]. One Space cycles to private.
        try await cycleVisibility(to: visibility)

        // Enter submits while focus is on .visibility.
        _ = try await sendRaw(.sendKey(.code(.enter, modifiers: [])))

        // Wait for the form to dismiss + the room to materialize. The
        // status bar transitions from lobby placeholder to host marker.
        let statusBar = staticTexts.matching(.label(contains: "[\(nick)(%)]")).firstMatch
        _ = try await statusBar.waitForExistence(timeout: 15, captureScope: "hostMaterialize")
    }

    private func cycleVisibility(to target: HostVisibility, maxTries: Int = 4) async throws {
        let needle = "visibility: \(target.formLabelSubstring)"
        for _ in 0..<maxTries {
            let current = staticTexts.matching(.label(contains: needle)).firstMatch
            if try await current.exists { return }
            _ = try await sendRaw(.sendKey(.code(.space, modifiers: [])))
            try await Task.sleep(nanoseconds: 200_000_000)
        }
        // One more check — if it doesn't match after maxTries, surface a
        // diagnostic via waitForExistence (which captures artifacts).
        let final = staticTexts.matching(.label(contains: needle)).firstMatch
        _ = try await final.waitForExistence(timeout: 1, captureScope: "cycleVisibility")
    }

    // MARK: - /join

    /// Join an already-hosted session. Reproduces `_lib.sh:join_session`:
    /// dismisses first-run overlay, waits for the target room to appear in
    /// the LAN-discovered sidebar (mDNS propagation can take 2–4s), then
    /// `/join <name>`.
    public func joinSession(nick: String, roomName: String) async throws {
        try await setNick(nick)

        // Wait for Bonjour to find the host's published room. The sidebar
        // renders DiscoveredRoom rows under "lan" with the room name.
        let discovered = staticTexts.matching(.label(contains: roomName)).firstMatch
        _ = try await discovered.waitForExistence(timeout: 30, captureScope: "joinDiscover")

        _ = try await sendRaw(.sendKeys("/join \(roomName)\n"))

        // Wait for join to materialize. Status bar shows [<nick>(+)] for
        // peers (vs. (%) for hosts).
        let statusBar = staticTexts.matching(.label(contains: "[\(nick)(+)]")).firstMatch
        _ = try await statusBar.waitForExistence(timeout: 15, captureScope: "joinMaterialize")
    }

    // MARK: - Messaging

    /// Send a message in the active room.
    public func sendMessage(_ text: String) async throws {
        _ = try await sendRaw(.sendKeys("\(text)\n"))
        try await Task.sleep(nanoseconds: 200_000_000)
    }

    /// Wait for a message of the form `<nick> <body-substring>` to appear.
    /// Matches the rendered format in `MessageListView` (HH:MM <nick> body).
    /// Note: `<` / `>` are part of the rendered nick decoration.
    public func expectMessage(
        from nick: String,
        contains body: String,
        timeout: TimeInterval = 10
    ) async throws {
        let needle = "<\(nick)> \(body)"
        let row = staticTexts.matching(.label(contains: needle)).firstMatch
        _ = try await row.waitForExistence(timeout: timeout, captureScope: "expectMessage")
    }

    // MARK: - Member count

    /// Wait until the room shows the expected nicks in the users sidebar.
    /// Asserts via the live UI tree, not by opening the lattice file —
    /// SQLite WAL doesn't reliably allow a separate-process reader to attach
    /// while the live writer is active (Lattice's Cxx core SIGSEGVs on some
    /// open shapes), so direct file inspection is reserved for assertions
    /// that genuinely require it (orphan-cleanup state in C4).
    public func waitForMembers(
        _ nicks: [String],
        timeout: TimeInterval = 30
    ) async throws {
        for nick in nicks {
            let row = staticTexts.matching(.label(contains: nick)).firstMatch
            _ = try await row.waitForExistence(timeout: timeout, captureScope: "waitForMembers")
        }
    }

    /// Poll `captureANSI()` until the rendered terminal output (with SGR
    /// escapes stripped) contains `needle`. Use when the target text isn't
    /// in the view tree — e.g. `BoxView` titles and `CardView` headers/
    /// footers are drawn via raw `Term.put` / `Text.draw(in:)` calls
    /// bypassing tree mounting. Stripping SGR makes substring matches like
    /// `"] Left"` work even when tmux emits a color-reset escape between
    /// the bracket and the option label.
    public func waitForRenderedText(
        _ needle: String,
        timeout: TimeInterval = 30
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let raw = try? captureANSI() {
                let stripped = Self.stripSGR(raw)
                if stripped.contains(needle) { return }
            }
            try await Task.sleep(nanoseconds: 250_000_000)
        }
        throw NCUIError.waitTimeout(
            spec: "rendered text contains '\(needle)'",
            timeout: timeout,
            artifactsDir: nil
        )
    }

    /// Capture the rendered terminal as text with SGR escape sequences
    /// removed — convenient for substring assertions in tests.
    public func captureRenderedText() throws -> String {
        Self.stripSGR(try captureANSI())
    }

    private static func stripSGR(_ ansi: String) -> String {
        guard let regex = try? Regex("\u{1B}\\[[0-9;]*m") else { return ansi }
        return ansi.replacing(regex, with: "")
    }

    // MARK: - Ask flow

    /// Trigger an AskUserQuestion via `@claude` invocation. The prompt is
    /// passed as-is; tests typically wrap it like:
    ///   "@claude use AskUserQuestion to ask 'Pick a color' (single-select; …)"
    /// Caller awaits an Ask card to materialize separately.
    public func triggerAskQuestion(prompt: String) async throws {
        _ = try await sendRaw(.sendKeys("\(prompt)\n"))
    }

    /// Vote on a single-select Ask by option index. Mirrors the bash flow
    /// (`Down × index, Enter`). Index 0 is the default-selected first option
    /// — pass 0 to vote for it without arrow-keying. Assumes the Ask card
    /// has focus (which it does when an Ask is the freshest event).
    public func voteOption(index: Int) async throws {
        for _ in 0..<index {
            _ = try await sendRaw(.sendKey(.code(.down, modifiers: [])))
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        _ = try await sendRaw(.sendKey(.code(.enter, modifiers: [])))
        try await Task.sleep(nanoseconds: 200_000_000)
    }

    // MARK: - Lattice access

    /// Open the first room lattice in `<dataDir>/rooms/` for read-only state
    /// inspection. The actual `Lattice`/`RoomStore.schema` types live in
    /// ClaudeCodeIRCCore — `CCIRCLatticeAccess` (compiled into the test target
    /// alongside this helper) provides typed accessors.
    public func openRoomLattice(roomCode: String? = nil) throws -> CCIRCLatticeHandle? {
        let roomsDir = (dataDir as NSString).appendingPathComponent("rooms")
        let entries = (try? FileManager.default.contentsOfDirectory(atPath: roomsDir)) ?? []
        let lattices = entries.filter { $0.hasSuffix(".lattice") }
        let target: String?
        if let code = roomCode {
            target = lattices.first { $0 == "\(code).lattice" }
        } else {
            target = lattices.first
        }
        guard let file = target else { return nil }
        let path = (roomsDir as NSString).appendingPathComponent(file)
        return try CCIRCLatticeAccess.open(path: path)
    }

    public func resolvedRoomCode() -> String? {
        let roomsDir = (dataDir as NSString).appendingPathComponent("rooms")
        let entries = (try? FileManager.default.contentsOfDirectory(atPath: roomsDir)) ?? []
        return entries.first { $0.hasSuffix(".lattice") }?
            .replacingOccurrences(of: ".lattice", with: "")
    }
}
