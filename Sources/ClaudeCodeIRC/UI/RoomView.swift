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

    var body: some View {
        VStack {
            HStack {
                if let name = model.session?.name, !name.isEmpty {
                    Text(name).foregroundColor(.cyan).bold()
                    Text(" · ").foregroundColor(.dim)
                }
                Text(members.map(\.nick).joined(separator: " "))
                    .foregroundColor(.cyan)
                if let code = model.session?.code {
                    Text(" · room: \(code)").foregroundColor(.dim)
                }
                if let joinCode = model.joinCode {
                    Text(" · join: \(joinCode)").foregroundColor(.yellow)
                } else if model.server != nil {
                    Text(" · open").foregroundColor(.dim)
                }
            }
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
        .environment(\.lattice, model.lattice)
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
