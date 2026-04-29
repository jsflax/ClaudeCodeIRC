import ClaudeCodeIRCCore
import Foundation
import class Lattice.TableResults
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

/// Identifies any visible row in `SessionsSidebar` across its mixed
/// sections (joined / recent / LAN / public / group). Used by
/// `WorkspaceView`'s pane-focus navigation so ↑/↓ can step through
/// rows without re-implementing the section structure, and Enter
/// can dispatch per-case to the right activation helper.
enum SessionsSelection: Hashable {
    case joined(UUID)
    case recent(String)
    case lan(String)
    case publicRoom(String)
    case groupRoom(groupHashHex: String, roomId: String)
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
    /// True when this pane is the current Tab-focus target. Section
    /// headers brighten and the row matching `selectedRow` gets the
    /// `▸ ` prefix + reverse-video.
    let paneFocused: Bool
    /// Currently-highlighted row inside this sidebar. Ignored when
    /// `paneFocused` is false (the marker is hidden so users aren't
    /// confused about whether arrow keys are routing here).
    let selectedRow: SessionsSelection?
    @Environment(\.palette) var palette

    /// Codes already in `joinedRooms`. Used by every "discovery"
    /// section to suppress duplicate rows for rooms we're already in.
    private var joinedCodes: Set<String> {
        Set(model.joinedRooms.map(\.roomCode))
    }

    /// Codes the host published to the directory — across the public
    /// bucket and every group. Drives the LAN dedup: a Bonjour find
    /// whose code is also in any directory bucket should NOT show in
    /// the `lan` section, because the host's chosen visibility
    /// (public / group) is what we honour. LAN discovery is a
    /// transport detail — we still use the LAN ws:// URL when
    /// joining if available, but the row is filed under the section
    /// the host advertised it under.
    private var directoryCodes: Set<String> {
        var codes: Set<String> = []
        for rooms in model.directoryRoomsByGroup.values {
            for room in rooms { codes.insert(room.roomId) }
        }
        return codes
    }

    /// Rooms the browser found on the LAN that we haven't joined and
    /// that aren't also published in any directory bucket.
    private var discoveredUnjoined: [DiscoveredRoom] {
        let suppressed = joinedCodes.union(directoryCodes)
        return model.browser.rooms.filter { !suppressed.contains($0.roomCode) }
    }

    /// Public-bucket rooms from the directory minus already-joined.
    private var publicRooms: [DirectoryAPI.ListedRoom] {
        let rooms = model.directoryRoomsByGroup[GroupID.publicBucket] ?? []
        return rooms.filter { !joinedCodes.contains($0.roomId) }
    }

    private var headerColor: Color { paneFocused ? .cyan : .dim }

    var body: some View {
        VStack(spacing: 0) {
            Text(fillRule("sessions (\(model.joinedRooms.count))", width: width))
                .foregroundColor(headerColor)

            ForEach(Array(model.joinedRooms.indices)) { idx in
                SessionRow(
                    idx: idx + 1,
                    room: model.joinedRooms[idx],
                    active: model.joinedRooms[idx].id == model.activeRoomId,
                    highlighted: paneFocused
                        && selectedRow == .joined(model.joinedRooms[idx].id))
            }

            // Recent: persisted rooms we're not currently in. Each row
            // owns its own `@Query Session` against the room's idle
            // Lattice via the `\.lattice` environment, so the displayed
            // name + lock state reflect live writes.
            if !model.recentLattices.isEmpty {
                SpacerView(1)
                Text(fillRule("recent (\(model.recentLattices.count))", width: width))
                    .foregroundColor(headerColor)
                ForEach(Array(model.recentLattices.indices)) { idx in
                    let entry = model.recentLattices[idx]
                    RecentRoomRow(
                        code: entry.code,
                        highlighted: paneFocused && selectedRow == .recent(entry.code))
                        .environment(\.lattice, entry.lattice)
                }
            }

            SpacerView(1)
            Text(fillRule("lan", width: width)).foregroundColor(headerColor)
            ForEach(discoveredUnjoined) { room in
                DiscoveredRow(
                    room: room,
                    highlighted: paneFocused && selectedRow == .lan(room.roomCode))
            }

            // Public bucket — directory rooms anyone can browse. Hidden
            // when empty so the sidebar doesn't grow a perpetual empty
            // header on `.private`-only setups.
            if !publicRooms.isEmpty {
                SpacerView(1)
                Text(fillRule("public (\(publicRooms.count))", width: width))
                    .foregroundColor(headerColor)
                ForEach(publicRooms) { room in
                    DirectoryRow(
                        room: room,
                        highlighted: paneFocused && selectedRow == .publicRoom(room.roomId))
                }
            }

            // Groups — one section per `LocalGroup`, driven by a
            // `@Query LocalGroup` against `prefs.lattice` so adding a
            // new invite (`/addgroup`) materialises a new section
            // without restart. Each section's contents come from
            // `directoryRoomsByGroup[group.hashHex]`.
            GroupsSidebarSection(
                model: model,
                width: width,
                joinedCodes: joinedCodes,
                paneFocused: paneFocused,
                selectedRow: selectedRow)
                .environment(\.lattice, model.prefsLattice)

            SpacerView(1)
            Text("[+] /host   /reopen [name]   /addgroup").foregroundColor(.yellow)
        }
    }

