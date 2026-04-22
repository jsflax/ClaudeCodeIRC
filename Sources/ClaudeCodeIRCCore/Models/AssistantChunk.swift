import Foundation
import Lattice

/// Append-only streamed chunk of assistant text for a given Turn. The full
/// rendered reply is the concatenation of all chunks for a Turn ordered by
/// `index`. Append-only rather than mutating `ChatMessage.text` so streaming
/// doesn't amplify writes.
@Model
public final class AssistantChunk {
    /// Monotonic position within the Turn (named `chunkIndex` rather than
    /// `index` because `INDEX` is a SQL reserved keyword).
    @Indexed()
    public var chunkIndex: Int = 0

    public var text: String = ""

    @Indexed()
    public var createdAt: Date = Date()

    public var turn: Turn?
}
