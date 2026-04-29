import NCursesUI

/// IRC-style stable per-nick colour. Hashes the nick to a fixed slot
/// in a small palette so the same person always renders in the same
/// colour across the chat scrollback and the users sidebar — the
/// classic IRC "you can pick someone out by their colour" affordance.
///
/// Reserved roles get fixed colours and should NOT go through this
/// helper: bots/`@claude` → `.yellow`, the local member's own row in
/// the users sidebar → `.green`, away rows → `.dim`. The palette
/// here is the leftover slots that are visible on dark backgrounds
/// and don't collide with any of those roles.
enum NickColor {
    /// Five distinct foreground hues — cyan/magenta/blue/purple/teal.
    /// Five is comfortably above the typical ccirc room headcount
    /// (host + a couple of peers), small enough that collisions are
    /// rare in practice but visible enough that adjacent nicks
    /// reliably read as different colours.
    private static let palette: [Color] = [.cyan, .magenta, .blue, .purple, .teal]

    /// Pick a stable colour for `nick`. Empty / nil-ish nicks fall
    /// through to `.cyan` rather than crashing — the rest of the UI
    /// already tolerates an empty nick (renders `?`), so this stays
    /// soft.
    static func color(for nick: String) -> Color {
        if nick.isEmpty { return palette[0] }
        // djb2 over the UTF-8 bytes — small, stable, and good enough
        // for picking 1-of-5 buckets (collisions are visually
        // acceptable since the alternative is everyone in cyan).
        var h: UInt64 = 5381
        for byte in nick.utf8 {
            h = h &* 33 &+ UInt64(byte)
        }
        return palette[Int(h % UInt64(palette.count))]
    }
}