    /// Visible rows in render order — joined → recent → LAN → public →
    /// each group. Used by `WorkspaceView` for ↑/↓ pane navigation so
    /// the keyboard cursor walks the same sequence the user sees.
    /// Reads directly from `model` (and `model.prefsLattice` for
    /// groups) — no `@Query` indirection needed.
    static func flatRows(model: RoomsModel) -> [SessionsSelection] {
        var rows: [SessionsSelection] = []
        let joinedCodes = Set(model.joinedRooms.map(\.roomCode))
        // Same dedup rule as the live sidebar: a Bonjour find that's
        // also published in any directory bucket gets filed under
        // public/group, not LAN.
        var directoryCodes: Set<String> = []
        for ds in model.directoryRoomsByGroup.values {
            for r in ds { directoryCodes.insert(r.roomId) }
        }

        for room in model.joinedRooms {
            rows.append(.joined(room.id))
        }
        for entry in model.recentLattices {
            rows.append(.recent(entry.code))
        }
        for room in model.browser.rooms
        where !joinedCodes.contains(room.roomCode)
            && !directoryCodes.contains(room.roomCode) {
            rows.append(.lan(room.roomCode))
        }
        let publics = (model.directoryRoomsByGroup[GroupID.publicBucket] ?? [])
            .filter { !joinedCodes.contains($0.roomId) }
        for room in publics {
            rows.append(.publicRoom(room.roomId))
        }
        let groups = Array(model.prefsLattice.objects(LocalGroup.self)
            .sortedBy(SortDescriptor(\.addedAt, order: .forward)))
        for group in groups {
            let groupRooms = (model.directoryRoomsByGroup[group.hashHex] ?? [])
                .filter { !joinedCodes.contains($0.roomId) }
            for room in groupRooms {
                rows.append(.groupRoom(groupHashHex: group.hashHex, roomId: room.roomId))
            }
        }
        return rows
    }
}

/// Driven by `@Query LocalGroup` against the prefs lattice (installed
/// via the parent's `.environment(\.lattice, ...)` override). Renders
/// one section per stored group. Each section's room rows come from
/// `model.directoryRoomsByGroup[group.hashHex]` — the directory client
/// queries each group's hash on its poll cycle, so this section
/// auto-refreshes with the snapshot.
struct GroupsSidebarSection: View {
    let model: RoomsModel
    let width: Int
    let joinedCodes: Set<String>
    let paneFocused: Bool
    let selectedRow: SessionsSelection?

    @Query(sort: \LocalGroup.addedAt) var groups: TableResults<LocalGroup>

    private var headerColor: Color { paneFocused ? .cyan : .dim }

