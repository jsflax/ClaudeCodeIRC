import Foundation
import Lattice

@Model
public final class Turn {
    public var status: TurnStatus = .pending
    public var startedAt: Date = Date()
    public var endedAt: Date? = nil

    public var session: Session?

    /// The flushed user batch this turn was assembled from.
    public var prompt: ChatMessage?

    @Relation(link: \AssistantChunk.turn)
    public var chunks: any Results<AssistantChunk>

    @Relation(link: \ToolEvent.turn)
    public var toolEvents: any Results<ToolEvent>

    @Relation(link: \ChatMessage.turn)
    public var replies: any Results<ChatMessage>
}
