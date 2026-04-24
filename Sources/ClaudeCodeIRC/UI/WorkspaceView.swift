import ClaudeCodeIRCCore
import Foundation
import struct Lattice.Lattice
import class Lattice.TableResults
import NCursesUI

/// Root view of the app — the 3-column IRC-style layout the design
/// handoff specifies. Shows joined + discovered sessions on the left,
/// the active room's chat in the middle, the members of that room on
/// the right. Top/status bars + input line + hotkey strip fill the
/// top and bottom.
///
/// With no active room, the center pane shows a welcome / empty state
/// nudging the user to pick a discovered session or host one.
struct WorkspaceView: View {
    let model: RoomsModel

    @Environment(\.screen) var screen
    @State private var draft: String = ""
    @State private var hostFormVisible: Bool = false
    @State private var joinFormVisible: Bool = false
    @State private var pendingJoin: DiscoveredRoom?
    @State private var paletteSelectorVisible: Bool = false
    /// Highlighted slash-popup row — driven by ↑/↓, used by Tab / Enter
    /// to pick the selected command instead of always-the-first.
    @State private var slashSelection: String = ""

    @Query(sort: \ApprovalRequest.requestedAt) var approvals: TableResults<ApprovalRequest>

    /// Oldest `.pending` approval — Y/A/D on the host flips its status.
    /// Pending approvals also render as inline cards in the scrollback
    /// via `MessageListView` so both host + peers see what's in-flight.
    private var pendingApproval: ApprovalRequest? {
        approvals.first { $0.status == .pending }
    }

    // MARK: - Slash-popup state

    /// Popup is visible while the user is still picking a command —
    /// draft starts with `/`, has no space yet, AND the portion
    /// after the slash isn't an exact match for a known command.
    /// Once the user has typed out a full command name (`/host`,
    /// `/palette`, …) the popup hides so Enter can send the intent
    /// instead of triggering completion.
    private var slashPopupVisible: Bool {
        guard draft.hasPrefix("/"), !draft.contains(" ") else { return false }
        let cmd = String(draft.dropFirst()).lowercased()
        let isExactMatch = InputRouter.commands.contains { $0.name == cmd }
        return !isExactMatch
    }

    /// Commands matching the current draft prefix. Empty when the
    /// popup isn't visible.
    private var slashCompletions: [InputRouter.Command] {
        guard slashPopupVisible else { return [] }
        return InputRouter.completions(forPrefix: String(draft.dropFirst()))
    }