    @ViewBuilder var body: some View {
        let groupArray = Array(groups)
        if groupArray.isEmpty {
            // Empty state — surface the two ways to add a group right
            // where the user is looking for them. Without this, /addgroup
            // and /newgroup are only discoverable via the slash popup
            // and the small footer line, neither of which the user
            // noticed during early testing.
            VStack(spacing: 0) {
                SpacerView(1)
                Text(fillRule("groups", width: width)).foregroundColor(headerColor)
                Text("  (none — /addgroup to paste invite)").foregroundColor(.dim)
                Text("  (or /newgroup <name> to create one)").foregroundColor(.dim)
            }
        } else {
            ForEach(groupArray) { group in
                let rooms = (model.directoryRoomsByGroup[group.hashHex] ?? [])
                    .filter { !joinedCodes.contains($0.roomId) }
                // Always render the section header for a group the user
                // joined — empty state is informative ("Canary (0)" tells
                // them the group is being polled and just has no public
                // rooms right now).
                VStack(spacing: 0) {
                    SpacerView(1)
                    Text(fillRule("\(group.name) (\(rooms.count))", width: width))
                        .foregroundColor(headerColor)
                    ForEach(rooms) { room in
                        DirectoryRow(
                            room: room,
                            highlighted: paneFocused
                                && selectedRow == .groupRoom(
                                    groupHashHex: group.hashHex,
                                    roomId: room.roomId))
                    }
                }
            }
        }
    }
}

/// One directory-listed room (Public or Group). Rendered identically
/// across both — the section header is what conveys scope. Activated
/// via `/join <name>` when the user wants to enter (the same path as
/// LAN-discovered rooms; the lobby code resolves the listing's
/// `wssURL` and treats it as a `DiscoveredRoom`).
struct DirectoryRow: View {
    let room: DirectoryAPI.ListedRoom
    let highlighted: Bool

    var body: some View {
        var line = Text(highlighted ? "▸ " : "  ")
        line = line + Text(room.name).foregroundColor(.white)
        line = line + Text("  ").foregroundColor(.dim)
        line = line + Text("@\(room.hostHandle)").foregroundColor(.dim)
        return line.reverse(highlighted)
    }
}

/// One recent-room row. Reads its `Session` live via `@Query` so the
/// rendered name updates if the row is mutated underneath us (another
/// instance of the app, a swap-target snippet, etc.). The row is
/// activated via `/reopen [name]` from the input line — sidebar
/// itself has no per-row click handler.
struct RecentRoomRow: View {
    let code: String
    let highlighted: Bool

    @Query var sessions: TableResults<Session>

    var body: some View {
        let session = Array(sessions).first(where: { $0.code == code })
        var line = Text(highlighted ? "▸ " : "  ")
        line = line + Text(session?.name ?? code).foregroundColor(.white)
        if session?.joinCode != nil {
            line = line + Text(" 🔒").foregroundColor(.dim)
        }
        if let v = session?.visibility, v != .private {
            line = line + Text("  \(v.rawValue)").foregroundColor(.dim)
        }
        return line.reverse(highlighted)
    }
}

/// A single joined-room row in the sessions sidebar.
struct SessionRow: View {
    let idx: Int
    let room: RoomInstance
    let active: Bool
    let highlighted: Bool

    var body: some View {
        let label = room.session?.name ?? room.roomCode
        var line = Text(highlighted ? "▸ " : "  ")
        line = line + Text("\(idx) ").foregroundColor(.dim)
        line = line + Text(label)
        if room.joinCode != nil {
            line = line + Text(" 🔒").foregroundColor(.dim)
        }
        return line.reverse(active || highlighted)
    }
}

/// A Bonjour-discovered row (not yet joined).
struct DiscoveredRow: View {
    let room: DiscoveredRoom
    let highlighted: Bool

    var body: some View {
        var line = Text(highlighted ? "▸ " : "  ")
        line = line + Text(room.name).foregroundColor(.white)
        line = line + Text("  ").foregroundColor(.dim)
        line = line + Text(room.cwd).foregroundColor(.dim)
        if room.requiresJoinCode {
            line = line + Text(" 🔒").foregroundColor(.dim)
        }
        return line.reverse(highlighted)
    }
}
