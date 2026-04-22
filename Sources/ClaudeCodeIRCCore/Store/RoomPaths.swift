import Foundation

/// Filesystem layout for room Lattice stores.
///
///   ~/Library/Application Support/ClaudeCodeIRC/rooms/<code>.lattice
///
/// Application Support, not Caches: transcripts are persistent user data
/// that must survive OS cache eviction under storage pressure. Users
/// reasonably expect "resume yesterday's session" to still work.
public enum RoomPaths {
    public static var rootDirectory: URL {
        let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first!
        return appSupport.appending(path: "ClaudeCodeIRC/rooms")
    }

    public static func storeURL(forCode code: String) -> URL {
        rootDirectory.appending(path: "\(code).lattice")
    }

    /// Create the rooms directory if it doesn't exist. Idempotent.
    public static func ensureRootDirectoryExists() throws {
        try FileManager.default.createDirectory(
            at: rootDirectory, withIntermediateDirectories: true)
    }
}
