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
        // First-run dependency gate. Refuse to boot without `claude`;
        // the TUI lobby is cosmetic without it. `cloudflared` missing
        // is non-blocking — surface only when the user tries to host
        // a non-Private room. See Doctor.swift for rationale.
        let report = Doctor.check()
        if report.claudePath == nil {
            FileHandle.standardError.write(Data("""
                ClaudeCodeIRC needs `claude` (Anthropic CLI) — not found on PATH.

                Install:   npm install -g @anthropic-ai/claude-code
                No Node?   brew install node    (then re-run claudecodeirc)

                """.utf8))
            exit(1)
        }
        // Background self-update — silent, non-blocking. The current
        // process keeps running on its already-loaded inode; any new
        // binary written to disk takes effect the next time the user
        // launches `claudecodeirc`. See `Updater.swift` for skip gates
        // (dev builds, brew installs, opt-out env vars).
        Updater.runInBackground(currentVersion: Version.current)
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
