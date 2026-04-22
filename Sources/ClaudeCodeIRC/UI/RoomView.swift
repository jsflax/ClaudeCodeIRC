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

    var body: some View {
        VStack {
            HStack {
                Text(members.map(\.nick).joined(separator: " "))
                    .foregroundColor(.cyan)
                if model.server != nil, let code = model.session?.code {
                    Text(" · room: \(code)").foregroundColor(.dim)
                    Text(" · join: \(model.joinCode)").foregroundColor(.yellow)
                }
            }
            Text(String(repeating: "─", count: 60)).foregroundColor(.dim)

            ScrollView(height: 15) {
                VStack(spacing: 0) {
                    ForEach(messages) { msg in
                        HStack {
                            Text("<\(msg.author?.nick ?? "?")>").foregroundColor(.cyan)
                            Text(" \(msg.text)")
                        }
                    }
                }
            }

            Text(String(repeating: "─", count: 60)).foregroundColor(.dim)
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