    var body: some View {
        // `.environment(\.lattice, …)` is set by the parent `RootView`
        // around this view — @Query inside the panels (UsersSidebar,
        // MessageListView, this view's own approvals) resolves against
        // the active room's Lattice (or the in-memory placeholder
        // when no room is active).
        // Fixed-width 3-column layout — NCursesUI's HStack has no
        // flex system, so center-pane width is computed explicitly
        // from the terminal width minus sidebar + separator cols.
        let cols = Term.cols
        let leftWidth = 26
        let rightWidth = 22
        let separatorWidth = 1 * 2  // two vertical rules
        let centerWidth = max(10, cols - leftWidth - rightWidth - separatorWidth)

        // Vertical budget — pin the HStack's height so the chrome
        // (status, input, popup, hotkeys) always fits below. Without
        // this the HStack takes its natural (tall) measure and pushes
        // the popup + hotkey strip off-screen.
        let popupRows = slashPopupVisible
            ? (slashCompletions.count + 1)  // header + one per row
            : 0
        let chromeRows = 1 /* topbar */
            + 1 /* hline */
            + 1 /* status */
            + 1 /* input */
            + popupRows
            + 1 /* hotkey strip */
        let hstackHeight = max(5, Term.rows - chromeRows)

        return VStack(spacing: 0) {
            TopBar(model: model)
            HStack(spacing: 0) {
                SessionsSidebar(model: model, width: leftWidth)
                    .frame(width: leftWidth)
                VLineView()
                centerPane.frame(width: centerWidth)
                VLineView()
                if let room = model.activeRoom {
                    UsersSidebar(room: room, width: rightWidth)
                        .frame(width: rightWidth)
                } else {
                    EmptyView().frame(width: rightWidth)
                }
            }.frame(height: hstackHeight)
            HLineView()
            statusLine
            inputLine
            // Slash popup renders BELOW the input line so the input's
            // VStack position stays stable when the popup appears /
            // disappears. Otherwise NCursesUI's position-based node
            // pairing remounts TextField and its @State cursor resets
            // to 0 on every `/` keystroke.
            if slashPopupVisible {
                SlashPopup(
                    completions: slashCompletions,
                    selection: $slashSelection)
            }
            HotkeyStrip()
        }
        .onKeyPress(27 /* ESC */) {
            // No-op at workspace level — HostForm/JoinForm own their
            // own ESC bindings. Approval cards don't dismiss on ESC;
            // Y/A/D are the explicit affirm/deny keys.
        }
        // Ctrl+N / Ctrl+P cycle joined rooms. ASCII control codes —
        // 14 ("N"-64) and 16 ("P"-64). ncurses surfaces them as raw
        // bytes since we run with keypad off.
        .onKeyPress(14) { model.cycleNext() }
        .onKeyPress(16) { model.cyclePrev() }
        // Alt+1..9 → activate room at 1-based index. Requires the
        // terminal to treat Option as Meta (macOS Terminal.app's
        // "Use Option as Meta" / iTerm2's Esc+ mapping). Decoded by
        // NCursesUI's decodeAfterEsc.
        .onKeyPress(KEY_ALT_1) { model.activateIndex(1) }
        .onKeyPress(KEY_ALT_2) { model.activateIndex(2) }
        .onKeyPress(KEY_ALT_3) { model.activateIndex(3) }
        .onKeyPress(KEY_ALT_4) { model.activateIndex(4) }
        .onKeyPress(KEY_ALT_5) { model.activateIndex(5) }
        .onKeyPress(KEY_ALT_6) { model.activateIndex(6) }
        .onKeyPress(KEY_ALT_7) { model.activateIndex(7) }
        .onKeyPress(KEY_ALT_8) { model.activateIndex(8) }
        .onKeyPress(KEY_ALT_9) { model.activateIndex(9) }
        // Tab — slash-complete when the draft starts with `/`, nick-
        // complete otherwise. TextField lets Tab bubble to us.
        .onKeyPress(9) { handleTab() }
        .onKeyPress(Int32(UInt8(ascii: "Y"))) { castVote(.approved) }
        .onKeyPress(Int32(UInt8(ascii: "y"))) { castVote(.approved) }
        .onKeyPress(Int32(UInt8(ascii: "D"))) { castVote(.denied) }
        .onKeyPress(Int32(UInt8(ascii: "d"))) { castVote(.denied) }
        .onKeyPress(Int32(UInt8(ascii: "A"))) { alwaysAllow() }
        .onKeyPress(Int32(UInt8(ascii: "a"))) { alwaysAllow() }
        .onKeyPress(Int32(KEY_BTAB)) {
            // Shift-Tab cycles permission mode on the host — peers see
            // whatever the host sets via Session sync.
            guard let room = model.activeRoom, room.isHost,
                  let s = room.session else { return }
            s.permissionMode = s.permissionMode.next()
            Log.line("workspace", "permission mode → \(s.permissionMode.label)")
        }
        .overlay(isPresented: $hostFormVisible, dimsBackground: true) {
            HostFormOverlay(
                model: model,
                isPresented: $hostFormVisible,
                onCreated: { _ in hostFormVisible = false })
        }
        .overlay(isPresented: $joinFormVisible, dimsBackground: true) {
            JoinFormOverlay(
                model: model,
                room: pendingJoin,
                isPresented: $joinFormVisible)
        }
        .overlay(isPresented: $paletteSelectorVisible, dimsBackground: true) {
            PaletteSelectorOverlay(
                prefs: model.prefs,
                isPresented: $paletteSelectorVisible)
        }
    }

    // MARK: - Center pane

    @ViewBuilder private var centerPane: some View {
        if let room = model.activeRoom {
            RoomPane(room: room, draft: $draft, onSubmit: send)
        } else {
            WelcomePane()
        }
    }

    // MARK: - Status + input line

