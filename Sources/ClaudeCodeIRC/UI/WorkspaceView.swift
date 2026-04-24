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

    @Query(sort: \ApprovalRequest.requestedAt) var approvals: TableResults<ApprovalRequest>

    /// Oldest `.pending` approval — Y/A/D on the host flips its status.
    /// Pending approvals also render as inline cards in the scrollback
    /// via `MessageListView` so both host + peers see what's in-flight.
    private var pendingApproval: ApprovalRequest? {
        approvals.first { $0.status == .pending }
    }

    // MARK: - Slash-popup state

    /// Popup is visible whenever the draft looks like a partial slash
    /// command — starts with `/` and the command portion hasn't yet
    /// been terminated by a space (once the user types past the
    /// command word, they're filling in arguments, not picking).
    private var slashPopupVisible: Bool {
        draft.hasPrefix("/") && !draft.contains(" ")
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
        VStack(spacing: 0) {
            TopBar(model: model)
            HStack(spacing: 1) {
                SessionsSidebar(model: model)
                Text("│").foregroundColor(.dim)
                centerPane
                Text("│").foregroundColor(.dim)
                if let room = model.activeRoom {
                    UsersSidebar(room: room)
                } else {
                    EmptyView()
                }
            }
            HLineView()
            statusLine
            if slashPopupVisible {
                SlashPopup(completions: slashCompletions)
            }
            inputLine
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
        .onKeyPress(Int32(UInt8(ascii: "Y"))) { decide(.approved, persist: false) }
        .onKeyPress(Int32(UInt8(ascii: "y"))) { decide(.approved, persist: false) }
        .onKeyPress(Int32(UInt8(ascii: "A"))) { decide(.approved, persist: true) }
        .onKeyPress(Int32(UInt8(ascii: "a"))) { decide(.approved, persist: true) }
        .onKeyPress(Int32(UInt8(ascii: "D"))) { decide(.denied,   persist: false) }
        .onKeyPress(Int32(UInt8(ascii: "d"))) { decide(.denied,   persist: false) }
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
        return HStack {
            Text("[\(activeName)] > ").foregroundColor(.yellow)
            TextField("type a message · @claude to invoke · / for commands · Tab to complete",
                      text: $draft,
                      isFocused: inputFocusBinding,
                      onSubmit: send)
        }
    }

    private var inputFocusBinding: Binding<Bool> {
        // Unfocus the TextField while a form overlay is visible OR a
        // pending approval awaits a host keypress — in both cases we
        // want Y/A/D/ESC to bubble past TextField to the root hotkey
        // handlers instead of being typed into the draft.
        Binding(
            get: { !(hostFormVisible || joinFormVisible)
                && !(pendingApproval != nil && (model.activeRoom?.isHost ?? false)) },
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
        guard let match = slashCompletions.first else { return }
        // Replace the whole draft with the matched command's slug so
        // subsequent keystrokes fill in arguments. The trailing space
        // makes typing "claude" or a path immediately useful.
        draft = "/\(match.name) "
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
        guard let room = model.activeRoom else { return }
        let raw = draft
        draft = ""
        let intent = InputRouter.parse(raw)
        switch intent {
        case .empty: return
        case .message(let text, let side):
            insertChat(room: room, text: text, kind: .user, side: side)
        case .setNick(let name):
            room.selfMember?.nick = name
            room.prefs.nick = name
            insertSystem(room: room, "nick set to \(name)")
        case .help:
            insertSystem(room: room, InputRouter.helpText)
        case .members:
            let nicks = Array(room.lattice.objects(Member.self))
                .sorted { $0.joinedAt < $1.joinedAt }
                .map { $0.isHost ? "\($0.nick) (host)" : $0.nick }
                .joined(separator: ", ")
            insertSystem(room: room, "members: \(nicks.isEmpty ? "(none)" : nicks)")
        case .leave:
            let id = room.id
            Task { await model.leave(id) }
        case .unknown(let reason):
            insertSystem(room: room, "error: \(reason)")
        }
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

    /// Mutate the oldest `.pending` approval on the active room so the
    /// shim's change observer wakes up. [A] persists a sticky
    /// `ApprovalPolicy` in addition; peers pressing [A] no-op (only
    /// the host can always-allow).
    ///
    /// D6 replaces this with democratic voting via `ApprovalVote` +
    /// `ApprovalTally` — for this landing the host still flips status
    /// directly so the existing shim path keeps working.
    private func decide(_ status: ApprovalStatus, persist: Bool) {
        guard let room = model.activeRoom, room.isHost else { return }
        let pending = room.lattice.objects(ApprovalRequest.self)
            .sortedBy(SortDescriptor(\.requestedAt, order: .forward))
            .first { $0.status == .pending }
        guard let req = pending else { return }
        req.status = status
        req.decidedAt = Date()
        req.decidedBy = room.selfMember
        if persist {
            let policy = ApprovalPolicy()
            policy.toolName = req.toolName
            policy.decision = status
            policy.decidedBy = room.selfMember
            room.lattice.add(policy)
        }
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

    var body: some View {
        VStack(spacing: 0) {
            Text("── slash commands ─────────")
                .foregroundColor(.dim)
            if completions.isEmpty {
                Text("  (no matches — Esc or Backspace to dismiss)")
                    .foregroundColor(.dim)
            } else {
                // Highlight the first match — that's what Tab picks.
                ForEach(completions) { cmd in
                    SlashPopupRow(
                        command: cmd,
                        highlighted: cmd == completions.first)
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

    private var scrollHeight: Int {
        // Terminal rows minus fixed chrome (top bar + status + input +
        // hotkey strip + 2 HLine rules ≈ 6).
        max(1, Term.rows - 6)
    }

    private var streamingTurn: Turn? {
        turns.first { $0.status == .streaming }
    }

    var body: some View {
        VStack(spacing: 0) {
            titleStrip
            ScrollView(height: scrollHeight) {
                MessageListView(isHost: room.isHost)
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
