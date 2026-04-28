import Foundation
import Lattice

/// Singleton row holding cross-launch user preferences (nick, last cwd,
/// etc). The `@Unique` key pins a single "singleton" row — the first
/// time the app opens prefs, PrefsStore inserts it; subsequent opens
/// find and return the same row.
@Model
public final class AppPreferences {
    @Unique()
    public var key: String = "singleton"
    public var nick: String = ""
    public var lastCwd: String = ""

    /// Active palette — picked via the palette selector overlay and
    /// restored on next launch.
    public var paletteId: PaletteId = .phosphor

    /// Base URL of the directory Worker (`POST /publish`,
    /// `GET /list?group=`). v1 deploys to a free `*.workers.dev`
    /// subdomain — `jsflax.workers.dev` is the maintainer's account;
    /// migration to a custom domain (e.g. `lobby.claudecodeirc.dev`)
    /// is a one-line default change in a future release. The
    /// `CCIRC_DIRECTORY_URL` env var overrides this for local
    /// Worker dev (`wrangler dev`).
    public var directoryEndpointURL: String = "https://ccirc-lobby.jsflax.workers.dev"

    /// Monotonic counter used as the directory publish payload's
    /// `publishVersion` field. Incremented on every successful publish.
    /// Persisted across launches so a fresh app instance wins last-
    /// writer-wins arbitration against a stale running one.
    public var publishVersion: Int = 0
}
