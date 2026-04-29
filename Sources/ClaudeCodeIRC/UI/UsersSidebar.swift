import ClaudeCodeIRCCore
import Foundation
import class Lattice.TableResults
import NCursesUI

/// Right column of the workspace. Renders the member list of the
/// active room, with a synthetic `@claude` entry on top (real
/// `Member` rows don't include it — the driver lives on the host
/// process, not in Lattice). AFK members dim + `(afk)` suffix.
struct UsersSidebar: View {
    let room: RoomInstance
    let width: Int
    /// True when this pane is the current Tab-focus target. Tints the
    /// section header and surfaces the `▸ ` selection marker on
    /// `selectedNick`'s row.
    let paneFocused: Bool
    /// `Member.globalId` of the row currently under the keyboard
    /// cursor. Synthetic `@claude` is never selectable.
    let selectedNick: UUID?

    @Query(sort: \Member.joinedAt) var members: TableResults<Member>
    @Environment(\.palette) var palette

    private var headerColor: Color { paneFocused ? .cyan : .dim }

    var body: some View {
        let realMembers = Array(members)
        return VStack(spacing: 0) {
            Text(fillRule("users (\(realMembers.count + 1))", width: width))
                .foregroundColor(headerColor)

            // Synthetic claude entry. Both host and peers show this —
            // peers still address @claude, their messages sync to the
            // host who runs the driver.
            UserRow(
                mode: "@",
                nick: "claude",
                isSelf: false,
                isBot: true,
                isAway: false,
                highlighted: false)

            ForEach(realMembers) { m in
                UserRow(
                    mode: modeFor(m),
                    nick: m.nick,
                    isSelf: m.globalId == room.selfMember?.globalId,
                    isBot: false,
                    isAway: m.isAway,
                    highlighted: paneFocused && selectedNick == m.globalId)
            }
        }
    }

    private func modeFor(_ m: Member) -> String {
        if m.isHost { return "%" }
        if m.globalId == room.selfMember?.globalId { return "+" }
        return " "
    }
}

/// One row in the user list. Mode glyph is accent-colored; nick
/// dim + suffix when afk, bold when self, accent when bot.
struct UserRow: View {
    let mode: String
    let nick: String
    let isSelf: Bool
    let isBot: Bool
    let isAway: Bool
    let highlighted: Bool

    var body: some View {
        var line = Text(highlighted ? "▸" : " ")
        line = line + Text(mode).foregroundColor(.yellow)
        // Self renders green so the user's own row pops; bots get
        // yellow (matches the chat-pane treatment of `@claude`); away
        // members dim. Everyone else hashes through `NickColor` so
        // their colour matches the chat scrollback — same person
        // reads as the same colour in both surfaces.
        let nickColor: Color = isAway
            ? .dim
            : isBot
                ? .yellow
                : isSelf
                    ? .green
                    : NickColor.color(for: nick)
        var nickText = Text(nick).foregroundColor(nickColor)
        if isSelf { nickText = nickText.bold() }
        line = line + nickText
        if isAway {
            line = line + Text(" (afk)").foregroundColor(.dim)
        }
        if isBot {
            line = line + Text("  bot").foregroundColor(.dim)
        }
        return line.reverse(highlighted)
    }
}