    private var statusLine: Text {
        guard let room = model.activeRoom else {
            return Text("[lobby] — no active session, pick one on the left or press /host")
                .foregroundColor(.dim)
        }
        let nick = room.selfMember?.nick ?? "?"
        let selfMark = room.isHost ? "%" : "+"
        let name = room.session?.name ?? room.roomCode
        let mode = room.session?.permissionMode ?? .default
        var line = Text("[\(nick)(\(selfMark))]").foregroundColor(.green)
        line = line + Text(" [\(name)]").foregroundColor(.dim)
        if let j = room.joinCode {
            line = line + Text(" [join:\(j)]").foregroundColor(.yellow)
        } else if room.isHost {
            line = line + Text(" [open]").foregroundColor(.dim)
        }
        if mode != .default {
            line = line + Text(" [\(mode.label)]").foregroundColor(Self.modeColor(mode))
        }
        return line
    }

    private var inputLine: some View {
        let activeName = model.activeRoom?.session?.name
            ?? model.activeRoom?.roomCode
            ?? "lobby"
        // ↑/↓ attached HERE (not on the root workspace) so they sit
        // later in dispatch order than the ScrollView that contains
        // the message list — NCursesUI walks children in reverse for
        // key dispatch, and ScrollView otherwise eats arrow keys for
        // scroll-offset adjustments before they reach us.
        return HStack {
            Text("[\(activeName)] > ").foregroundColor(.yellow)
            TextField("type a message · @claude to invoke · / for commands · Tab to complete",
                      text: $draft,
                      isFocused: inputFocusBinding,
                      onSubmit: send)
        }
        .onKeyPress(Int32(KEY_UP)) {
            if slashPopupVisible { moveSlashSelection(-1) }
        }
        .onKeyPress(Int32(KEY_DOWN)) {
            if slashPopupVisible { moveSlashSelection(+1) }
        }
    }

    private var inputFocusBinding: Binding<Bool> {
        // Defocus the TextField so Y/A/D/ESC bubble past it when:
        //   (a) a form overlay is visible — it owns key handling
        //   (b) an approval is pending AND the draft is empty —
        //       the user isn't mid-typing, so their keystrokes are
        //       votes. Once they start typing (draft non-empty),
        //       TextField reclaims keys so they can finish the word.
        Binding(
            get: {
                if hostFormVisible || joinFormVisible { return false }
                if pendingApproval != nil && draft.isEmpty { return false }
                return true
            },
            set: { _ in })
    }

    private static func modeColor(_ mode: PermissionMode) -> Color {
        switch mode {
        case .default:           return .dim
        case .acceptEdits:       return .green
        case .plan:              return .cyan
        case .auto:              return .red
        case .bypassPermissions: return .red
        }
    }

    // MARK: - Tab completion

    /// Dispatch Tab to either slash-completion (when the draft starts
    /// with a partial `/cmd`) or nick-completion (when the last word
    /// of the draft is a partial nick). Both paths replace just the
    /// incomplete fragment in `draft` in place.
    private func handleTab() {
        if slashPopupVisible {
            completeSlash()
        } else {
            completeNick()
        }
    }

    private func completeSlash() {
        // Prefer the highlighted row; fall back to the first match if
        // the user hasn't touched arrows yet (or the selection scrolled
        // off-list because completions changed).
        let picked = slashCompletions.first { $0.name == slashSelection }
            ?? slashCompletions.first
        guard let picked else { return }
        draft = "/\(picked.name) "
    }

    /// Shift the slash-popup selection by `delta` rows (typically ±1).
    /// Wraps at the boundaries so ↑ on the first row lands on the last
    /// and vice-versa; feels better in a short popup than clamping.
    private func moveSlashSelection(_ delta: Int) {
        let items = slashCompletions
        guard !items.isEmpty else { return }
        let currentIdx = items.firstIndex { $0.name == slashSelection } ?? 0
        let nextIdx = ((currentIdx + delta) % items.count + items.count) % items.count
        slashSelection = items[nextIdx].name
    }

