import Foundation
import NCUITest

extension NCUIApplication {
    /// ClaudeCodeIRC-specific factory: per-app isolated data dir so multiple
    /// tests can run with their own prefs + room state. The label maps to a
    /// directory suffix; pass the same label twice and you'll get distinct
    /// directories (each call generates a fresh UUID-prefixed path).
    public static func ccirc(label: String) -> NCUIApplication {
        let dataDir = (NSTemporaryDirectory() as NSString)
            .appendingPathComponent("ccirc-e2e-\(label)-\(UUID().uuidString.prefix(6))")
        try? FileManager.default.removeItem(atPath: dataDir)
        return NCUIApplication(
            label: label,
            productName: "claudecodeirc",
            launchEnvironment: ["CCIRC_DATA_DIR": dataDir]
        )
    }

    /// Generate a unique-per-run room name. Avoids stale-discovery hits
    /// between test runs (mirrors `_lib.sh:SMOKE_ROOM_NAME`).
    public static func ccircRoomName(prefix: String) -> String {
        let suffix = UUID().uuidString.prefix(8).lowercased()
        return "\(prefix)-\(suffix)"
    }

    /// The `CCIRC_DATA_DIR` value passed to the spawned process. Tests use
    /// this to open the room lattice file directly via Lattice for state
    /// assertions that aren't visible in the UI tree.
    public var dataDir: String {
        launchEnvironment["CCIRC_DATA_DIR"] ?? ""
    }
}
