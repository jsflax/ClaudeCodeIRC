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
}
