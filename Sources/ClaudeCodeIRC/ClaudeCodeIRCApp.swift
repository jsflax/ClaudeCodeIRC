import ClaudeCodeIRCCore
import Lattice
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
    init() {
        // `@Query` Wrapper's init seeds its TableResults value from
        // `LatticeKey.defaultValue.objects(T.self)` BEFORE the room
        // lattice is installed via the environment. If that fallback
        // lattice doesn't know about our model types, SQLite barfs
        // with "no such table" on the first observe/fetch. Register
        // the full schema on the default in-memory placeholder at
        // process start.
        LatticeKey.defaultValue = try! Lattice(
            for: RoomStore.schema + [AppPreferences.self],
            configuration: .init(isStoredInMemoryOnly: true))
    }

    var body: some Scene {
        WindowServer {
            RootView()
        }
    }
}
