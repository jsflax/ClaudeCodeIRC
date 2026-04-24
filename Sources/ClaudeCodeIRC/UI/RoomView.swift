import ClaudeCodeIRCCore
import Foundation
import struct Lattice.Lattice
import class Lattice.TableResults
import NCursesUI

/// Union of the two event streams rendered in the scrollback. When
/// P5 lands TurnManager + tool events + turn separators, this grows
/// a `.toolEvent(ToolEvent)` case and a `.turnBoundary(Turn)` case.
enum RoomEvent: Identifiable {
    case message(ChatMessage)
    case chunk(AssistantChunk)

    var id: String {
        switch self {
        case .message(let m): return "m-\(m.globalId?.uuidString ?? "?")"
        case .chunk(let c):   return "c-\(c.globalId?.uuidString ?? "?")"
        }
    }

    var timestamp: Date {
        switch self {
        case .message(let m): return m.createdAt
        case .chunk(let c):   return c.createdAt
        }
    }

    var authorLabel: String {
        switch self {
        case .message(let m): return "<\(m.author?.nick ?? "?")>"
        case .chunk: return "<claude>"
        }
    }

    var authorColor: Color {
        switch self {
        case .message: return .cyan
        case .chunk:   return .magenta
        }
    }

    var text: String {
        switch self {
        case .message(let m): return m.text
        case .chunk(let c):   return c.text
        }
    }
}

struct RoomView: View {
    let model: RoomModel
    let onLeave: () -> Void

    @Environment(\.screen) var screen
    @State private var draft: String = ""
    @State private var overlayOpen: Bool = false

    @Query(sort: \ChatMessage.createdAt) var messages: TableResults<ChatMessage>
    @Query(sort: \AssistantChunk.createdAt) var chunks: TableResults<AssistantChunk>
    @Query(sort: \Turn.startedAt) var turns: TableResults<Turn>
    @Query() var members: TableResults<Member>
    @Query(sort: \ApprovalRequest.requestedAt) var approvals: TableResults<ApprovalRequest>

    /// Oldest `.pending` approval — drives the overlay on the host.
    /// Peers would render a read-only "<nick> is reviewing…" strip;
    /// that half lands as a P5 follow-up.
    private var pendingApproval: ApprovalRequest? {
        approvals.first { $0.status == .pending }
    }

    /// Host-only: does this instance own the sync server? Approvals
    /// are only actionable on the host — the shim subprocess runs as
    /// the host's child and watches the host's Lattice.
    private var isHost: Bool { model.server != nil }

    /// The Turn currently being streamed, if any. Drives the
    /// thinking strip above the input bar.
    private var streamingTurn: Turn? {
        turns.first { $0.status == .streaming }
    }

    init(model: RoomModel, onLeave: @escaping () -> Void) {
        self.model = model
        self.onLeave = onLeave
    }

    /// Terminal rows minus the fixed-height chrome around the scroll
    /// (status bar + two HLines + input bar = 4). `Term.rows` is read
    /// at body-eval time, so a terminal resize triggers recomputation
    /// on the next draw.
    private var scrollHeight: Int {
        max(1, Term.rows - 4)
    }

    /// Composed into a single Text so there's no chance of conditional
    /// HStack children collapsing to zero width and leaving only the
    /// trailing segments visible. Colors are folded into runs.
    private var statusBar: Text {
        let name = model.session?.name ?? ""
        let code = model.session?.code ?? "…"
        let memberNicks = members.map(\.nick).joined(separator: " ")
        let auth: (text: String, color: Color) = {
            if let j = model.joinCode { return (" · join: \(j)", .yellow) }
            if model.server != nil { return (" · open", .dim) }
            return ("", .dim)
        }()
        let mode = model.session?.permissionMode ?? .default

        var text = Text(name.isEmpty ? "(unnamed)" : name)
            .foregroundColor(.cyan).bold()
        text = text + Text(" · ").foregroundColor(.dim)
        text = text + Text(memberNicks.isEmpty ? "(no members)" : memberNicks)
            .foregroundColor(.cyan)
        text = text + Text(" · room: \(code)").foregroundColor(.dim)
        if !auth.text.isEmpty {
            text = text + Text(auth.text).foregroundColor(auth.color)
        }
        // `.default` is hidden — visible color only when the host has
        // actively relaxed the permission surface, mirroring the
        // signal intent of claude-code's mode pill.
        if mode != .default {
            text = text + Text(" · \(mode.label)").foregroundColor(Self.modeColor(mode))
        }
        return text
    }

    private static func modeColor(_ mode: PermissionMode) -> Color {
        switch mode {
        case .default:            return .dim
        case .acceptEdits:        return .magenta
        case .plan:               return .green
        case .auto:               return .yellow
        case .bypassPermissions:  return .red
        }
    }

