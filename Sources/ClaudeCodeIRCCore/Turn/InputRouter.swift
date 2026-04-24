import Foundation

/// Parses raw TextField input into an `InputIntent`. All slash
/// commands are case-insensitive and whitespace-trimmed; anything
/// that isn't a recognised command (or is plain text) falls through
/// to `.message`.
///
/// Why not parse inside `RoomView.send()`? The router is
/// side-effect-free and testable without a live Lattice — unit tests
/// cover command edge cases (`/nick   Alice`, `/side `, `/SIDE X`,
/// bare `/`, etc.) in `InputRouterTests`. The view's `send()` stays
/// a thin dispatch over the resulting intent.
public enum InputRouter {

    public enum InputIntent: Equatable, Sendable {
        /// A chat message. `side == true` marks it as IRC-style
        /// banter — rendered italic + dim in the UI and excluded
        /// from Claude's prompt context by `TurnManager`.
        case message(text: String, side: Bool)

        /// Rename self. Updates `Member.nick` on the host's row and
        /// the caller's `AppPreferences.nick` for next-launch
        /// persistence.
        case setNick(String)

        /// Local-only help text. Caller writes a `.system` `ChatMessage`
        /// so the renderer hands it to `StyledText` like anything else.
        case help

        /// Local-only member-list dump.
        case members

        /// Leave the room. On host this kicks off handoff (P7);
        /// on peer it just disconnects.
        case leave

        /// Recognised slash prefix but unknown command — caller
        /// renders an error banner instead of treating as chat.
        case unknown(String)

        /// Empty / whitespace-only input — send should no-op.
        case empty
    }

    public static func parse(_ raw: String) -> InputIntent {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .empty }
        guard trimmed.hasPrefix("/") else {
            return .message(text: trimmed, side: false)
        }

        // Split into `/cmd` and the remainder. Allow the arg to
        // contain leading/trailing spaces (a `/nick  foo` should
        // yield nick "foo", not "  foo").
        let afterSlash = String(trimmed.dropFirst())
        let (cmd, rest): (String, String) = {
            if let space = afterSlash.firstIndex(of: " ") {
                return (
                    String(afterSlash[..<space]).lowercased(),
                    String(afterSlash[afterSlash.index(after: space)...])
                        .trimmingCharacters(in: .whitespaces))
            }
            return (afterSlash.lowercased(), "")
        }()

        switch cmd {
        case "side":
            // `/side` with no body is rejected — "just a lone /side"
            // isn't meaningful content. Shaped as `.unknown` so the
            // user sees an error, not a silent no-op.
            guard !rest.isEmpty else { return .unknown("/side needs text") }
            return .message(text: rest, side: true)
        case "nick":
            guard !rest.isEmpty else { return .unknown("/nick needs a name") }
            // Nicks can't contain whitespace — keeps status-bar
            // member lists parseable and avoids "alice bob" being a
            // single member.
            guard !rest.contains(where: { $0.isWhitespace }) else {
                return .unknown("/nick can't contain whitespace")
            }
            return .setNick(rest)
        case "help":
            return .help
        case "members":
            return .members
        case "leave":
            return .leave
        case "":
            // Bare "/" — treat as chat so users can type "/usr/bin"
            // without it disappearing into the parser.
            return .message(text: trimmed, side: false)
        default:
            return .unknown("unknown command: /\(cmd)")
        }
    }

    /// Machine-readable slash-command catalogue. Drives the
    /// slash-command autocomplete popup in the workspace input line.
    /// Keep in sync with `parse(_:)` and `helpText`.
    public struct Command: Sendable, Equatable {
        public let name: String        // e.g. "nick"
        public let usage: String       // e.g. "/nick <name>"
        public let description: String // one-line help
    }

    public static let commands: [Command] = [
        Command(name: "help",    usage: "/help",           description: "show the command list"),
        Command(name: "nick",    usage: "/nick <name>",    description: "change your nickname"),
        Command(name: "members", usage: "/members",        description: "list members in this room"),
        Command(name: "side",    usage: "/side <msg>",     description: "banter excluded from Claude's context"),
        Command(name: "leave",   usage: "/leave",          description: "leave the room"),
    ]

    /// Commands whose name starts with `prefix` (after the leading `/`),
    /// case-insensitive. Empty prefix returns the full list. Used by
    /// the slash popup to narrow suggestions as the user types.
    public static func completions(forPrefix prefix: String) -> [Command] {
        let p = prefix.lowercased()
        guard !p.isEmpty else { return commands }
        return commands.filter { $0.name.hasPrefix(p) }
    }

    /// Help text shown when the user types `/help`. Mirrors the list
    /// of commands above; keep in sync.
    public static let helpText: String = """
        commands:
          /help              show this list
          /nick <name>       change your nickname
          /members           list members in this room
          /side <msg>        send chatter that's excluded from Claude's context
          /leave             leave the room
        trigger Claude:
          @claude <prompt>   mention to ask Claude (case-insensitive)
        """
}
