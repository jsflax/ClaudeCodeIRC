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

    /// Peer-side room file. Scoped by pid so two instances running on
    /// the same machine (host + peer, or two peers) don't share the
    /// same SQLite file — the peer is supposed to be a replica that
    /// syncs *over the wire*, not a second handle on the host's file.
    public static func peerStoreURL(forCode code: String, pid: pid_t = getpid()) -> URL {
        rootDirectory.appending(path: "\(code).peer-\(pid).lattice")
    }

    /// Create the rooms directory if it doesn't exist. Idempotent.
    public static func ensureRootDirectoryExists() throws {
        try FileManager.default.createDirectory(
            at: rootDirectory, withIntermediateDirectories: true)
    }
}