    var body: some View {
        VStack {
            statusBar
            HLineView()

            ScrollView(height: scrollHeight) {
                VStack(spacing: 0) {
                    ForEach(scrollbackEvents) { event in
                        HStack {
                            Text(event.authorLabel)
                                .foregroundColor(event.authorColor)
                            Text(" \(event.text)")
                        }
                    }
                }
            }

            HLineView()
            if let t = streamingTurn {
                ClaudeThinkingView(turnId: t.globalId)
            }
            HStack {
                Text("\(model.selfMember?.nick ?? "?")> ").foregroundColor(.cyan)
                TextField("type a message…",
                          text: $draft,
                          isFocused: inputFocusBinding,
                          onSubmit: send)
            }
        }
        .onKeyPress(27 /* ESC */) {
            // ESC dismisses a pending approval overlay without deciding
            // (leaves the row pending so the host can come back to it);
            // otherwise it leaves the room.
            if isHost, pendingApproval != nil {
                overlayOpen = false
            } else {
                onLeave()
            }
        }
        .onKeyPress(Int32(UInt8(ascii: "Y"))) { decide(.approved, persist: false) }
        .onKeyPress(Int32(UInt8(ascii: "y"))) { decide(.approved, persist: false) }
        .onKeyPress(Int32(UInt8(ascii: "A"))) { decide(.approved, persist: true) }
        .onKeyPress(Int32(UInt8(ascii: "a"))) { decide(.approved, persist: true) }
        .onKeyPress(Int32(UInt8(ascii: "D"))) { decide(.denied,   persist: false) }
        .onKeyPress(Int32(UInt8(ascii: "d"))) { decide(.denied,   persist: false) }
        .onKeyPress(Int32(KEY_BTAB)) {
            // Shift-Tab cycles permission mode. Only meaningful for the
            // host — peers' sessions reflect whatever the host set.
            guard isHost, let s = model.session else { return }
            s.permissionMode = s.permissionMode.next()
            Log.line("room-host", "permission mode → \(s.permissionMode.label)")
        }
        .task(id: pendingApproval?.globalId) {
            // When a new pending approval appears, open the overlay.
            // The decide()/ESC paths flip `overlayOpen` back to false
            // directly — don't close here based on absence, since the
            // row may still be `.pending` after the user dismisses.
            if isHost, pendingApproval != nil { overlayOpen = true }
        }
        .overlay(isPresented: $overlayOpen, dimsBackground: true) {
            if let req = pendingApproval {
                ApprovalOverlayView(request: req)
            }
        }
    }

    /// Unfocus the TextField while the approval overlay is visible,
    /// so Y/A/D/ESC keystrokes bubble past TextField (whose `handles`
    /// short-circuits on `!isFocused`) to the RoomView-level approval
    /// handlers. After ESC (leave-pending), `overlayOpen` is false and
    /// the user can resume chatting even while the approval row stays
    /// `.pending`.
    private var inputFocusBinding: Binding<Bool> {
        Binding(
            get: { !overlayOpen },
            set: { _ in })
    }

    /// Mutate the `ApprovalRequest` row (and optionally persist an
    /// `ApprovalPolicy`) so the shim's `changeStream` observer wakes
    /// up. Lives on `RoomView` rather than `ApprovalOverlayView` so it
    /// fires regardless of whether the overlay is currently rendered
    /// — closing the race where the second approval's keystroke lands
    /// between overlay A dismissing and overlay B mounting.
    private func decide(_ status: ApprovalStatus, persist: Bool) {
        guard isHost, let req = pendingApproval else { return }
        req.status = status
        req.decidedAt = Date()
        req.decidedBy = model.selfMember
        if persist {
            let policy = ApprovalPolicy()
            policy.toolName = req.toolName
            policy.decision = status
            policy.decidedBy = model.selfMember
            model.lattice.add(policy)
        }
        overlayOpen = false
    }

    /// Merged time-ordered stream of user/system chat messages and
    /// assistant chunks. Proper unified rendering (with tool events,
    /// turn separators, per-nick colors) lands in P5 — for now this
    /// interleaves both sources by `createdAt` so the assistant reply
    /// actually shows up in the scrollback.
    private var scrollbackEvents: [RoomEvent] {
        let chatEvents = messages.map { RoomEvent.message($0) }
        let chunkEvents = chunks.map { RoomEvent.chunk($0) }
        return (chatEvents + chunkEvents).sorted { $0.timestamp < $1.timestamp }
    }

    private func send() {
        let raw = draft
        draft = ""
        let intent = InputRouter.parse(raw)
        switch intent {
        case .empty:
            return
        case .message(let text, let side):
            insertChat(text: text, kind: .user, side: side)
        case .setNick(let name):
            // Updates the `Member.nick` cell on this room's Lattice
            // (syncs to peers as a normal audit-log entry) and
            // persists on the prefs Lattice so the next launch picks
            // up the new nick.
            model.selfMember?.nick = name
            model.prefs?.nick = name
            insertSystem("nick set to \(name)")
        case .help:
            insertSystem(InputRouter.helpText)
        case .members:
            let nicks = Array(members)
                .sorted { $0.joinedAt < $1.joinedAt }
                .map { $0.isHost ? "\($0.nick) (host)" : $0.nick }
                .joined(separator: ", ")
            insertSystem("members: \(nicks.isEmpty ? "(none)" : nicks)")
        case .leave:
            onLeave()
        case .unknown(let reason):
            insertSystem("error: \(reason)")
        }
    }

    private func insertChat(text: String, kind: MessageKind, side: Bool) {
        guard let author = model.selfMember, let session = model.session
        else { return }
        let msg = ChatMessage()
        msg.text = text
        msg.kind = kind
        msg.side = side
        msg.author = author
        msg.session = session
        model.lattice.add(msg)
    }

    /// Local-only system message (e.g. `/help` output, unknown-command
    /// errors). Not authored by any Member — renders in its own dimmed
    /// style once MessageListView lands.
    private func insertSystem(_ text: String) {
        guard let session = model.session else { return }
        let msg = ChatMessage()
        msg.text = text
        msg.kind = .system
        msg.side = true  // exclude from Claude's prompt context
        msg.session = session
        model.lattice.add(msg)
    }
}