    private func completeNick() {
        guard let room = model.activeRoom else { return }
        // Find the last whitespace-delimited word in the draft.
        let scalars = Array(draft)
        var wordStart = scalars.count
        while wordStart > 0, !scalars[wordStart - 1].isWhitespace {
            wordStart -= 1
        }
        let partial = String(scalars[wordStart..<scalars.count])
        guard !partial.isEmpty else { return }

        // Candidates: every real Member's nick + synthetic "claude".
        let nicks = Array(room.lattice.objects(Member.self)).map(\.nick) + ["claude"]
        let matches = nicks
            .filter { $0.lowercased().hasPrefix(partial.lowercased()) && $0 != partial }
            .sorted()
        guard let match = matches.first else { return }

        // Append `: ` when expanding at the start of the draft (opens
        // a new line addressed to someone), else a single space so the
        // user can continue typing after the nick.
        let suffix = wordStart == 0 ? ": " : " "
        draft = String(scalars[0..<wordStart]) + match + suffix
    }

    // MARK: - Send / approve

    private func send() {
        // Slash popup intercepts Enter — treat it as "pick highlighted
        // command" instead of sending raw. The user still has to press
        // Enter again with real args typed to actually fire the intent.
        if slashPopupVisible {
            completeSlash()
            return
        }
        let raw = draft
        draft = ""
        let intent = InputRouter.parse(raw)

        // Commands that work from the welcome state (no active room
        // yet). /host and /join are how a user gets into their first
        // room, so they can't require one to exist already. /nick
        // also runs here so the nick prefs is set before hosting —
        // otherwise the first room's host Member gets an empty nick.
        switch intent {
        case .empty:
            return
        case .host:
            hostFormVisible = true
            return
        case .join(let filter):
            joinDiscovered(nameFilter: filter, room: model.activeRoom)
            return
        case .palette:
            paletteSelectorVisible = true
            return
        case .setNick(let name):
            model.prefs.nick = name
            if let room = model.activeRoom {
                room.selfMember?.nick = name
                insertSystem(room: room, "nick set to \(name)")
            }
            return
        default:
            break
        }

        // Everything below mutates the active room — nothing to do
        // without one.
        guard let room = model.activeRoom else {
            Log.line("workspace", "ignoring intent \(intent) — no active room")
            return
        }

        // AFK auto-clear: sending any non-system, non-afk content
        // implicitly marks you back. Keeps the "away" state honest
        // without requiring a second `/afk` to toggle off. Runs
        // before the intent switch so the side-effecting cases
        // (message / action / topic / members / help) all benefit.
        if let me = room.selfMember, me.isAway {
            switch intent {
            case .afk: break // explicit toggle — handled below
            case .empty, .unknown, .leave, .clear, .palette, .host, .join: break
            default:
                me.isAway = false
                me.awayReason = nil
                insertSystem(room: room, "\(me.nick) is back")
            }
        }

        switch intent {
        case .empty, .host, .join, .palette, .setNick:
            // Handled above — listed here only for the exhaustive
            // switch; shouldn't reach this branch.
            return
        case .message(let text, let side):
            insertChat(room: room, text: text, kind: .user, side: side)
        case .help:
            insertSystem(room: room, InputRouter.helpText)
        case .members:
            // Ordering goes through a SortDescriptor so Lattice pushes
            // the sort down into SQL rather than materialising every
            // row and sorting in Swift.
            let nicks = room.lattice.objects(Member.self)
                .sortedBy(SortDescriptor(\.joinedAt, order: .forward))
                .map { $0.isHost ? "\($0.nick) (host)" : $0.nick }
                .joined(separator: ", ")
            insertSystem(room: room, "members: \(nicks.isEmpty ? "(none)" : nicks)")
        case .leave:
            let id = room.id
            Task { await model.leave(id) }
        case .clear:
            // Local-only scrollback hide. No Lattice write — floor
            // lives on the RoomInstance and MessageListView reads
            // it to gate rendering.
            room.scrollbackFloor = Date()
        case .setTopic(let text):
            guard let session = room.session else { return }
            session.topic = text
            let nick = room.selfMember?.nick ?? "?"
            insertSystem(room: room, "\(nick) set topic: \(text)")
        case .action(let text):
            insertChat(room: room, text: text, kind: .action, side: false)
        case .afk(let reason):
            guard let me = room.selfMember else { return }
            if me.isAway {
                me.isAway = false
                me.awayReason = nil
                insertSystem(room: room, "\(me.nick) is back")
            } else {
                me.isAway = true
                me.awayReason = reason
                if let r = reason {
                    insertSystem(room: room, "\(me.nick) is away: \(r)")
                } else {
                    insertSystem(room: room, "\(me.nick) is away")
                }
            }
        case .palette:
            paletteSelectorVisible = true
        case .host:
            hostFormVisible = true
        case .join(let filter):
            joinDiscovered(nameFilter: filter, room: room)
        case .unknown(let reason):
            insertSystem(room: room, "error: \(reason)")
        }
    }

