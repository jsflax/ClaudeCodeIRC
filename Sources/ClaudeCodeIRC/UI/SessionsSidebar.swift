import ClaudeCodeIRCCore
import NCursesUI

/// Build a sidebar divider label that fills `width` cols: `── <label> `
/// followed by as many `─` as fit. Matches the panel-header look from
/// the JSX handoff without hardcoding a trailing dash count per call
/// site (previously `── sessions (1) ────────` capped at 8 trailing
/// dashes regardless of sidebar width).
func fillRule(_ label: String, width: Int) -> String {
    let prefix = "── \(label) "
    let fill = max(0, width - prefix.count)
    return prefix + String(repeating: "─", count: fill)
}

/// Left column of the workspace. Shows two groups:
///   1. Joined rooms — one row per `RoomInstance` in `model.joinedRooms`,
///      active row reverse-videoed. Alt+1..9 also maps here.
///   2. Discovered rooms — Bonjour finds on the LAN that this instance
///      hasn't already joined. Opening one goes through the join overlay
///      (or joins directly if the room is open).
///
/// Trailing `[+] /host` row reminds the user how to host from the
/// hotkey strip; the actual overlay mount lives in `WorkspaceView`.
struct SessionsSidebar: View {
    let model: RoomsModel
    /// Width the parent pinned via `.frame(width:)`. Drives the
    /// divider-fill length so the `── label ────` rule spans the full
    /// sidebar instead of a fixed dash count.
    let width: Int
    @Environment(\.palette) var palette

    /// Rooms the browser found on the LAN that we haven't already
    /// joined — avoid duplicate rows for a room we're sitting in.
    private var discoveredUnjoined: [DiscoveredRoom] {
        let joinedCodes = Set(model.joinedRooms.map(\.roomCode))
        return model.browser.rooms.filter { !joinedCodes.contains($0.roomCode) }
    }

    var body: some View {
        VStack(spacing: 0) {
            Text(fillRule("sessions (\(model.joinedRooms.count))", width: width))
                .foregroundColor(.dim)

            ForEach(Array(model.joinedRooms.indices)) { idx in
                SessionRow(
                    idx: idx + 1,
                    room: model.joinedRooms[idx],
                    active: model.joinedRooms[idx].id == model.activeRoomId)
            }

            SpacerView(1)
            Text(fillRule("discovered", width: width)).foregroundColor(.dim)

            ForEach(discoveredUnjoined) { room in
                DiscoveredRow(room: room)
            }

            SpacerView(1)
            Text("[+] /host").foregroundColor(.yellow)
        }
    }
}

/// A single joined-room row in the sessions sidebar.
struct SessionRow: View {
    let idx: Int
    let room: RoomInstance
    let active: Bool

    var body: some View {
        let label = room.session?.name ?? room.roomCode
        var line = Text("\(idx) ").foregroundColor(.dim)
        line = line + Text(label)
        if room.joinCode != nil {
            line = line + Text(" 🔒").foregroundColor(.dim)
        }
        return line.reverse(active)
    }
}

/// A Bonjour-discovered row (not yet joined).
struct DiscoveredRow: View {
    let room: DiscoveredRoom

    var body: some View {
        var line = Text("  ")
        line = line + Text(room.name).foregroundColor(.white)
        line = line + Text("  ").foregroundColor(.dim)
        line = line + Text(room.cwd).foregroundColor(.dim)
        if room.requiresJoinCode {
            line = line + Text(" 🔒").foregroundColor(.dim)
        }
        return line
    }
}
