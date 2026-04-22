import Foundation
import Lattice

@Model
public final class ChatMessage {
    public var kind: MessageKind = .user
    public var text: String = ""

    /// `/side` marker: message is visible to humans but excluded from the
    /// prompt batched to Claude on the next `@claude` flush.
    public var side: Bool = false

    @Indexed()
    public var createdAt: Date = Date()

    /// nil for assistant / system messages.
    public var author: Member?
    public var session: Session?

    /// For assistant / system messages tied to a specific turn.
    public var turn: Turn?
}
