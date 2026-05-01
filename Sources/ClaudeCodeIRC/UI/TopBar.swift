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
        // Per-device nick from prefs — shown in lobby AND rooms so the
        // user can always confirm what handle they're on. Empty in the
        // brief window before the first-run picker submits.
        let nick: String = model.prefs.nick

        return HStack(spacing: 0) {
            // Static prefix — re-renders only when the active room
            // / topic / nick changes (driven by RoomsModel observers).
            staticHeader(name: name, topic: topic, nick: nick)
            // Live clock — its own view so only it re-renders on
            // every minute tick. Without the split, the State write
            // for `now` would invalidate the whole TopBar body.
            Clock()
        }
    }

    /// Reverse-video header — bg/fg swap matches the topbar look in
    /// the design (`var(--tui-fg)` background, `var(--tui-bg)` text).
    /// `.reverse()` lives on Text, so we apply it here and let the
    /// HStack compose the already-styled runs alongside `Clock`.
    private func staticHeader(name: String, topic: String, nick: String) -> Text {
        var line = Text("claude-code.irc").bold()
        if !nick.isEmpty {
            line = line + Text("  │  ")
            line = line + Text("<\(nick)>").bold()
        }
        line = line + Text("  │  ")
        line = line + Text(name).bold()
        if !topic.isEmpty {
            line = line + Text("  │  topic: ").foregroundColor(.dim)
            line = line + Text(topic)
        }
        line = line + Text("  │  ").foregroundColor(.dim)
        return line.reverse()
    }
}

/// Self-contained HH:mm display that ticks every 30 s. Lives in its
/// own view so its `@State now` write only invalidates this subtree
/// — the rest of `TopBar` (app tag, room name, topic, separators)
/// doesn't need to redraw.
///
/// 30 s is enough granularity for HH:mm precision — the worst-case
/// stall at the minute boundary is 30 s, which is fine for a TUI.
/// Sleeping until exactly the next `:00` is more code for marginal
/// benefit.
private struct Clock: View {
    @State private var now: Date = Date()

    var body: some View {
        Text(Self.clockString(now)).reverse()
            .task(id: "clock-tick") {
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(30))
                    if Task.isCancelled { return }
                    now = Date()
                }
            }
    }

    private static func clockString(_ d: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return f.string(from: d)
    }
}
