import ClaudeCodeIRCCore
import Foundation
import Lattice
import NCursesUI

// Both `Lattice` and `ClaudeCodeIRCCore` (the latter via `App/Query.swift`)
// publicly export a `Query<T>`. The full `import Lattice` is needed
// for the `Query<T>` operator overloads + `LatticeUnion` conformances
// used in `.where { ... }` closures, but it makes the bare `Query`
// name ambiguous at use sites. Pin the unqualified name to the
// app's property-wrapper in CCIRCCore.
typealias Query<T: Lattice.Model> = ClaudeCodeIRCCore.Query<T>

/// Tab-cycle stops in `WorkspaceView`. The center chat pane is
/// intentionally not a focus stop — its scroll view already owns
/// arrow keys, and Enter on chat has no row-level action.
enum FocusedPane { case input, sessions, users }

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
    @State private var addGroupVisible: Bool = false
    @State private var pendingJoin: DiscoveredRoom?
    @State private var paletteSelectorVisible: Bool = false
    /// Set after `/newgroup <name>` succeeds while no room is active —
    /// the lobby welcome pane renders this as a copy-friendly banner so
    /// the user can grab the invite. Cleared via Escape from the lobby
    /// or by joining/hosting a room.
    @State private var pendingNewGroupInvite: String?
    /// Highlighted slash-popup row — driven by ↑/↓, used by Tab / Enter
    /// to pick the selected command instead of always-the-first.
    @State private var slashSelection: String = ""

    // MARK: - Pane focus
    //
    // Tab cycles the keyboard focus across input → sessions → users →
    // input. While a sidebar is focused, ↑/↓ navigate row selection
    // and Enter activates (joins / switches / reopens for sessions;
    // no-op for users). The TextField defocuses while a sidebar is
    // focused so the cursor stops blinking and other keys bubble.
    //
    // `focusedPane` is only consulted after the existing auto-defocus
    // rules (form overlays, pending approval/AskQuestion + empty draft)
    // have decided they don't want focus — those win at higher priority.
    @State private var focusedPane: FocusedPane = .input
    /// Selected row in the sessions sidebar. Cleared on `.input` and
    /// re-seeded to the first visible row when focus enters `.sessions`.
    @State private var sessionsSelection: SessionsSelection? = nil
    /// `Member.globalId` of the highlighted users-sidebar row. Synthetic
    /// `@claude` is never selectable.
    @State private var usersSelection: UUID? = nil

    @Query(sort: \ApprovalRequest.requestedAt) var approvals: TableResults<ApprovalRequest>
    @Query(sort: \AskQuestion.requestedAt) var askQuestions: TableResults<AskQuestion>

    // MARK: - AskUserQuestion focus state
    //
    // Lives on WorkspaceView (rather than per-card) so the focus row
    // and the multi-select pending ballot survive the lattice-change
    // re-renders that recreate AskQuestionCardView on every vote.
    // Keyed off `pendingAskQuestion?.globalId`; resets to (0, []) when
    // a new question becomes active.

    /// Currently-focused row index inside the active AskQuestion's
    /// option list (0..<options.count for option rows, == options.count
    /// for "Other…").
    @State private var askFocusedRow: Int = 0

    /// Multi-select local pending ballot — toggled by Enter, committed
    /// to a `AskVote` row by Tab. Empty for single-select questions.
    @State private var askPendingBallot: Set<String> = []

    /// Tracks the question whose state above corresponds to. When a
    /// new question becomes active (k+1 in a sequential group, or a
    /// fresh AskUserQuestion arrives), we clear the focus state.
    @State private var askActiveQuestionId: UUID? = nil

    /// "Other…" overlay visibility. Mounted when the active question
    /// has its Other row focused and the user hits Enter.
    @State private var askOtherVisible: Bool = false

    /// Per-card discussion-thread composer state. Reset whenever
    /// `pendingAskQuestion` changes (a new ballot starts with an empty
    /// draft and ballot-focused). When `askDiscussionFocused == true`
    /// the inline TextField in the card captures keys instead of the
    /// option list / main composer.
    @State private var askDiscussionDraft: String = ""
    @State private var askDiscussionFocused: Bool = false

    /// Oldest `.pending` AskQuestion that should be the active focus
    /// target. Mirrors `pendingApproval`: drives both visibility of
    /// the focus marker and the input-handler routing in WorkspaceView.
    private var pendingAskQuestion: AskQuestion? {
        // Find the lowest groupIndex pending row across all groups —
        // sequential rule prevents two cards being interactive at
        // once. If multiple groups are stacked (unlikely under -p
        // serialisation), the earliest by requestedAt wins.
        //
        // Single-pass over the @Query result rather than
        // filter().sorted().first — this getter is read on every
        // render frame, sometimes multiple times (askCardActive,
        // inputFocusBinding, centerPane). filter+sort allocated two
        // intermediate arrays per call and dominated render time
        // post-question.
        var best: AskQuestion?
        for q in askQuestions where q.status == .pending {
            guard let cur = best else { best = q; continue }
            if q.requestedAt < cur.requestedAt
                || (q.requestedAt == cur.requestedAt && q.groupIndex < cur.groupIndex) {
                best = q
            }
        }
        return best
    }

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
        // Host statusline: rendered when the active room's host has
        // configured a `statusLine.command` and the driver has produced
        // non-empty output (peers see this via Lattice sync). One line
        // per `\n` in the captured stdout.
        let statusLineText = model.activeRoom?.session?.hostStatusLine ?? ""
        let statusLineRows = statusLineText.isEmpty
            ? 0
            : statusLineText.split(separator: "\n", omittingEmptySubsequences: false).count
        let chromeRows = 1 /* topbar */
            + 1 /* hline */
            + 1 /* status */
            + 1 /* input */
            + popupRows
            + statusLineRows
            + 1 /* hotkey strip */
        let hstackHeight = max(5, Term.rows - chromeRows)

        return VStack(spacing: 0) {
            TopBar(model: model)
            HStack(spacing: 0) {
                SessionsSidebar(
                    model: model,
                    width: leftWidth,
                    paneFocused: focusedPane == .sessions,
                    selectedRow: sessionsSelection)
                    .frame(width: leftWidth)
                VLineView()
                centerPane.frame(width: centerWidth)
                VLineView()
                if let room = model.activeRoom {
                    UsersSidebar(
                        room: room,
                        width: rightWidth,
                        paneFocused: focusedPane == .users,
                        selectedNick: usersSelection)
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
            // Host statusline. The host's `StatusLineDriver` writes raw
            // (possibly ANSI-coloured) stdout to `Session.hostStatusLine`
            // and Lattice syncs it to peers; everyone renders the same
            // string here. Multi-line preserved by splitting on `\n`.
            if !statusLineText.isEmpty {
                ForEach(Array(statusLineText.split(separator: "\n", omittingEmptySubsequences: false).map(String.init).enumerated())) { (pair: (offset: Int, element: String)) in
                    Text(ansi: pair.element)
                }
            }
            HotkeyStrip()
        }
        .onKeyPress(27 /* ESC */) {
            // Form overlays own their own ESC (they're rendered in an
            // overlay layer that intercepts before this fires). Here
            // ESC is the way out of a focused sidebar — return focus
            // to input and clear the per-pane selection so the next
            // Tab into a sidebar starts fresh at the first row.
            if focusedPane != .input {
                focusedPane = .input
                sessionsSelection = nil
                usersSelection = nil
                return
            }
            // Otherwise: interrupt the active Claude turn. Anyone in
            // the room can request the interrupt — flipping the
            // Lattice flag on a peer propagates to the host via sync,
            // and only the host's `cancelObserver` actually stops the
            // subprocess. Local ESC on the host short-circuits via
            // the same observer.
            guard let room = model.activeRoom else { return }
            let streaming = room.lattice.objects(Turn.self)
                .where { $0.status == TurnStatus.streaming && $0.cancelRequested == false }
                .first
            guard let streaming else { return }
            streaming.cancelRequested = true
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
        // Space — when a multi-select ballot is the focus target,
        // commit the local pending ballot. (Was Tab pre-discussion;
        // moved to Space so Tab can switch focus between vote and
        // discussion composer.) When the discussion composer owns
        // focus, the TextField has already eaten the keystroke and
        // we never reach here.
        .onKeyPress(Int32(UInt8(ascii: " "))) {
            guard askCardActive, !askDiscussionFocused,
                  let q = pendingAskQuestion, q.multiSelect else { return }
            askCommitBallot()
        }
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
        .overlay(isPresented: firstRunNickVisible, dimsBackground: true) {
            FirstRunNickOverlay(prefs: model.prefs)
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
        .overlay(isPresented: $addGroupVisible, dimsBackground: true) {
            AddGroupOverlay(
                model: model,
                isPresented: $addGroupVisible)
        }
        .overlay(isPresented: $paletteSelectorVisible, dimsBackground: true) {
            PaletteSelectorOverlay(
                prefs: model.prefs,
                isPresented: $paletteSelectorVisible)
        }
        .overlay(isPresented: $askOtherVisible, dimsBackground: true) {
            AskOtherInputOverlay(
                isPresented: $askOtherVisible,
                onSubmit: askSubmitOther)
        }
        // Reset focus state when the active question changes — a new
        // question starts at row 0 with an empty pending ballot.
        // `task(id:)` re-fires whenever pendingAskQuestion's globalId
        // changes (or first-becomes-non-nil).
        .task(id: pendingAskQuestion?.globalId) {
            askFocusedRow = 0
            askPendingBallot = []
            askActiveQuestionId = pendingAskQuestion?.globalId
            askDiscussionDraft = ""
            askDiscussionFocused = false
        }
        // Drain `RoomsModel.pendingNotice` (one-shot user-facing string
        // posted by the model — e.g. a kick) into the active room's
        // chat as a system message. With no active room we leave the
        // notice set so `WelcomePane` can render it as a banner; it'll
        // get drained the next time the user activates a room.
        .task(id: model.pendingNotice) {
            if let notice = model.pendingNotice, let room = model.activeRoom {
                insertSystem(room: room, notice)
                model.pendingNotice = nil
            }
        }
        // When the user does activate a room, drain any sticky notice
        // out of the lobby banner into that room's chat.
        .task(id: model.activeRoomId) {
            if let notice = model.pendingNotice, let room = model.activeRoom {
                insertSystem(room: room, notice)
                model.pendingNotice = nil
            }
        }
        // Auto-seed sidebar selection when focus enters a sidebar.
        // Picks the first visible row so the user doesn't have to
        // press ↓ before Enter does anything.
        .task(id: focusedPane) {
            switch focusedPane {
            case .sessions:
                if sessionsSelection == nil {
                    sessionsSelection = SessionsSidebar.flatRows(model: model).first
                }
            case .users:
                if usersSelection == nil,
                   let lattice = model.activeRoom?.lattice {
                    let realMembers = Array(lattice.objects(Member.self)
                        .sortedBy(SortDescriptor(\.joinedAt, order: .forward)))
                    usersSelection = realMembers.first?.globalId
                }
            case .input:
                break
            }
        }
    }

    // MARK: - Center pane

    @ViewBuilder private var centerPane: some View {
        if let room = model.activeRoom {
            RoomPane(
                room: room,
                draft: $draft,
                onSubmit: send,
                activeAskQuestionId: pendingAskQuestion?.globalId,
                askFocusedRow: askFocusedRow,
                askPendingBallot: askPendingBallot,
                askDiscussionDraft: $askDiscussionDraft,
                askDiscussionFocused: $askDiscussionFocused,
                onAskCommentSubmit: submitAskComment,
                extraChromeRows: extraChromeRows)
        } else {
            WelcomePane(
                pendingNewGroupInvite: pendingNewGroupInvite,
                pendingNotice: model.pendingNotice)
        }
    }

    /// Rows added on top of `RoomPane`'s baseline chrome budget. Slash
    /// popup + host statusline are conditional and grow the chrome
    /// dynamically; without telling `RoomPane`, its scroll budget
    /// overshoots and trailing tool rows (e.g. `TodoWrite` checklists)
    /// get pushed off the visible viewport.
    private var extraChromeRows: Int {
        let popup = slashPopupVisible ? (slashCompletions.count + 1) : 0
        let statusLineText = model.activeRoom?.session?.hostStatusLine ?? ""
        let statusLine = statusLineText.isEmpty
            ? 0
            : statusLineText.split(separator: "\n", omittingEmptySubsequences: false).count
        return popup + statusLine
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
        // Tunnel state: only meaningful for non-private rooms. `pending`
        // = host picked public/group but cloudflared hasn't surfaced a
        // URL yet; `ready` = URL assigned and synced to peers via
        // Session.publicURL.
        if let session = room.session, session.visibility != .private {
            if session.publicURL != nil {
                line = line + Text(" [public:ready]").foregroundColor(.green)
            } else {
                line = line + Text(" [public:pending]").foregroundColor(.yellow)
            }
        }
        if mode != .default {
            line = line + Text(" \(Self.modePrefix(mode))\(mode.label)")
                .foregroundColor(Self.modeColor(mode))
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
            // Sidebar focus owns arrows when it has focus — without
            // this branch, ↑ would also walk the slash popup or
            // AskQuestion card, neither of which is what the user
            // wants while sitting in a sidebar.
            switch focusedPane {
            case .sessions: moveSessionsSelection(-1); return
            case .users:    moveUsersSelection(-1); return
            case .input:    break
            }
            if slashPopupVisible { moveSlashSelection(-1); return }
            if askCardActive { askMove(-1) }
        }
        .onKeyPress(Int32(KEY_DOWN)) {
            switch focusedPane {
            case .sessions: moveSessionsSelection(+1); return
            case .users:    moveUsersSelection(+1); return
            case .input:    break
            }
            if slashPopupVisible { moveSlashSelection(+1); return }
            if askCardActive { askMove(+1) }
        }
        // Enter — when a sidebar pane has focus, activate its
        // selected row (joins / switches / reopens for sessions; the
        // users pane has no row action and falls through to no-op).
        // When the AskQuestion card is the focus target and the
        // TextField is defocused, vote / toggle. Otherwise
        // TextField's onSubmit handles it.
        .onKeyPress(Int32(UInt8(ascii: "\n"))) {
            Log.line(
                "workspace",
                "Enter pressed focusedPane=\(focusedPane) askCardActive=\(askCardActive) draft.empty=\(draft.isEmpty) pendingAsk=\(pendingAskQuestion != nil)")
            switch focusedPane {
            case .sessions:
                activateSessionsSelection()
                return
            case .users:
                // No row-level action yet for users — could insert
                // `@nick ` into draft as a future enhancement. For
                // now, swallowing the key would block the AskQuestion
                // path and bubbling it would let the (defocused)
                // TextField submit; explicit no-op + return keeps
                // both off.
                return
            case .input:
                break
            }
            guard askCardActive else {
                Log.line("workspace", "Enter ignored — askCardActive=false")
                return
            }
            // Discussion composer wins when focused. The card's
            // TextField captures keystrokes for typing but Enter
            // doesn't always reach its onSubmit (Binding chain
            // through MessageListView → RoomPane → WorkspaceView
            // can lag a frame), so we route at the root unambiguously.
            if askDiscussionFocused {
                submitAskComment()
                return
            }
            askActivateFocusedRow()
        }
    }

    /// True when an AskQuestion card should receive arrow/Enter/Tab
    /// keypresses — same rule as the focus binding's "card route"
    /// branch (pending question + empty draft + no overlay open).
    /// Requires `focusedPane == .input` so a user who Tab'd to a
    /// sidebar can keep using arrows/Enter/Tab there even with an
    /// AskQuestion pending — the ballot just stays uncommitted until
    /// they Tab back to input.
    private var askCardActive: Bool {
        guard focusedPane == .input else { return false }
        guard !hostFormVisible, !joinFormVisible, !addGroupVisible, !askOtherVisible else {
            return false
        }
        // First-run nick picker owns all input until a nick is chosen.
        guard !model.prefs.nick.isEmpty else { return false }
        guard pendingAskQuestion != nil, draft.isEmpty else { return false }
        return true
    }

    /// First-run nick picker is mandatory: if `prefs.nick` is empty
    /// (fresh launch on a new data dir), a `FirstRunNickOverlay` is
    /// presented to collect a nick before the user can do anything
    /// else. The binding is computed (not @State) so the overlay
    /// dismisses automatically when the user submits — setting
    /// `prefs.nick` to a non-empty string flips `isEmpty` to false
    /// and the @Observable propagation re-evaluates this getter.
    private var firstRunNickVisible: Binding<Bool> {
        Binding(
            get: { self.model.prefs.nick.isEmpty },
            set: { _ in })
    }

    private var inputFocusBinding: Binding<Bool> {
        // Defocus the TextField so Y/A/D/ESC + arrow keys bubble past
        // it when:
        //   (a) a form overlay is visible — it owns key handling
        //   (b) an approval is pending AND the draft is empty —
        //       the user isn't mid-typing, so their keystrokes are
        //       votes. Once they start typing (draft non-empty),
        //       TextField reclaims keys so they can finish the word.
        //   (c) an AskQuestion is pending AND the draft is empty —
        //       same rationale, but for arrow/Enter/Tab navigation
        //       through the option list.
        //   (d) the AskOtherInputOverlay is visible — it owns its
        //       own TextField focus.
        //   (e) a sidebar pane is the active Tab focus — arrows
        //       drive sidebar selection, Enter activates a row.
        Binding(
            get: {
                if focusedPane != .input { return false }
                if hostFormVisible || joinFormVisible || addGroupVisible { return false }
                // First-run nick picker owns the TextField until nick is set.
                if model.prefs.nick.isEmpty { return false }
                if askOtherVisible { return false }
                if pendingApproval != nil && draft.isEmpty { return false }
                if pendingAskQuestion != nil && draft.isEmpty { return false }
                return true
            },
            set: { _ in })
    }

    private static func modeColor(_ mode: PermissionMode) -> Color {
        switch mode {
        case .default:           return .dim
        case .acceptEdits:       return .purple
        case .plan:              return .teal
        case .auto:              return .gold
        case .bypassPermissions: return .red
        }
    }

    /// Visual glyph prefix that distinguishes elevated permission modes.
    /// `⏵⏵` (double right-pointing) reads as "fast-forward / skip the
    /// approval gate" — used for both acceptEdits and auto. `⏸` (pause)
    /// reads as "no execution" — used for plan mode where Claude only
    /// drafts. Default + bypass return empty (default needs no marker;
    /// bypass already screams via the red colour).
    private static func modePrefix(_ mode: PermissionMode) -> String {
        switch mode {
        case .acceptEdits, .auto: return "⏵⏵ "
        case .plan:               return "⏸ "
        case .default, .bypassPermissions: return ""
        }
    }

    // MARK: - Tab completion

    /// Dispatch Tab. Order of precedence (top wins):
    ///
    ///   1. Slash popup visible → pick the highlighted command.
    ///   2. AskQuestion card is the active focus + multi-select →
    ///      commit the local pending ballot.
    ///   3. Last word of `draft` is non-empty → nick-complete.
    ///   4. Otherwise (empty draft, no AskQuestion ballot, no slash
    ///      popup) → cycle the focused pane.
    ///
    /// Cases 1–3 mirror the prior behaviour; case 4 is the "context-
    /// aware" pane navigator. Consolidated to a single Tab handler
    /// because NCursesUI's child-first dispatch ALWAYS consumes a
    /// child `.onKeyPress(9)` (the wrapper hard-returns true), so a
    /// second handler at root level would be unreachable.
    private func handleTab() {
        if slashPopupVisible {
            completeSlash()
            return
        }
        // When a ballot card owns focus, Tab toggles between the option
        // list (vote) and the inline discussion composer (chat).
        // Multi-select commit moved to Space (see Space handler).
        if askCardActive {
            askDiscussionFocused.toggle()
            return
        }
        let scalars = Array(draft)
        var wordStart = scalars.count
        while wordStart > 0, !scalars[wordStart - 1].isWhitespace {
            wordStart -= 1
        }
        let lastWord = String(scalars[wordStart..<scalars.count])
        if !lastWord.isEmpty {
            completeNick()
            return
        }
        cyclePane()
    }

    /// Move focus to the next pane in the cycle. Skips `.users` when
    /// no room is active (the users sidebar renders as `EmptyView` in
    /// that case, so focusing it would be a dead stop).
    private func cyclePane() {
        let next: FocusedPane
        switch focusedPane {
        case .input:
            next = .sessions
        case .sessions:
            next = (model.activeRoom != nil) ? .users : .input
        case .users:
            next = .input
        }
        focusedPane = next
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
        case .reopen(let filter):
            reopenRecent(nameFilter: filter, room: model.activeRoom)
            return
        case .addGroup:
            addGroupVisible = true
            return
        case .newGroup(let name):
            handleNewGroup(name: name, room: model.activeRoom)
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
            case .empty, .unknown, .leave, .deleteRoom, .clear, .palette, .host, .join, .reopen, .addGroup, .newGroup: break
            default:
                me.isAway = false
                me.awayReason = nil
                insertSystem(room: room, "\(me.nick) is back")
            }
        }

        switch intent {
        case .empty, .host, .join, .reopen, .addGroup, .newGroup, .palette, .setNick:
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
        case .deleteRoom:
            let id = room.id
            Task { await model.deleteRoom(id) }
        case .kick(let nick):
            // Host-only. Self-kick aliases to /leave so the host can
            // type either spelling. For everyone else, find the
            // Member by nick and delete the row — Lattice sync fans
            // the delete out, and the kicked peer's
            // `selfMemberObserver` self-ejects.
            guard room.isHost else {
                insertSystem(room: room, "only the host can /kick")
                return
            }
            if nick == room.selfMember?.nick {
                let id = room.id
                Task { await model.leave(id) }
                return
            }
            guard let target = room.lattice.objects(Member.self)
                .first(where: { $0.nick == nick }) else {
                insertSystem(room: room, "no such member: \(nick)")
                return
            }
            room.lattice.delete(target)
            insertSystem(room: room, "\(nick) was kicked")
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
        case .reopen(let filter):
            reopenRecent(nameFilter: filter, room: room)
        case .addGroup:
            addGroupVisible = true
        case .newGroup(let name):
            handleNewGroup(name: name, room: room)
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
        let candidates = discoverableRooms()
        let filter = nameFilter?.lowercased()
        let target: DiscoveredRoom?
        if let filter, !filter.isEmpty {
            target = candidates.first { $0.name.lowercased().hasPrefix(filter) }
        } else {
            target = candidates.first
        }
        guard let target else {
            feedback(
                nameFilter.map { "no room matches '\($0)'" } ?? "no discovered rooms to join",
                room: currentRoom)
            return
        }
        activateDiscovered(target, currentRoom: currentRoom)
    }

    /// Single source of truth for "rooms I could join right now",
    /// shared by `/join`, the LAN-discovered sidebar row, and the
    /// directory-listed (public / group) sidebar rows. Bonjour finds
    /// + every directory bucket get normalised into `DiscoveredRoom`;
    /// joined rooms drop out; same-room duplicates keep the directory
    /// entry (the host's chosen visibility — public / group — is the
    /// source of truth, LAN discovery is a transport detail).
    private func discoverableRooms() -> [DiscoveredRoom] {
        let joined = Set(model.joinedRooms.map(\.roomCode))
        let directory = directoryAsDiscoveredRooms()
        let directoryCodes = Set(directory.map(\.roomCode))
        // LAN-only rooms: a Bonjour find that isn't also published in
        // any directory bucket. Same Bonjour entry that's ALSO in
        // public/group is suppressed here so the room shows in the
        // section the host actually advertised it under.
        let lanOnly = model.browser.rooms.filter { !directoryCodes.contains($0.roomCode) }
        return (directory + lanOnly).filter { !joined.contains($0.roomCode) }
    }

    /// Open a `DiscoveredRoom` — the only side-effect-bearing path
    /// shared by `/join`, the LAN-discovered sidebar row, and the
    /// directory-listed (public / group) sidebar rows. Honours
    /// `requiresJoinCode` by popping the join overlay pre-populated;
    /// open rooms join in place. Errors land on `currentRoom` if any.
    private func activateDiscovered(
        _ target: DiscoveredRoom,
        currentRoom: RoomInstance?
    ) {
        pendingJoin = target
        if target.requiresJoinCode {
            joinFormVisible = true
        } else {
            do { _ = try model.join(target, joinCode: nil) }
            catch { feedback("join failed: \(error)", room: currentRoom) }
        }
    }

    /// Translate `model.directoryRoomsByGroup` snapshots into
    /// `DiscoveredRoom` view models so they merge with Bonjour finds
    /// in `/join`. Same room appearing in multiple group buckets is
    /// deduped by `roomCode`.
    private func directoryAsDiscoveredRooms() -> [DiscoveredRoom] {
        var seen: Set<String> = []
        var out: [DiscoveredRoom] = []
        for room in model.directoryRoomsByGroup.values.flatMap({ $0 }) {
            guard !seen.contains(room.roomId),
                  let url = URL(string: room.wssURL) else { continue }
            seen.insert(room.roomId)
            out.append(DiscoveredRoom(
                id: room.roomId,
                name: room.name,
                roomCode: room.roomId,
                hostNick: room.hostHandle,
                cwd: "",
                hostname: url.host ?? "",
                port: url.port ?? 443,
                requiresJoinCode: room.requireJoinCode,
                wssURLOverride: url))
        }
        return out
    }

    /// Resolve `/reopen [name]` against `model.recentLattices` and
    /// hand off to `activateRecent(code:)`. Errors / "no match" land
    /// in `currentRoom` (or the log if the user ran this from the
    /// welcome state).
    private func reopenRecent(nameFilter: String?, room currentRoom: RoomInstance?) {
        guard !model.recentLattices.isEmpty else {
            feedback("no recent rooms on disk", room: currentRoom)
            return
        }
        let filterLower = nameFilter?.lowercased()
        let target = model.recentLattices.first { entry in
            guard let s = entry.lattice.objects(Session.self)
                .first(where: { $0.code == entry.code }) else { return false }
            guard let f = filterLower, !f.isEmpty else { return true }
            return s.name.lowercased().hasPrefix(f) || s.code.lowercased().hasPrefix(f)
        }
        guard let target else {
            feedback("no recent room matches '\(nameFilter ?? "")'", room: currentRoom)
            return
        }
        activateRecent(code: target.code, currentRoom: currentRoom)
    }

    /// Reopen a recent room by code — host vs peer is decided by
    /// looking up a `Member` row whose `userId == prefs.userId &&
    /// isHost`. `userId` is stable across `/nick` and across crashes;
    /// matching against `nick` was brittle (collisions, renames).
    /// Peer reopen needs `Session.publicURL`; without it the user has
    /// to rejoin via Bonjour / directory.
    ///
    /// Belt-and-suspenders: we deliberately don't dereference
    /// `Session.host` here. Lattice files on disk that pre-date
    /// LatticeCore@113fc8d (cascade-clean link & union tables on row
    /// delete) can carry an orphaned `_Session_Member_host` row
    /// pointing at a Member that has since been deleted — the cascade
    /// loop in `lattice_db::remove` was incorrectly skipping every
    /// link table, so the cleanup never ran or synced. Following such
    /// an orphan via `s.host?` faults inside
    /// `dynamic_object::get_object`: `find_by_global_id<Member>`
    /// returns empty, `cached_object_` stays null, and `m->table_name()`
    /// dereferences nullptr → SIGSEGV in
    /// `swift_lattice::get_properties_for_table`. New writes are
    /// covered by the LatticeCore fix; this guard keeps existing user
    /// lattices from crashing on first reopen until they re-sync.
    ///
    /// Shared by `/reopen <name>` and the recent-row Enter activation.
    private func activateRecent(code: String, currentRoom: RoomInstance?) {
        guard let entry = model.recentLattices.first(where: { $0.code == code }),
              let s = entry.lattice.objects(Session.self)
                .first(where: { $0.code == code })
        else {
            feedback("recent room '\(code)' has no session row", room: currentRoom)
            return
        }
        let myUserId = model.prefs.userId
        let allMembers = Array(entry.lattice.objects(Member.self))
        let isHostRoom = allMembers.contains { $0.userId == myUserId && $0.isHost }
        Log.line("recent-activate",
                 "code=\(code) myUserId=\(myUserId) members=[" +
                 allMembers.map { "(nick=\($0.nick) userId=\($0.userId) isHost=\($0.isHost))" }
                    .joined(separator: ",") +
                 "] isHostRoom=\(isHostRoom) hasPublicURL=\(s.publicURL != nil)")
        // Diagnostic: also surface in-flight orphan rows that survived a
        // hard exit. Permanent thinking strip on rejoin = a `.streaming`
        // Turn whose driver is gone.
        let streamingTurns = entry.lattice.objects(Turn.self)
            .where { $0.status == .streaming }
        let pendingAsks = entry.lattice.objects(AskQuestion.self)
            .where { $0.status == .pending }
        let runningTools = entry.lattice.objects(ToolEvent.self)
            .where { $0.status == .running }
        let pendingApprovals = entry.lattice.objects(ApprovalRequest.self)
            .where { $0.status == .pending }
        Log.line("recent-activate",
                 "orphans streamingTurns=\(streamingTurns.count) pendingAsks=\(pendingAsks.count) " +
                 "runningTools=\(runningTools.count) pendingApprovals=\(pendingApprovals.count)")
        if isHostRoom {
            Task {
                do { _ = try await model.reopenAsHost(code: code) }
                catch { feedback("reopen as host failed: \(error)", room: currentRoom) }
            }
        } else {
            guard let urlStr = s.publicURL, let url = URL(string: urlStr) else {
                feedback("can't reopen as peer: no cached endpoint (host may be offline; rejoin via lobby)",
                         room: currentRoom)
                return
            }
            do {
                _ = try model.reopenAsPeer(
                    code: code,
                    wssEndpoint: url,
                    joinCode: s.joinCode)
            } catch {
                feedback("reopen as peer failed: \(error)", room: currentRoom)
            }
        }
    }

    // MARK: - Sidebar pane navigation

    /// Step the sessions-sidebar selection by ±1 across the flat row
    /// list (joined → recent → LAN → public → groups, in render
    /// order). Clamps at the boundaries — wrapping mid-list is jarring
    /// because the sections look different and the user can lose
    /// orientation.
    private func moveSessionsSelection(_ delta: Int) {
        let rows = SessionsSidebar.flatRows(model: model)
        guard !rows.isEmpty else {
            sessionsSelection = nil
            return
        }
        let currentIdx = sessionsSelection.flatMap { rows.firstIndex(of: $0) } ?? -1
        let next = max(0, min(rows.count - 1, currentIdx + delta))
        sessionsSelection = rows[next]
    }

    /// Step the users-sidebar selection by ±1 across real members
    /// (synthetic `@claude` is skipped — it has no `Member` row and
    /// no row-level action).
    private func moveUsersSelection(_ delta: Int) {
        guard let lattice = model.activeRoom?.lattice else { return }
        let realMembers = Array(lattice.objects(Member.self)
            .sortedBy(SortDescriptor(\.joinedAt, order: .forward)))
        guard !realMembers.isEmpty else { return }
        let currentIdx = usersSelection.flatMap { id in
            realMembers.firstIndex { $0.globalId == id }
        } ?? -1
        let next = max(0, min(realMembers.count - 1, currentIdx + delta))
        usersSelection = realMembers[next].globalId
    }

    /// Enter on the sessions sidebar — dispatch by the row kind.
    /// Joined rows switch the active room; everything else funnels
    /// through `activateDiscovered` / `activateRecent` so the
    /// behaviour matches the slash-command path. Returns focus to
    /// `.input` after a successful dispatch so subsequent keystrokes
    /// type into the message draft.
    private func activateSessionsSelection() {
        guard let sel = sessionsSelection else { return }
        let here = model.activeRoom
        switch sel {
        case .joined(let id):
            model.activate(id)
        case .recent(let code):
            activateRecent(code: code, currentRoom: here)
        case .lan(let code), .publicRoom(let code), .groupRoom(_, let code):
            // All three "discovered room" cases resolve through the
            // same `discoverableRooms()` candidate set as `/join` so
            // the lookup, the visibility-precedence dedup, and the
            // join-code handling stay consistent across surfaces.
            guard let room = discoverableRooms().first(where: { $0.roomCode == code })
            else { return }
            activateDiscovered(room, currentRoom: here)
        }
        focusedPane = .input
        sessionsSelection = nil
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

    /// Materialise a brand-new `LocalGroup` from `/newgroup <name>` and
    /// surface its invite code so the user can copy/share it. When a
    /// room is active the invite + name lands as a `.system` message
    /// in that room's chat (peers will see it too — fine for a group
    /// invite, the secret was generated locally and is meant to be
    /// shared anyway). Otherwise we stash it on
    /// `pendingNewGroupInvite`; the lobby welcome pane renders the
    /// pending invite as a yellow banner.
    private func handleNewGroup(name: String, room: RoomInstance?) {
        let result: (group: LocalGroup, invite: String)
        do {
            result = try model.createGroup(name: name)
        } catch {
            let msg = error.localizedDescription
            if let room { insertSystem(room: room, "error: \(msg)") }
            return
        }
        let banner = "*** group \"\(result.group.name)\" created — share this invite:\n\(result.invite)"
        if let room {
            insertSystem(room: room, banner)
        } else {
            pendingNewGroupInvite = result.invite
        }
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

    // MARK: - AskQuestion focus / voting

    /// Move the focus cursor up (-1) or down (+1) through the active
    /// question's option list. Wraps at both ends so the user doesn't
    /// fall off; clamping was tried earlier and felt sticky.
    private func askMove(_ delta: Int) {
        guard let q = pendingAskQuestion else { return }
        let total = q.options.count + 1 // +1 for "Other…"
        guard total > 0 else { return }
        var next = (askFocusedRow + delta) % total
        if next < 0 { next += total }
        askFocusedRow = next
    }

    /// Enter on the focused row. For option rows: vote (single-select)
    /// or toggle pending ballot (multi-select). For the "Other…" row:
    /// open the free-text overlay.
    private func askActivateFocusedRow() {
        guard let q = pendingAskQuestion else {
            Log.line("workspace", "askActivate: no pending question — bailing")
            return
        }
        let otherIdx = q.options.count
        Log.line(
            "workspace",
            "askActivate row=\(askFocusedRow) otherIdx=\(otherIdx) multiSelect=\(q.multiSelect) ballotBefore=\(askPendingBallot)")
        if askFocusedRow == otherIdx {
            askOtherVisible = true
            return
        }
        guard askFocusedRow >= 0, askFocusedRow < q.options.count else { return }
        let label = q.options[askFocusedRow].label
        if q.multiSelect {
            // Toggle in local pending ballot — committed on Tab.
            if askPendingBallot.contains(label) {
                askPendingBallot.remove(label)
            } else {
                askPendingBallot.insert(label)
            }
            Log.line("workspace", "askActivate multiSelect toggled label=\(label) ballotAfter=\(askPendingBallot)")
        } else {
            // Single-select: write directly. Re-pressing on the
            // already-voted-for label retracts the vote (delete the
            // existing AskVote row).
            Log.line("workspace", "askActivate singleSelect cast label=\(label)")
            castSingleSelect(label: label, on: q)
        }
    }

    /// Multi-select Tab — write the local pending ballot to lattice.
    /// Replaces any prior ballot from this voter on this question.
    private func askCommitBallot() {
        guard let q = pendingAskQuestion, q.multiSelect else { return }
        writeBallot(labels: Array(askPendingBallot), on: q)
    }

    /// Single-select vote: `[label]` ballot, or retract if the user
    /// re-presses on a row they're already voted for.
    private func castSingleSelect(label: String, on q: AskQuestion) {
        guard let room = model.activeRoom, let voter = room.selfMember else { return }
        // Find existing ballot from this voter.
        let existing = q.votes.first { $0.voter?.globalId == voter.globalId }
        if let existing, existing.chosenLabels == [label] {
            // Re-press on already-voted row → retract.
            room.lattice.delete(existing)
            return
        }
        writeBallot(labels: [label], on: q)
    }

    /// Upsert an `AskVote` row for the active member on `q` with
    /// `chosenLabels`. Wraps the delete + insert in a transaction so
    /// peers see the new ballot atomically.
    private func writeBallot(labels: [String], on q: AskQuestion) {
        guard let room = model.activeRoom, let voter = room.selfMember else { return }
        let lattice = room.lattice
        lattice.beginTransaction()
        for existing in q.votes where existing.voter?.globalId == voter.globalId {
            lattice.delete(existing)
        }
        let vote = AskVote()
        vote.voter = voter
        vote.question = q
        vote.chosenLabels = labels
        vote.castAt = Date()
        lattice.add(vote)
        lattice.commitTransaction()
        Log.line("workspace", "ballot cast labels=\(labels) on \"\(q.header)\"")
    }

    /// "Other…" submit — append a new option (de-duped) and auto-vote.
    /// The append + ballot land in one transaction so peers can't see
    /// the option without the submitter's vote already on it.
    private func askSubmitOther(_ text: String) {
        guard let q = pendingAskQuestion,
              let room = model.activeRoom,
              let voter = room.selfMember else { return }
        let lattice = room.lattice
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        // De-dupe case-insensitively against existing labels.
        let existingLabels = q.options.map { $0.label }
        let matched = existingLabels.first { $0.caseInsensitiveCompare(trimmed) == .orderedSame }
        let label = matched ?? trimmed

        lattice.beginTransaction()
        if matched == nil {
            // Append a new option carrying the submitter's nick.
            var opts = q.options
            opts.append(AskOption(
                label: trimmed,
                optionDescription: "",
                submittedByNick: voter.nick))
            q.options = opts
        }
        // Auto-vote: drop any prior ballot from this voter, write a
        // fresh one for the (possibly newly-added) label.
        for existing in q.votes where existing.voter?.globalId == voter.globalId {
            lattice.delete(existing)
        }
        // Multi-select: merge with the local pending ballot too so
        // the new label sticks across Tab commits.
        let labels: [String]
        if q.multiSelect {
            askPendingBallot.insert(label)
            labels = Array(askPendingBallot)
        } else {
            labels = [label]
        }
        let vote = AskVote()
        vote.voter = voter
        vote.question = q
        vote.chosenLabels = labels
        vote.castAt = Date()
        lattice.add(vote)
        lattice.commitTransaction()
        Log.line("workspace", "submitted other answer=\"\(trimmed)\" on \"\(q.header)\"")
    }

    /// Append a comment to the focused `AskQuestion`'s discussion
    /// thread. Whitespace-only drafts no-op (Enter on empty draft is
    /// a "stay put" rather than a write). Comments live in
    /// `question.comments: List<AskComment>`; the parent-list
    /// `.update` notification will re-render the card on every peer
    /// (see Lattice `crossProcessListAppend` test).
    private func submitAskComment() {
        let trimmed = askDiscussionDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let q = pendingAskQuestion,
              let room = model.activeRoom,
              let me = room.selfMember else { return }
        let c = AskComment()
        c.author = me
        c.text = trimmed
        c.createdAt = Date()
        q.comments.append(c)
        askDiscussionDraft = ""
        Log.line("workspace",
                 "askComment posted nick=\(me.nick) len=\(trimmed.count) on q=\"\(q.header.prefix(40))\"")
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
    /// Set when the user just ran `/newgroup <name>` while no room is
    /// active — the resulting invite code is shown as a yellow banner
    /// so they can copy/share it. Cleared by the workspace when the
    /// user joins/hosts a room (or types `/clear`).
    var pendingNewGroupInvite: String? = nil
    /// One-shot notice from `RoomsModel` (e.g. "you were kicked from
    /// <room>") rendered as a yellow banner. Persists in lobby until
    /// the user joins/hosts another room — clearing happens via the
    /// `.task(id:)` drain in `WorkspaceView` once an active room is
    /// available to host the system message.
    var pendingNotice: String? = nil

    var body: some View {
        VStack {
            SpacerView(1)
            Text("welcome to claude-code.irc").foregroundColor(.yellow).bold()
            SpacerView(1)
            Text("pick a discovered session on the left, or press `/host` to start one.")
                .foregroundColor(.dim)
            Text("claude only replies when addressed — use `@claude` anywhere in a message.")
                .foregroundColor(.dim)
            if let notice = pendingNotice {
                SpacerView(1)
                Text(notice).foregroundColor(.yellow)
            }
            if let invite = pendingNewGroupInvite {
                SpacerView(1)
                Text("group created — share this invite:").foregroundColor(.dim)
                Text(invite).foregroundColor(.yellow)
            }
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
    /// AskQuestion focus state, threaded down from `WorkspaceView`
    /// so MessageListView's card render path knows which row to mark
    /// with `▸` and which labels to render `[x]` for.
    let activeAskQuestionId: UUID?
    let askFocusedRow: Int
    let askPendingBallot: Set<String>
    /// Discussion thread state, plumbed through to `MessageListView` ⇒
    /// `AskQuestionCardView`. Owned by `WorkspaceView`; reset on
    /// question change.
    @Binding var askDiscussionDraft: String
    @Binding var askDiscussionFocused: Bool
    let onAskCommentSubmit: () -> Void
    /// Rows the parent's chrome takes on top of `RoomPane`'s baseline
    /// of 6. Slash popup + host statusline are the dynamic ones; both
    /// live in `WorkspaceView` and need to be subtracted from the
    /// scroll budget here so the bottom of our content (tool rows,
    /// thinking strip, etc.) doesn't get pushed off-screen.
    let extraChromeRows: Int

    @Query(sort: \Turn.startedAt) var turns: TableResults<Turn>
    /// Counted-only queries that drive the auto-scroll trigger. We
    /// don't render from these directly (MessageListView has its own
    /// queries), but their `count` changing is the cleanest way to
    /// fire `.task(id:)` whenever any chat-stream row inserts.
    @Query(sort: \ChatMessage.createdAt) var messages: TableResults<ChatMessage>
    @Query(sort: \AssistantChunk.createdAt) var chunks: TableResults<AssistantChunk>
    @Query(sort: \ToolEvent.startedAt) var paneToolEvents: TableResults<ToolEvent>
    @Query(sort: \ApprovalRequest.requestedAt) var paneApprovals: TableResults<ApprovalRequest>
    @Query(sort: \AskQuestion.requestedAt) var paneAskQuestions: TableResults<AskQuestion>

    /// ScrollView offset state. Initialised to `Int.max`; the
    /// ScrollView's `afterChildren` clamps to `contentH - viewportH`
    /// on first render, so this naturally sits at the bottom on
    /// open. Each new event re-pins via `.task(id: totalEventCount)`.
    @State private var scrollOffset: Int = .max

    private var streamingTurn: Turn? {
        turns.first { $0.status == .streaming }
    }

    /// ScrollView reserves the pane's full height minus the title
    /// strip (1). The "claude is working" row is now a synthetic
    /// chat event injected by `MessageListView` (see G4) instead of
    /// a separate strip below the scroll, so we no longer subtract
    /// a thinking-strip row here.
    private var scrollHeight: Int {
        // Baseline chrome: topbar + hline + status + input + hotkey + pad = 6.
        // `extraChromeRows` covers conditional rows the parent owns
        // (slash popup, host statusline) so the ScrollView shrinks in
        // sync with the workspace's chrome calc and doesn't push our
        // own trailing content off-screen.
        let paneHeight = Term.rows - 6 - extraChromeRows
        return max(1, paneHeight - 1 /* title strip */)
    }

    /// Sum of inserted rows that should drive auto-scroll-to-bottom.
    /// Includes every row type that lands visibly in the scrollback:
    /// chat messages, streaming chunks, tool events, approvals, and
    /// question cards. Bumping any of these pins the view.
    private var totalEventCount: Int {
        messages.count
            + chunks.count
            + paneToolEvents.count
            + paneApprovals.count
            + paneAskQuestions.count
    }

    var body: some View {
        VStack(spacing: 0) {
            titleStrip
            ScrollView(height: scrollHeight, offset: $scrollOffset, interceptScrollKeys: true) {
                MessageListView(
                    isHost: room.isHost,
                    scrollbackFloor: room.scrollbackFloor,
                    selfMember: room.selfMember,
                    activeAskQuestionId: activeAskQuestionId,
                    askFocusedRow: askFocusedRow,
                    askPendingBallot: askPendingBallot,
                    askDiscussionDraft: $askDiscussionDraft,
                    askDiscussionFocused: $askDiscussionFocused,
                    onAskCommentSubmit: onAskCommentSubmit,
                    streamingTurn: streamingTurn)
            }
            // Auto-pin to bottom whenever a new scrollback row
            // inserts. ScrollView's afterChildren clamps `Int.max`
            // to the real maxOffset, so we don't need to know the
            // viewport / content sizes here. Trade-off: if the user
            // scrolled up to read history, the next streaming chunk
            // yanks them back to the bottom. Smart "preserve user
            // scroll position" UX is a follow-up.
            .task(id: totalEventCount) {
                scrollOffset = .max
            }
        }
    }

    private var titleStrip: some View {
        let name = room.session?.name ?? room.roomCode
        // Read the host nick from a direct Member query rather than
        // following `Session.host`. Same belt-and-suspenders rationale
        // as `activateRecent`: lattice files on disk that pre-date
        // LatticeCore@113fc8d can have an orphaned
        // `_Session_Member_host` row pointing at a deleted Member, and
        // following it SIGSEGVs in `swift_lattice::get_properties_for_table`.
        // The direct query stays inside the `Member` table.
        let host = room.lattice.objects(Member.self)
            .first(where: { $0.isHost })?.nick ?? "?"
        var line = Text("── \(name) ").foregroundColor(.dim)
        line = line + Text("── host: ").foregroundColor(.dim)
        line = line + Text(host).foregroundColor(.yellow)
        line = line + Text(" ──────────").foregroundColor(.dim)
        return line
    }
}

// MARK: - Host form (re-parented from the old LobbyView)

enum HostFormFocus { case name, cwd, auth, visibility }

struct HostFormOverlay: View {
    let model: RoomsModel
    @Binding var isPresented: Bool
    let onCreated: (RoomInstance) -> Void

    @State private var focus: HostFormFocus = .name
    @State private var name: String = ""
    /// Default to "no join code" — the common case is a casual public
    /// room shared with friends/teammates over the directory; requiring
    /// a code is an opt-in extra step, not the default.
    @State private var requireCode: Bool = false
    /// Selected visibility choice. Index 1 = `.public_` in the cycler's
    /// `[private, public, …groups]` order. Public is the default
    /// because it's the case the directory + tunnel were built for;
    /// users who want LAN-only flip to private.
    @State private var visibilityIndex: Int = 1
    @State private var error: String = ""

    /// Available group rows from `prefs.lattice`. The cycler iterates
    /// `[private, public] + groups` so the user can pick a group they
    /// already pasted via `/addgroup`. Read once per body eval — fine
    /// for a modal form that's open briefly.
    private var groups: [LocalGroup] {
        Array(model.prefsLattice.objects(LocalGroup.self)
            .sortedBy(SortDescriptor(\.addedAt, order: .forward)))
    }

    /// Edited cwd for this form. Seeded from `prefs.lastCwd` if the
    /// user has hosted before, otherwise from the shell's pwd at app
    /// launch — that's almost always the directory the user wants to
    /// share. Empty `lastCwd` was the common first-launch case before
    /// this fallback (form opened with a literal placeholder string,
    /// which dropped the user into a typo trap).
    private var cwdBinding: Binding<String> {
        Binding(
            get: {
                let stored = model.prefs.lastCwd
                if !stored.isEmpty { return stored }
                return FileManager.default.currentDirectoryPath
            },
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
                HStack {
                    Text("visibility: \(visibilityLabel)")
                        .foregroundColor(focus == .visibility ? .cyan : .white)
                        .reverse(focus == .visibility)
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
            case .name:       .cwd
            case .cwd:        .auth
            case .auth:       .visibility
            case .visibility: .name
            }
        }
        .onKeyPress(Int32(UInt8(ascii: " "))) {
            switch focus {
            case .auth:       requireCode.toggle()
            case .visibility: cycleVisibility()
            default: break
            }
        }
        .onKeyPress(Int32(UInt8(ascii: "\n"))) {
            if focus == .auth || focus == .visibility { submit() }
        }
        .onKeyPress(27 /* ESC */) {
            isPresented = false
        }
    }

    /// `[private, public, ...groups]`. Cycling wraps. Group entries
    /// resolve to `(visibility: .group, groupHashHex: <hash>)` at
    /// submit time.
    private var visibilityChoices: [VisibilityChoice] {
        [.private_, .public_] + groups.map { .group($0) }
    }

    private var currentChoice: VisibilityChoice {
        let choices = visibilityChoices
        let i = max(0, min(visibilityIndex, choices.count - 1))
        return choices[i]
    }

    private func cycleVisibility() {
        let choices = visibilityChoices
        guard !choices.isEmpty else { return }
        visibilityIndex = (visibilityIndex + 1) % choices.count
    }

    private var visibilityLabel: String {
        switch currentChoice {
        case .private_:        return "private (LAN only)"
        case .public_:         return "public (listed in directory)"
        case .group(let g):    return "group: \(g.name)"
        }
    }

    private func submit() {
        let choice = currentChoice
        let visibility: SessionVisibility
        let groupHashHex: String?
        switch choice {
        case .private_:        visibility = .private; groupHashHex = nil
        case .public_:         visibility = .public;  groupHashHex = nil
        case .group(let g):    visibility = .group;   groupHashHex = g.hashHex
        }
        // Resolve cwd identically to `cwdBinding.getter` — the binding's
        // setter only fires when the user actually types in the field,
        // so a "open form, hit Enter on defaults" path leaves
        // `prefs.lastCwd` empty even though the form rendered the fall-
        // back. Without this, `Session.cwd` ends up "" and downstream
        // (StatusLineDriver's transcript path lookup, claude -p's
        // working directory) silently breaks.
        //
        // Also expand a leading `~` to `$HOME`. The user might type
        // `~/Projects/foo`; `Process` doesn't expand tildes and
        // Claude Code's transcript path encoding is `/`+`.` → `-` on
        // an absolute path, so a literal `~` stays in the encoded
        // segment (`--Projects-foo`) and `TranscriptReader` can't
        // find the jsonl that actually lives at
        // `-Users-…-Projects-foo`.
        let stored = model.prefs.lastCwd
        let raw = stored.isEmpty
            ? FileManager.default.currentDirectoryPath
            : stored
        let resolvedCwd = (raw as NSString).expandingTildeInPath
        Task {
            do {
                let room = try await model.host(
                    name: name.isEmpty ? "unnamed" : name,
                    cwd: resolvedCwd,
                    mode: .default,
                    requireJoinCode: requireCode,
                    visibility: visibility,
                    groupHashHex: groupHashHex)
                onCreated(room)
            } catch {
                // `LocalizedError` (RoomsModel.HostError, etc.) gives a
                // friendly string; arbitrary `Error`s fall back to
                // `localizedDescription`, which is at minimum a real
                // sentence rather than the raw type dump that
                // `"\(error)"` produces.
                self.error = error.localizedDescription
            }
        }
    }
}

/// Internal enum for `HostFormOverlay`'s visibility cycler. Cases
/// are suffixed `_` because `private`/`public` are Swift keywords;
/// using backticks across many sites was uglier.
enum VisibilityChoice {
    case private_
    case public_
    case group(LocalGroup)
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

/// "Add a group" form — paste a `ccirc-group:v1:` invite, persist the
/// resulting `LocalGroup` row in `prefs.lattice`. Idempotent: pasting
/// the same invite twice resolves to the same row (matched by hash).
struct AddGroupOverlay: View {
    let model: RoomsModel
    @Binding var isPresented: Bool

    @State private var invite: String = ""
    @State private var error: String = ""

    var body: some View {
        BoxView("Add group", color: .cyan) {
            VStack {
                Text("Paste a group invite (ccirc-group:v1:…)").foregroundColor(.dim)
                HStack {
                    Text("invite: ").foregroundColor(.dim)
                    TextField("ccirc-group:v1:…",
                              text: $invite,
                              isFocused: .constant(true),
                              onSubmit: submit)
                }
                SpacerView(1)
                Text("↵ add   ⎋ cancel").foregroundColor(.dim)
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
        do {
            _ = try model.addGroup(invitePaste: invite)
            isPresented = false
        } catch {
            self.error = "\(error)"
        }
    }
}

/// First-run nick picker. Mandatory: presented automatically when
/// `prefs.nick.isEmpty` (fresh data dir, no prior session). Stays
/// visible until the user submits a non-empty, whitespace-free nick
/// — there is no cancel affordance, ESC is a no-op, and the parent's
/// input focus / sidebar nav are gated off while it's up.
///
/// Validation mirrors `InputRouter.parse("/nick …")`: trim, reject
/// empty, reject whitespace inside the name. On success the nick
/// goes straight into the `AppPreferences` row, which dismisses the
/// overlay automatically (the parent's `firstRunNickVisible` getter
/// computes from `prefs.nick.isEmpty`).
struct FirstRunNickOverlay: View {
    let prefs: AppPreferences

    @State private var nick: String = ""
    @State private var error: String = ""

    var body: some View {
        BoxView("Welcome to ClaudeCodeIRC", color: .cyan) {
            VStack {
                Text("Pick a nickname for this device.").foregroundColor(.dim)
                Text("It shows up next to your messages and votes.").foregroundColor(.dim)
                SpacerView(1)
                HStack {
                    Text("nick: ").foregroundColor(.dim)
                    TextField("alice",
                              text: $nick,
                              isFocused: .constant(true),
                              onSubmit: submit)
                }
                SpacerView(1)
                Text("↵ continue").foregroundColor(.dim)
                if !error.isEmpty {
                    Text(error).foregroundColor(.red)
                }
            }
        }
        // Mandatory first-run setup — ESC consumed as no-op so it
        // doesn't bubble to the parent's interrupt-turn handler. (No
        // turn can be streaming on first run anyway, but explicit
        // > implicit.)
        .onKeyPress(27 /* ESC */) { }
    }

    private func submit() {
        let trimmed = nick.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            error = "nick can't be empty"
            return
        }
        guard !trimmed.contains(where: { $0.isWhitespace }) else {
            error = "nick can't contain whitespace"
            return
        }
        prefs.nick = trimmed
        // Overlay dismisses automatically — the parent's binding
        // re-evaluates `prefs.nick.isEmpty` and flips to false.
    }
}