    /// Resolve `/join [name]` against the Bonjour-discovered set.
    /// `nil` filter = first unjoined discovery; string filter =
    /// first unjoined discovery whose name starts with it
    /// (case-insensitive). Open rooms are joined directly; rooms
    /// requiring a code pop the join overlay pre-populated.
    ///
    /// `currentRoom` may be nil when the user runs /join from the
    /// welcome state (no room active yet). In that case info /
    /// error feedback goes to the log — there's nowhere visible to
    /// render a system ChatMessage.
    private func joinDiscovered(nameFilter: String?, room currentRoom: RoomInstance?) {
        let joined = Set(model.joinedRooms.map(\.roomCode))
        let unjoined = model.browser.rooms.filter { !joined.contains($0.roomCode) }
        guard !unjoined.isEmpty else {
            feedback("no discovered rooms to join", room: currentRoom)
            return
        }
        let target: DiscoveredRoom?
        if let filter = nameFilter?.lowercased() {
            target = unjoined.first { $0.name.lowercased().hasPrefix(filter) }
        } else {
            target = unjoined.first
        }
        guard let target else {
            feedback("no room matches '\(nameFilter ?? "")'", room: currentRoom)
            return
        }
        pendingJoin = target
        if target.requiresJoinCode {
            joinFormVisible = true
        } else {
            do { _ = try model.join(target, joinCode: nil) }
            catch { feedback("join failed: \(error)", room: currentRoom) }
        }
    }

    /// Surface a short informational line to the user. Emits a
    /// `.system` ChatMessage in the active room if there is one;
    /// otherwise logs — we haven't got a toast / status-bar flash
    /// mechanism yet for the welcome state.
    private func feedback(_ text: String, room: RoomInstance?) {
        if let room { insertSystem(room: room, text) }
        else { Log.line("workspace", text) }
    }

    private func insertChat(room: RoomInstance, text: String, kind: MessageKind, side: Bool) {
        guard let author = room.selfMember, let session = room.session else { return }
        let msg = ChatMessage()
        msg.text = text
        msg.kind = kind
        msg.side = side
        msg.author = author
        msg.session = session
        room.lattice.add(msg)
    }

    private func insertSystem(room: RoomInstance, _ text: String) {
        guard let session = room.session else { return }
        let msg = ChatMessage()
        msg.text = text
        msg.kind = .system
        msg.side = true
        msg.session = session
        room.lattice.add(msg)
    }

    /// Cast a vote as the active member on the oldest `.pending`
    /// approval. Any member can vote (hosts + peers). The shim
    /// wakes up only once `ApprovalVoteCoordinator` tips status out
    /// of `.pending` via the tally; we never flip status here
    /// directly.
    ///
    /// Re-voting overwrites the prior vote: LatticeCore enforces the
    /// compound unique on (voter, request), so we delete any existing
    /// vote row by this member for this request before inserting the
    /// new one — Y→D and D→Y both work without resurrecting the old
    /// count.
    private func castVote(_ decision: ApprovalStatus) {
        guard let room = model.activeRoom,
              let voter = room.selfMember,
              let req = pendingApproval else { return }
        for existing in req.votes where existing.voter?.globalId == voter.globalId {
            room.lattice.delete(existing)
        }
        let vote = ApprovalVote()
        vote.voter = voter
        vote.request = req
        vote.decision = decision
        room.lattice.add(vote)
        Log.line("workspace", "\(voter.nick) voted \(decision) on \(req.toolName)")
    }

