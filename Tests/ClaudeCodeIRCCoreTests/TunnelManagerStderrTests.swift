import Foundation
import Testing
import ClaudeCodeIRCCore

/// Tests for `TunnelManager.extractTunnelURL(in:)` — the regex-free
/// scanner that pulls `https://*.trycloudflare.com` URLs out of
/// `cloudflared` stderr lines. Pure function; no process spawn.
///
/// The exact stderr format is undocumented and has churned across
/// `cloudflared` releases. Each case here is sourced from real output
/// observed in development; if a future cloudflared changes the
/// surrounding text, only this test needs an update — the parser is
/// resilient by design (it only looks for the URL substring).
@Suite struct TunnelManagerStderrTests {

    @Test func extractsFromQuickTunnelBanner() {
        // Typical "Your quick tunnel has been created!" banner line.
        let line = "2026-04-28T12:34:56Z INF |  https://abc-quick-tunnel-1234.trycloudflare.com  |"
        let url = TunnelManager.extractTunnelURL(in: line)
        #expect(url?.absoluteString == "https://abc-quick-tunnel-1234.trycloudflare.com")
    }

    @Test func extractsFromBareLog() {
        let line = "INFO Quick Tunnel URL: https://random-words-7890.trycloudflare.com"
        let url = TunnelManager.extractTunnelURL(in: line)
        #expect(url?.absoluteString == "https://random-words-7890.trycloudflare.com")
    }

    @Test func extractsAllLowercaseHostname() {
        let line = "https://abcdef.trycloudflare.com"
        let url = TunnelManager.extractTunnelURL(in: line)
        #expect(url?.absoluteString == "https://abcdef.trycloudflare.com")
    }

    @Test func extractsWithDigitsAndDashes() {
        let line = "Visit https://aurora-blue-pickle-3.trycloudflare.com to see your tunnel"
        let url = TunnelManager.extractTunnelURL(in: line)
        #expect(url?.absoluteString == "https://aurora-blue-pickle-3.trycloudflare.com")
    }

    @Test func returnsNilOnUnrelatedLine() {
        let lines = [
            "INF Authenticating tunnel",
            "WARN Connection refused",
            "Started tunnel agent",
            "https://example.com/path",
            "wss://abc.trycloudflare.com",   // ws scheme, not https
            "",
        ]
        for line in lines {
            #expect(TunnelManager.extractTunnelURL(in: line) == nil,
                "should not match: \(line)")
        }
    }

    @Test func returnsNilOnEmptyHostname() {
        // `https://` immediately followed by `.trycloudflare.com` —
        // no host segment between them. Walk-back logic should fail.
        let line = "INF prefix https://.trycloudflare.com suffix"
        #expect(TunnelManager.extractTunnelURL(in: line) == nil)
    }

    /// Multiple URLs on one line — return the first. (Real cloudflared
    /// stderr only emits one per line, but be defensive.)
    @Test func extractsFirstURLWhenMultiple() {
        let line = "https://a.trycloudflare.com / https://b.trycloudflare.com"
        let url = TunnelManager.extractTunnelURL(in: line)
        #expect(url?.absoluteString == "https://a.trycloudflare.com")
    }

    /// The walk-back uses ASCII letter/digit/hyphen as the host
    /// alphabet. A non-conforming character bordering the suffix
    /// should make the parser refuse the match (no partial host).
    @Test func returnsNilOnInvalidHostCharacter() {
        let line = "INF https://bad host.trycloudflare.com"
        #expect(TunnelManager.extractTunnelURL(in: line) == nil)
    }
}
