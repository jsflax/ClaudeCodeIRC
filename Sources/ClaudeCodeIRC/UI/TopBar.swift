import ClaudeCodeIRCCore
import Foundation
import NCursesUI

/// Reverse-video bar at the top of the workspace. Shows the app tag,
/// active session name, topic (if set), and a clock in the right
/// gutter. Matches the JSX design's `.topbar` — `bg` fg on `fg` bg.
struct TopBar: View {
    let model: RoomsModel
    @Environment(\.palette) var palette

    var body: some View {
        let active = model.activeRoom
        let name: String = active?.session?.name ?? active?.roomCode ?? "lobby"
        let topic: String = active?.session?.topic ?? ""
        let clock = Self.clockString()

        var line = Text("claude-code.irc").bold()
        line = line + Text("  │  ")
        line = line + Text(name).bold()
        if !topic.isEmpty {
            line = line + Text("  │  topic: ").foregroundColor(.dim)
            line = line + Text(topic)
        }
        line = line + Text("  │  ").foregroundColor(.dim)
        line = line + Text(clock)
        return line.reverse()
    }

    private static func clockString() -> String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return f.string(from: Date())
    }
}
