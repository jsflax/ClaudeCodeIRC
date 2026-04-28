import Foundation

/// Filesystem layout for room Lattice stores.
///
///   ~/Library/Application Support/ClaudeCodeIRC/rooms/<code>.lattice
///
/// Application Support, not Caches: transcripts are persistent user data
/// that must survive OS cache eviction under storage pressure. Users
/// reasonably expect "resume yesterday's session" to still work.
///
/// **Data-dir override.** For local e2e testing (two tmux panes
/// simulating two different users on one machine) the base directory
/// can be pointed elsewhere via either:
///   - CLI flag `--data-dir <path>` (highest precedence; set by
///     `ClaudeCodeIRCApp.main()`)
///   - env var `CCIRC_DATA_DIR`
///   - default `~/Library/Application Support/ClaudeCodeIRC`
///
/// When overridden, rooms live at `<path>/rooms/…` and prefs at
/// `<path>/prefs.lattice` — isolating the full per-user state.
public enum RoomPaths {
    /// CLI-set override — takes precedence over the env var and the
    /// default. Set once by `ClaudeCodeIRCApp.main()` before any
    /// `RoomsModel` is built. `nonisolated(unsafe)` because this is
    /// a write-once-at-startup knob; no runtime contention.
    nonisolated(unsafe) public static var dataDirOverride: URL?

    /// Resolved base directory honoring the override precedence.
    public static var dataDirectory: URL {
        if let override = dataDirOverride { return override }
        if let env = ProcessInfo.processInfo.environment["CCIRC_DATA_DIR"],
           !env.isEmpty {
            return URL(fileURLWithPath: (env as NSString).expandingTildeInPath)
        }
        let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first!
        return appSupport.appending(path: "ClaudeCodeIRC")
    }

    public static var rootDirectory: URL {
        dataDirectory.appending(path: "rooms")
    }

    /// Prefs lattice path — derived from the data directory so an
    /// override isolates nick / lastCwd / paletteId per instance.
    public static var prefsURL: URL {
        dataDirectory.appending(path: "prefs.lattice")
    }

    /// Room DB path. Same file for host and peer roles — the role is a
    /// runtime property of the `Lattice` (host owns the synchronizer;
    /// peer connects over WS), not a property of the file. Multiple
    /// instances on one machine isolate via `CCIRC_DATA_DIR` (or the
    /// `--data-dir` CLI flag), so different roles using the same room
    /// code never share a directory.
    public static func storeURL(forCode code: String) -> URL {
        rootDirectory.appending(path: "\(code).lattice")
    }

    /// Create the rooms directory if it doesn't exist. Idempotent.
    public static func ensureRootDirectoryExists() throws {
        try FileManager.default.createDirectory(
            at: rootDirectory, withIntermediateDirectories: true)
    }
}
