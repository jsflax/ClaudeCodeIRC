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

        /// Leave AND delete the room — same teardown as `.leave`,
        /// then closes the on-disk Lattice handle and removes the
        /// `<DATA_DIR>/rooms/<code>.lattice` file. The room
        /// disappears from the Recent sidebar after this. On host,
        /// the directory entry is also DELETEd via the publisher's
        /// stop path before the file is removed.
        case deleteRoom

        /// Host-only. Remove a member from the room by nick. The
        /// host's lattice deletes the target Member row; the delete
        /// syncs to the kicked peer, whose `selfMemberObserver`
        /// auto-ejects them. Kicking yourself by nick aliases to
        /// `/leave`.
        case kick(String)

        /// Hide scrollback up to now in this client's view. Doesn't
        /// delete any Lattice rows; a `scrollbackFloor: Date` on the
        /// RoomInstance is set to `.now` and `MessageListView`
        /// filters events below it.
        case clear

        /// Set the session topic. Syncs to peers as a `Session.topic`
        /// update; host-side only semantic (peers can set it too but
        /// host's last-writer-wins). Caller emits a system chat line.
        case setTopic(String)

        /// IRC-style action — renders "* <nick> <text>" italic-accent.
        /// Caller writes a `ChatMessage` with kind `.action`.
        case action(String)

        /// Toggle self-AFK. `reason` is the optional blurb shown in
        /// the users sidebar and the system message ("<you> is away:
        /// brb coffee"). Passing nil or empty toggles back to present.
        case afk(String?)

        /// Open the palette selector overlay. No arguments — the
        /// overlay itself drives the pick. Caller flips a `@State`
        /// flag on the root view to present the modal.
        case palette

        /// Open the "host a new session" form overlay. Caller flips
        /// the corresponding `@State` on WorkspaceView.
        case host

        /// Join a Bonjour-discovered room. `nameFilter` narrows to
        /// rooms whose name starts with it (case-insensitive); nil
        /// picks the first unjoined discovered room. Caller opens the
        /// join overlay (if the room requires a code) or joins
        /// directly (open rooms).
        case join(String?)

        /// Reopen a room whose `.lattice` file is on disk but which
        /// we're not currently in. `filter` narrows by name OR code
        /// (case-insensitive prefix); nil picks the first persisted
        /// room. The caller decides host vs peer reopen by reading
        /// the persisted `Session.host?.nick`.
        case reopen(String?)

        /// Open the "add group" overlay so the user can paste a
        /// `ccirc-group:v1:` invite and persist the resulting
        /// `LocalGroup` row. No arguments — the overlay collects the
        /// paste itself.
        case addGroup

        /// Create a brand-new local group with the given name and a
        /// freshly-generated 32-byte secret. The handler computes the
        /// `hashHex` (sha256 of the secret), inserts a `LocalGroup`
        /// row in `prefs.lattice`, and emits the resulting invite code
        /// (`ccirc-group:v1:<name>:<base64url(secret)>`) as a system
        /// message in the lobby so the user can copy/share it.
        case newGroup(String)

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
        case "delete-room":
            return .deleteRoom
        case "kick":
            guard !rest.isEmpty else { return .unknown("/kick needs a nick") }
            // Same single-token rule as /nick — the rest of the line
            // is the target's nick, no embedded whitespace allowed.
            guard !rest.contains(where: { $0.isWhitespace }) else {
                return .unknown("/kick takes one nick (no whitespace)")
            }
            return .kick(rest)
        case "clear":
            return .clear
        case "topic":
            guard !rest.isEmpty else { return .unknown("/topic needs text") }
            return .setTopic(rest)
        case "me":
            guard !rest.isEmpty else { return .unknown("/me needs text") }
            return .action(rest)
        case "afk":
            // `/afk` toggles; `/afk <reason>` sets the reason.
            // Empty `rest` is a legitimate toggle-off path.
            return .afk(rest.isEmpty ? nil : rest)
        case "palette":
            return .palette
        case "host":
            return .host
        case "join":
            return .join(rest.isEmpty ? nil : rest)
        case "reopen":
            return .reopen(rest.isEmpty ? nil : rest)
        case "addgroup":
            return .addGroup
        case "newgroup":
            // Group name must be non-empty and contain no whitespace —
            // it ends up in the invite code wire format and the
            // sidebar section header.
            guard !rest.isEmpty else { return .unknown("/newgroup needs a name") }
            guard !rest.contains(where: { $0.isWhitespace }) else {
                return .unknown("/newgroup name can't contain whitespace")
            }
            return .newGroup(rest)
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
        Command(name: "host",    usage: "/host",           description: "host a new session (opens form overlay)"),
        Command(name: "join",    usage: "/join [name]",    description: "join a discovered room (prefix match)"),
        Command(name: "reopen",  usage: "/reopen [name]",  description: "reopen a previously joined room from disk"),
        Command(name: "addgroup",usage: "/addgroup",       description: "add a group invite (opens form to paste)"),
        Command(name: "newgroup",usage: "/newgroup <name>", description: "create a new group, prints invite to share"),
        Command(name: "nick",    usage: "/nick <name>",    description: "change your nickname"),
        Command(name: "members", usage: "/members",        description: "list members in this room"),
        Command(name: "side",    usage: "/side <msg>",     description: "banter excluded from Claude's context"),
        Command(name: "me",      usage: "/me <action>",    description: "emote — \"* <you> <action>\""),
        Command(name: "topic",   usage: "/topic <text>",   description: "set the session topic"),
        Command(name: "afk",     usage: "/afk [reason]",   description: "toggle away — excluded from vote quorum"),
        Command(name: "clear",   usage: "/clear",          description: "hide scrollback up to now (local)"),
        Command(name: "palette", usage: "/palette",        description: "pick a UI palette — phosphor / amber / modern / claude"),
        Command(name: "leave",   usage: "/leave",          description: "leave the room"),
        Command(name: "delete-room", usage: "/delete-room", description: "leave the room AND delete its on-disk lattice"),
        Command(name: "kick",    usage: "/kick <nick>",    description: "host-only — remove a member from the room"),
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
          /me <action>       emote — "* <you> <action>"
          /topic <text>      set the session topic
          /afk [reason]      toggle away — excluded from vote quorum
          /clear             hide scrollback up to now (local only)
          /palette           pick a UI palette
          /leave             leave the room
          /delete-room       leave AND delete the room's on-disk lattice
          /kick <nick>       host-only — remove a member from the room
        trigger Claude:
          @claude <prompt>   mention to ask Claude (case-insensitive)
        """
}