    /// Host-only always-allow: writes an `ApprovalPolicy` row so
    /// subsequent calls to the same tool bypass the approval flow,
    /// and commits the current request's status directly (skipping
    /// the vote). Peers pressing [A] no-op — policies authoritatively
    /// come from the host.
    private func alwaysAllow() {
        guard let room = model.activeRoom, room.isHost,
              let req = pendingApproval else { return }
        let policy = ApprovalPolicy()
        policy.toolName = req.toolName
        policy.decision = .approved
        policy.decidedBy = room.selfMember
        room.lattice.add(policy)
        req.status = .approved
        req.decidedAt = Date()
        req.decidedBy = room.selfMember
        Log.line("workspace", "always-allow for tool \(req.toolName)")
    }
}

// MARK: - Slash popup

/// Floating list of slash-command suggestions rendered above the
/// input line when the user is mid-typing a `/command`. Narrow — one
/// row per match, usage on the left and description on the right.
/// Tab or Enter from the input picks the first match (see
/// `WorkspaceView.completeSlash`).
struct SlashPopup: View {
    let completions: [InputRouter.Command]
    @Binding var selection: String

    var body: some View {
        VStack(spacing: 0) {
            Text("── slash commands (↑/↓ navigate · Tab/Enter pick) ──")
                .foregroundColor(.dim)
            if completions.isEmpty {
                Text("  (no matches — Backspace to dismiss)")
                    .foregroundColor(.dim)
            } else {
                // Fall back to the first match when `selection` doesn't
                // name any currently-visible row — happens on first
                // mount (selection: "") and whenever the completion
                // set narrows past the previous pick.
                let active = completions.first(where: { $0.name == selection })
                    ?? completions.first
                ForEach(completions) { cmd in
                    SlashPopupRow(
                        command: cmd,
                        highlighted: cmd.name == active?.name)
                }
            }
        }
    }
}

struct SlashPopupRow: View {
    let command: InputRouter.Command
    let highlighted: Bool

    var body: some View {
        var line = Text("  ")
        line = line + Text(command.usage).foregroundColor(.yellow)
        line = line + Text("  ").foregroundColor(.dim)
        line = line + Text(command.description).foregroundColor(.dim)
        return line.reverse(highlighted)
    }
}

extension InputRouter.Command: Identifiable {
    public var id: String { name }
}

// MARK: - Panes

/// Welcome / empty state shown when no room is active. Nudges the
/// user toward the two entry points — pick a discovered session or
/// host a new one. The hotkey strip below this already advertises
/// `/` for commands.
struct WelcomePane: View {
    var body: some View {
        VStack {
            SpacerView(1)
            Text("welcome to claude-code.irc").foregroundColor(.yellow).bold()
            SpacerView(1)
            Text("pick a discovered session on the left, or press `/host` to start one.")
                .foregroundColor(.dim)
            Text("claude only replies when addressed — use `@claude` anywhere in a message.")
                .foregroundColor(.dim)
        }
    }
}

/// Center pane for an active room — title strip + scrollback +
/// thinking indicator. Pending approval overlay still flies over
/// the whole workspace for now (D6 inlines it into this pane).
struct RoomPane: View {
    let room: RoomInstance
    @Binding var draft: String
    let onSubmit: () -> Void

    @Query(sort: \Turn.startedAt) var turns: TableResults<Turn>

    private var streamingTurn: Turn? {
        turns.first { $0.status == .streaming }
    }

    /// ScrollView reserves the pane's full height minus the title
    /// strip (1) and, when claude is streaming, the thinking strip
    /// (1). Without shrinking here, the ScrollView eats the pane and
    /// the ClaudeThinkingView gets 0 rows → invisible.
    private var scrollHeight: Int {
        let paneHeight = Term.rows - 6 // chrome: topbar+hline+status+input+hotkey+pad
        let thinking = streamingTurn != nil ? 1 : 0
        return max(1, paneHeight - 1 /* title strip */ - thinking)
    }

    var body: some View {
        VStack(spacing: 0) {
            titleStrip
            ScrollView(height: scrollHeight) {
                MessageListView(
                    isHost: room.isHost,
                    scrollbackFloor: room.scrollbackFloor)
            }
            if let t = streamingTurn {
                ClaudeThinkingView(turnId: t.globalId)
            }
        }
    }

