import Foundation
import Lattice

@Model
public final class Turn {
    public var status: TurnStatus = .pending
    public var startedAt: Date = Date()
    public var endedAt: Date? = nil

    /// Cooperative interrupt. Anyone in the room can flip this to
    /// `true` (peer or host) — the host's `RoomInstance` observes
    /// the change and stops the `claude` subprocess, which flushes
    /// pending assistant text and flips `status` to `.errored`.
    /// Peers don't run a driver, so without this flag they'd have
    /// no way to interrupt; routing the request through Lattice
    /// keeps the cancel path identical for host and peer ESC presses
    /// and avoids a separate signaling channel.
    public var cancelRequested: Bool = false

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
