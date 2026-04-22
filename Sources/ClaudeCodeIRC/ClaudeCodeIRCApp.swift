import ClaudeCodeIRCCore
import NCursesUI

enum Screen {
    case lobby(LobbyModel)
    case room(RoomModel)
}

struct RootView: View {
    @Environment(\.screen) var screen
    @State private var current: Screen = .lobby(LobbyModel())

    var body: some View {
        switch current {
        case .lobby(let model):
            LobbyView(model: model) { room in
                current = .room(room)
            }
        case .room(let model):
            RoomView(model: model) {
                Task {
                    await model.leave()
                    current = .lobby(LobbyModel())
                }
            }
        }
    }
}

@main
struct ClaudeCodeIRCApp: App {
    var body: some Scene {
        WindowServer {
            RootView()
        }
    }
}
