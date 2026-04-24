import ClaudeCodeIRCCore
import class Lattice.TableResults
import NCursesUI

/// Right column of the workspace. Renders the member list of the
/// active room, with a synthetic `@claude` entry on top (real
/// `Member` rows don't include it — the driver lives on the host
/// process, not in Lattice). AFK members dim + `(afk)` suffix.
struct UsersSidebar: View {
    let room: RoomInstance

    @Query(sort: \Member.joinedAt) var members: TableResults<Member>
    @Environment(\.palette) var palette

    var body: some View {
        let realMembers = Array(members)
        return VStack(spacing: 0) {
            Text("── users ── \(realMembers.count + 1) ──")
                .foregroundColor(.dim)

            // Synthetic claude entry. Both host and peers show this —
            // peers still address @claude, their messages sync to the
            // host who runs the driver.
            UserRow(
                mode: "@",
                nick: "claude",
                isSelf: false,
                isBot: true,
                isAway: false)

            ForEach(realMembers) { m in
                UserRow(
                    mode: modeFor(m),
                    nick: m.nick,
                    isSelf: m.globalId == room.selfMember?.globalId,
                    isBot: false,
                    isAway: m.isAway)
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

    var body: some View {
        var line = Text(mode).foregroundColor(.yellow)
        let nickColor: Color = isAway
            ? .dim
            : isBot
                ? .yellow
                : isSelf
                    ? .green
                    : .white
        var nickText = Text(nick).foregroundColor(nickColor)
        if isSelf { nickText = nickText.bold() }
        line = line + nickText
        if isAway {
            line = line + Text(" (afk)").foregroundColor(.dim)
        }
        if isBot {
            line = line + Text("  bot").foregroundColor(.dim)
        }
        return line
    }
}
