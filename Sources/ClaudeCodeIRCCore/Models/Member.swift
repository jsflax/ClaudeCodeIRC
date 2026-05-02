import Foundation
import Lattice

@Model
public final class Member {
    /// Stable, per-device identity (mirrored from `AppPreferences.userId`).
    /// Used to find "my Member" on rejoin instead of comparing nicks —
    /// nicks change with `/nick` and collide across users. Indexed so
    /// the rejoin lookup `WHERE userId = ?` is a single SQL hit. Not
    /// `@Unique` — the same global user can have a Member row in many
    /// rooms (different lattice files), and over time within a single
    /// room if delete-and-reinsert ever happens.
    @Indexed()
    public var userId: UUID = UUID()

    public var nick: String = ""
    public var isHost: Bool = false

    @Indexed()
    public var colorIndex: Int = 0

    public var joinedAt: Date = Date()
    public var lastSeenAt: Date = Date()

    /// AFK flag — toggled by `/afk`. AFK members are excluded from the
    /// approval-vote quorum denominator and render dim + `(afk)` suffix in
    /// the userlist. Auto-clears when the member sends a non-afk message.
    public var isAway: Bool = false
    public var awayReason: String? = nil

    /// Typing indicator. Set ~3s in the future on each (debounced)
    /// keystroke and cleared on send. UI renders an ephemeral
    /// "<nick> typing…" row for any non-self member where
    /// `typingUntil > Date.now`. Self-expires without GC.
    public var typingUntil: Date? = nil

    public var session: Session?

    @Relation(link: \ChatMessage.author)
    public var authored: any Results<ChatMessage>
}
