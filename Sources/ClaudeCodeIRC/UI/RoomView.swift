import ClaudeCodeIRCCore
import class Lattice.TableResults
import NCursesUI

struct RoomView: View {
    let model: RoomModel
    let onLeave: () -> Void

    @Environment(\.screen) var screen
    @State private var draft: String = ""

    @Query(sort: \ChatMessage.createdAt) var messages: TableResults<ChatMessage>
    @Query() var members: TableResults<Member>

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

        var text = Text(name.isEmpty ? "(unnamed)" : name)
            .foregroundColor(.cyan).bold()
        text = text + Text(" · ").foregroundColor(.dim)
        text = text + Text(memberNicks.isEmpty ? "(no members)" : memberNicks)
            .foregroundColor(.cyan)
        text = text + Text(" · room: \(code)").foregroundColor(.dim)
        if !auth.text.isEmpty {
            text = text + Text(auth.text).foregroundColor(auth.color)
        }
        return text
    }

    var body: some View {
        VStack {
            statusBar
            HLineView()

            ScrollView(height: scrollHeight) {
                VStack(spacing: 0) {
                    ForEach(messages) { msg in
                        HStack {
                            Text("<\(msg.author?.nick ?? "?")>").foregroundColor(.cyan)
                            Text(" \(msg.text)")
                        }
                    }
                }
            }

            HLineView()
            HStack {
                Text("\(model.selfMember?.nick ?? "?")> ").foregroundColor(.cyan)
                TextField("type a message…", text: $draft, onSubmit: send)
            }
        }
        .onKeyPress(27 /* ESC */) {
            onLeave()
        }
    }

    private func send() {
        let text = draft
        guard !text.isEmpty,
              let author = model.selfMember,
              let session = model.session
        else { return }
        let msg = ChatMessage()
        msg.text = text
        msg.kind = .user
        msg.author = author
        msg.session = session
        model.lattice.add(msg)
        draft = ""
    }
}
