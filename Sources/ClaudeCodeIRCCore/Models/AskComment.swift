import Foundation
import Lattice

/// A discussion message attached to a pending `AskQuestion`. Lets the
/// room debate which option to pick when votes split, without those
/// words leaking into claude's tool-call response.
///
/// Owned by its parent `AskQuestion` via `List<AskComment>` — the
/// link table preserves insertion order (no `createdAt` sort needed
/// for display) and binds lifecycle to the question.
///
/// Crucially this is NOT a `ChatMessage`: `TurnManager.ingest` only
/// observes `ChatMessage` inserts, so comments never reach the live
/// `claude -p` subprocess. The shim's reply to claude carries only
/// the chosen labels — discussion stays peer-to-peer.
@Model
public final class AskComment {
    public var author: Member?
    public var text: String = ""
    public var createdAt: Date = Date()
}
