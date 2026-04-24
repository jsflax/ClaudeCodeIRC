import Foundation

/// `@claude` word-token detector used by the host's chat observer to
/// decide whether an inbound `ChatMessage` should trigger the
/// `ClaudeCliDriver`.
///
/// Matches are case-insensitive; the token is bordered by
/// start-of-string / end-of-string / whitespace / common
/// punctuation. Deliberately excludes `@` in an email-like context
/// (`foo@claude.com`) and rejects longer runs (`@claudette`).
package enum ClaudeMention {
    package static func matches(_ text: String) -> Bool {
        // `Regex` isn't Sendable, so the literal can't live at module
        // scope under strict concurrency. Constructing it per call is
        // ~free — Regex compilation is lazy and parsed once, and this
        // only runs on ChatMessage inserts.
        let pattern = /(?:^|[\s,.!?])@claude(?:$|[\s,.!?])/.ignoresCase()
        return text.contains(pattern)
    }
}