    private var titleStrip: some View {
        let name = room.session?.name ?? room.roomCode
        let host = room.session?.host?.nick ?? "?"
        var line = Text("── \(name) ").foregroundColor(.dim)
        line = line + Text("── host: ").foregroundColor(.dim)
        line = line + Text(host).foregroundColor(.yellow)
        line = line + Text(" ──────────").foregroundColor(.dim)
        return line
    }
}

// MARK: - Host form (re-parented from the old LobbyView)

enum HostFormFocus { case name, cwd, auth }

struct HostFormOverlay: View {
    let model: RoomsModel
    @Binding var isPresented: Bool
    let onCreated: (RoomInstance) -> Void

    @State private var focus: HostFormFocus = .name
    @State private var name: String = ""
    @State private var requireCode: Bool = true
    @State private var error: String = ""

    private var cwdBinding: Binding<String> {
        Binding(
            get: { model.prefs.lastCwd },
            set: { model.prefs.lastCwd = $0 })
    }
    private var nameFocus: Binding<Bool> {
        Binding(get: { focus == .name }, set: { _ in })
    }
    private var cwdFocus: Binding<Bool> {
        Binding(get: { focus == .cwd }, set: { _ in })
    }

    var body: some View {
        BoxView("Host a new session", color: .cyan) {
            VStack {
                HStack {
                    Text("name: ").foregroundColor(.dim)
                    TextField("my session",
                              text: $name,
                              isFocused: nameFocus,
                              onSubmit: submit)
                }
                HStack {
                    Text("cwd:  ").foregroundColor(.dim)
                    TextField("/path/to/repo",
                              text: cwdBinding,
                              isFocused: cwdFocus,
                              onSubmit: submit)
                }
                HStack {
                    Text("\(requireCode ? "[x]" : "[ ]") require join code")
                        .foregroundColor(focus == .auth ? .cyan : .white)
                        .reverse(focus == .auth)
                }
                SpacerView(1)
                Text("⇥ switch   space toggle   ↵ create   ⎋ cancel")
                    .foregroundColor(.dim)
                if !error.isEmpty {
                    Text(error).foregroundColor(.red)
                }
            }
        }
        .onKeyPress(9 /* Tab */) {
            focus = switch focus {
            case .name: .cwd
            case .cwd:  .auth
            case .auth: .name
            }
        }
        .onKeyPress(Int32(UInt8(ascii: " "))) {
            if focus == .auth { requireCode.toggle() }
        }
        .onKeyPress(Int32(UInt8(ascii: "\n"))) {
            if focus == .auth { submit() }
        }
        .onKeyPress(27 /* ESC */) {
            isPresented = false
        }
    }

    private func submit() {
        Task {
            do {
                let room = try await model.host(
                    name: name.isEmpty ? "unnamed" : name,
                    cwd: model.prefs.lastCwd,
                    mode: .default,
                    requireJoinCode: requireCode)
                onCreated(room)
            } catch {
                self.error = "\(error)"
            }
        }
    }
}

/// Join form — single TextField for the bearer code.
struct JoinFormOverlay: View {
    let model: RoomsModel
    let room: DiscoveredRoom?
    @Binding var isPresented: Bool

    @State private var joinCode: String = ""
    @State private var error: String = ""

    var body: some View {
        BoxView("Join", color: .cyan) {
            VStack {
                if let room {
                    Text("room: \(room.name)").foregroundColor(.dim)
                    Text("host: \(room.hostNick)").foregroundColor(.dim)
                    SpacerView(1)
                    HStack {
                        Text("code: ").foregroundColor(.dim)
                        TextField("6-char join code",
                                  text: $joinCode,
                                  isFocused: .constant(true),
                                  onSubmit: submit)
                    }
                } else {
                    Text("no room selected").foregroundColor(.red)
                }
                SpacerView(1)
                Text("↵ join   ⎋ cancel").foregroundColor(.dim)
                if !error.isEmpty {
                    Text(error).foregroundColor(.red)
                }
            }
        }
        .onKeyPress(27 /* ESC */) {
            isPresented = false
        }
    }

    private func submit() {
        guard let room else { return }
        do {
            _ = try model.join(room, joinCode: joinCode)
            isPresented = false
        } catch {
            self.error = "\(error)"
        }
    }
}
