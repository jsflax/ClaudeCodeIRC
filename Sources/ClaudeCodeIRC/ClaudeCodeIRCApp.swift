import ClaudeCodeIRCCore
import Foundation
import Lattice
import NCursesUI

struct RootView: View {
    @Environment(\.screen) var screen
    @State private var model: RoomsModel = RoomsModel()

    var body: some View {
        // Env modifier must live OUTSIDE WorkspaceView so that by the
        // time its DynamicProperty updates run (which is where @Query
        // reads @Environment(\.lattice)), the active room's lattice is
        // already installed. Applying env inside a view's own body is
        // too late.
        let activeLattice = model.activeRoom?.lattice ?? LatticeKey.defaultValue
        let palette = model.prefs.paletteId.palette
        return WorkspaceView(model: model)
            .environment(\.lattice, activeLattice)
            .environment(\.palette, palette)
            // Rebind ncurses color pairs when the user picks a palette.
            // `.task(id:)` cancels + re-fires when the id changes, and
            // `PaletteRegistrar.activate` is idempotent so running it
            // on first appear is fine. Body is sync — the Task wrapper
            // just anchors lifecycle.
            .task(id: model.prefs.paletteId) {
                PaletteRegistrar.activate(palette)
                Log.line("app", "palette activated → \(palette.name)")
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
        // `LatticeKey.defaultValue.objects(T.self)` BEFORE the active
        // room lattice is installed via the environment. If that
        // fallback lattice doesn't know about our model types, SQLite
        // barfs with "no such table" on the first observe/fetch.
        // Register the full schema on the default in-memory placeholder.
        LatticeKey.defaultValue = try! Lattice(
            for: RoomStore.schema + [AppPreferences.self, LocalGroup.self],
            configuration: .init(isStoredInMemoryOnly: true))
        Log.line("app", "LatticeKey.defaultValue seeded with full schema")
    }

    var body: some Scene {
        WindowServer {
            RootView()
        }
    }
}
