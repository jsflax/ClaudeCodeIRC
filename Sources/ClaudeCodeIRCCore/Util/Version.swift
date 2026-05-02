import Foundation

/// The version string baked into the binary at build time.
///
/// `release.yml` rewrites the literal below with the git tag
/// (e.g. `v0.0.4`) before invoking `swift build -c release`. Local
/// `swift build` keeps `"dev"`, which `Updater` treats as the
/// sentinel for "skip the auto-update check" — we never want a
/// developer iterating on the codebase to silently swap their build
/// out for a published release.
public enum Version {
    public static let current = "dev"
}
