import Foundation
import Lattice

@Model
public final class Member {
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

    /// Preflight fields used by host election. Each peer writes its own values
    /// on join so the election algorithm can filter candidates.
    public var hasClaudeHelper: Bool = false
    public var canHostCwd: String? = nil

    public var session: Session?

    @Relation(link: \ChatMessage.author)
    public var authored: any Results<ChatMessage>
}
