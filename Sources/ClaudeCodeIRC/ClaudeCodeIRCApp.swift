import ClaudeCodeIRCCore
import Foundation
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
            // Env modifier must live OUTSIDE RoomView so that by the
            // time RoomView's DynamicProperty update runs (which is
            // where @Query reads @Environment(\.lattice)), the lattice
            // has already been installed in _current. Applying the env
            // inside RoomView's own body is too late.
            RoomView(model: model) {
                Task {
                    await model.leave()
                    current = .lobby(LobbyModel())
                }
            }
            .environment(\.lattice, model.lattice)
        }
    }
}

@main
struct ClaudeCodeIRCApp: App {
    /// Overrides NCursesUI's default `main()` to intercept the
    /// `--mcp-approve` invocation before the TUI boots. When `claude`
    /// spawns us as a stdio MCP server (per `ClaudeCliDriver`'s
    /// `--mcp-config`), we don't want to touch ncurses at all — we're
    /// just a JSON-RPC pipe over stdin/stdout routing approvals
    /// through the host's room Lattice.
    ///
    /// `ApprovalMcpShim.run()` is `async -> Never` and calls `exit()`
    /// at teardown, so the detached Task never returns control here;
    /// `RunLoop.main.run()` just keeps the process alive while the
    /// cooperative pool services the shim.
    static func main() {
        if CommandLine.arguments.contains("--mcp-approve") {
            Task.detached { await ApprovalMcpShim.run() }
            RunLoop.main.run()
            return
        }
        let app = Self.init()
        app.body.run()
    }

    init() {
        Log.line("app", "startup — log file: \(Log.filePath)")
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
        Log.line("app", "LatticeKey.defaultValue seeded with full schema")
    }

    var body: some Scene {
        WindowServer {
            RootView()
        }
    }
}
